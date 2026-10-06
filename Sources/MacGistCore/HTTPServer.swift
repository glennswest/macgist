import Foundation
import Network
import os

private let log = Logger(subsystem: "com.glennswest.macgist", category: "http")

/// Minimal HTTP/1.1 server, one request per connection. Serves gists
/// (`/g/...`, GET/HEAD, streamed from disk) and the token-protected inbox
/// (`/in/<token>/...`, uploads to this Mac).
public final class HTTPServer: @unchecked Sendable {
    public enum State: Sendable { case ready, failed(Error) }

    private let listener: NWListener
    private let store: GistStore
    private let inbox: Inbox?
    private let page: PageSettings

    public init(port: UInt16, store: GistStore, inbox: Inbox? = nil, page: PageSettings = PageSettings()) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: p)
        self.store = store
        self.inbox = inbox
        self.page = page
    }

    public func start(onState: @escaping @Sendable (State) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(.ready)
            case .failed(let e): onState(.failed(e))
            default: break
            }
        }
        listener.newConnectionHandler = { [store, inbox, page] conn in
            Connection(conn: conn, store: store, inbox: inbox, page: page).start()
        }
        listener.start(queue: DispatchQueue(label: "macgist.listener"))
    }

    public func stop() { listener.cancel() }
}

private final class Connection: @unchecked Sendable {
    static let maxHeader = 16 * 1024
    static let chunk = 1 << 20
    static let headerTimeout: TimeInterval = 30
    static let bodyIdleTimeout: TimeInterval = 60

    let conn: NWConnection
    let store: GistStore
    let inbox: Inbox?
    let page: PageSettings
    let queue = DispatchQueue(label: "macgist.conn")
    var buffer = Data()
    var gotHeader = false

    // Request-body state (inbox uploads).
    enum BodyFailure: Error { case tooLarge, malformed, closed, timeout, write(Error) }
    var bodyTotal: UInt64 = 0
    var bodyExpected: UInt64 = 0
    var bodyLimit: UInt64 = 0
    var bodyDecoder: ChunkedDecoder?
    var bodySink: ((Data) throws -> Void)?
    var bodyDone: ((Result<UInt64, BodyFailure>) -> Void)?
    var bodyActivity = 0

    init(conn: NWConnection, store: GistStore, inbox: Inbox?, page: PageSettings) {
        self.conn = conn
        self.store = store
        self.inbox = inbox
        self.page = page
    }

    func start() {
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) { [self] in
            if !gotHeader { conn.cancel() }
        }
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeader) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                gotHeader = true
                handle(head: buffer[..<end.lowerBound], leftover: Data(buffer[end.upperBound...]))
            } else if buffer.count > Self.maxHeader {
                gotHeader = true
                respondText(400, "Request header too large.\n")
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                receive()
            }
        }
    }

    private func handle(head: Data, leftover: Data) {
        guard let req = HTTP.parse(Data(head)) else { return respondText(400, "Bad request.\n") }
        if case .inbox(let token, let item) = HTTP.route(req.path) {
            return handleInbox(req, token: token, item: item, leftover: leftover)
        }
        let isHead = req.method == "HEAD"
        guard req.method == "GET" || isHead else {
            return respondText(405, "Method not allowed.\n", extra: [("Allow", "GET, HEAD")])
        }
        let wantsHTML = req.headers["accept"]?.contains("text/html") ?? false
        let remote = conn.endpoint.debugDescription
        guard let route = HTTP.route(req.path), let token = route.token, let gist = store.lookup(token) else {
            log.info("\(remote, privacy: .public) \(req.method, privacy: .public) -> 404")
            if wantsHTML { return respond(404, html: GistPage.notFound(), head: isHead) }
            return respondText(404, "This gist has expired or does not exist.\n", head: isHead)
        }
        log.info("\(remote, privacy: .public) \(req.method, privacy: .public) \(req.path, privacy: .public)")

        switch route {
        case .page:
            if wantsHTML {
                if !isHead { store.recordHit(gist.token) }
                return respond(200, html: GistPage.render(gist, sharedBy: Host.current().localizedName ?? "a Mac",
                                                                 highlightBase: page.highlightBase), head: isHead)
            }
            // curl/wget: a one-file gist is the file itself; otherwise a list of raw URLs.
            if gist.entries.count == 1 { return serve(gist, file: gist.entries[0], inline: true, req: req) }
            let base = "http://\(req.headers["host"] ?? "localhost")"
            return respondText(200, GistPage.listing(gist, base: base), head: isHead)
        case .raw(_, let i), .download(_, let i):
            guard gist.entries.indices.contains(i) else { return respondText(404, "No such file.\n", head: isHead) }
            if case .raw = route { return serve(gist, file: gist.entries[i], inline: true, req: req) }
            return serve(gist, file: gist.entries[i], inline: false, req: req)
        case .inbox:
            return respondText(404, "Not found.\n", head: isHead)
        case .archive:
            do {
                let zip = try store.archive(for: gist)
                let entry = try GistEntry(name: zip.lastPathComponent, fileURL: zip)
                return serve(gist, file: entry, inline: false, req: req)
            } catch {
                log.error("archive: \(error.localizedDescription, privacy: .public)")
                return respondText(500, "Could not build the archive.\n", head: isHead)
            }
        }
    }

    // MARK: - Inbox (issue #1)

    private var remoteIP: String {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: break
            }
        }
        return ""
    }

    private func handleInbox(_ req: HTTPRequest, token: String?, item: String?, leftover: Data) {
        let ip = remoteIP
        // Same 403 for every refusal so a prober learns nothing about which check failed.
        guard let inbox, inbox.enabled, inbox.allows(ip), let token, inbox.authorize(token) else {
            log.info("inbox refused \(ip, privacy: .public) \(req.method, privacy: .public)")
            return respondText(403, "Forbidden.\n")
        }
        let sender = inbox.senderName(for: ip)
        log.info("inbox \(sender, privacy: .public) (\(ip, privacy: .public)) \(req.method, privacy: .public) \(item ?? "/", privacy: .public)")

        switch (req.method, item) {
        case ("GET", "ping"), ("HEAD", "ping"):
            return respondText(200, "ok \(Host.current().localizedName ?? "MacGist")\n", head: req.method == "HEAD")
        case ("GET", nil), ("GET", ""):
            return respond(200, html: GistPage.inboxPage(token: inbox.token, macName: Host.current().localizedName ?? "this Mac"),
                           head: false)
        case ("POST", "clipboard"):
            var text = Data()
            readBody(req, leftover: leftover, limit: inbox.clipboardLimit, sink: { text.append($0) }) { [self] result in
                switch result {
                case .success:
                    guard let string = String(data: text, encoding: .utf8) else {
                        return respondText(400, "Clipboard text must be UTF-8.\n")
                    }
                    inbox.deliverText(string, title: HTTP.query(req.path)["title"], sender: sender)
                    sendHead(204, []) { [self] in finish() }
                case .failure(let f):
                    fail(f)
                }
            }
        case ("PUT", let name?), ("POST", let name?):
            guard name != "clipboard", name != "ping", let safe = HTTP.sanitizeFilename(name) else {
                return respondText(400, "Bad file name.\n")
            }
            let partial: URL
            let handle: FileHandle
            do {
                partial = try inbox.makePartial()
                handle = try FileHandle(forWritingTo: partial)
            } catch {
                return respondText(500, "Cannot write to the inbox: \(error.localizedDescription)\n")
            }
            readBody(req, leftover: leftover, limit: inbox.maxFileBytes, sink: { try handle.write(contentsOf: $0) }) { [self] result in
                try? handle.close()
                switch result {
                case .success(let bytes):
                    do {
                        let saved = try inbox.saveFile(partial: partial, name: safe, size: bytes, sender: sender)
                        respondJSON(201, ["saved": saved.path, "bytes": bytes])
                    } catch {
                        try? FileManager.default.removeItem(at: partial)
                        respondText(500, "Could not save: \(error.localizedDescription)\n")
                    }
                case .failure(let f):
                    try? FileManager.default.removeItem(at: partial)
                    fail(f)
                }
            }
        default:
            respondText(405, "Method not allowed.\n", extra: [("Allow", "GET, PUT, POST")])
        }
    }

    private func fail(_ f: BodyFailure) {
        switch f {
        case .tooLarge: respondText(413, "Too large.\n")
        case .malformed: respondText(400, "Malformed body.\n")
        case .timeout: respondText(408, "Timed out waiting for the body.\n")
        case .write(let e): respondText(500, "Write failed: \(e.localizedDescription)\n")
        case .closed: conn.cancel()
        }
    }

    /// Reads a Content-Length or chunked body into `sink`, enforcing `limit`.
    private func readBody(_ req: HTTPRequest, leftover: Data, limit: UInt64,
                          sink: @escaping (Data) throws -> Void,
                          done: @escaping (Result<UInt64, BodyFailure>) -> Void) {
        let chunked = req.headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
        if chunked {
            bodyDecoder = ChunkedDecoder()
        } else {
            guard let length = req.headers["content-length"].flatMap({ UInt64($0) }) else {
                return respondText(411, "Content-Length or chunked encoding required.\n")
            }
            guard length <= limit else { return respondText(413, "Too large (limit \(HTTP.formatSize(limit))).\n") }
            bodyExpected = length
        }
        bodyLimit = limit
        bodySink = sink
        bodyDone = done

        let start = { [self] in
            do {
                if try consume(leftover) { return complete(.success(bodyTotal)) }
            } catch let f as BodyFailure {
                return complete(.failure(f))
            } catch {
                return complete(.failure(.write(error)))
            }
            pumpBody()
        }
        if req.headers["expect"]?.lowercased() == "100-continue" {
            conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { [self] error in
                if error != nil { return conn.cancel() }
                start()
            })
        } else {
            start()
        }
    }

    /// Returns true once the whole body has arrived.
    private func consume(_ data: Data) throws -> Bool {
        let out: Data
        if bodyDecoder != nil {
            do { out = try bodyDecoder!.feed(data) } catch { throw BodyFailure.malformed }
        } else {
            out = data.prefix(Int(min(UInt64(data.count), bodyExpected - bodyTotal)))
        }
        bodyTotal += UInt64(out.count)
        if bodyTotal > bodyLimit { throw BodyFailure.tooLarge }
        if !out.isEmpty {
            do { try bodySink?(out) } catch { throw BodyFailure.write(error) }
        }
        return bodyDecoder?.isDone ?? (bodyTotal >= bodyExpected)
    }

    private func pumpBody() {
        bodyActivity += 1
        let mine = bodyActivity
        queue.asyncAfter(deadline: .now() + Self.bodyIdleTimeout) { [self] in
            if bodyActivity == mine, bodyDone != nil { complete(.failure(.timeout)) }
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [self] data, _, isComplete, error in
            guard bodyDone != nil else { return }
            do {
                if let data, try consume(data) { return complete(.success(bodyTotal)) }
            } catch let f as BodyFailure {
                return complete(.failure(f))
            } catch {
                return complete(.failure(.write(error)))
            }
            if isComplete || error != nil { return complete(.failure(.closed)) }
            pumpBody()
        }
    }

    private func complete(_ result: Result<UInt64, BodyFailure>) {
        guard let done = bodyDone else { return }
        bodyDone = nil
        bodySink = nil
        bodyActivity += 1
        done(result)
    }

    private func respondJSON(_ status: Int, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        sendHead(status, [("Content-Type", "application/json"), ("Content-Length", String(data.count + 1))]) { [self] in
            conn.send(content: data + Data("\n".utf8), completion: .contentProcessed { [self] _ in finish() })
        }
    }

    // MARK: - Gists

    private func serve(_ gist: Gist, file: GistEntry, inline: Bool, req: HTTPRequest) {
        let isHead = req.method == "HEAD"
        let handle: FileHandle
        let size: UInt64
        do {
            handle = try FileHandle(forReadingFrom: file.fileURL)
            size = try handle.seekToEnd()
        } catch {
            log.error("open \(file.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return respondText(404, "The shared file is no longer available.\n", head: isHead)
        }

        // Raw text is always text/plain so a shared .html or .svg never runs as a page.
        let mime: String
        switch file.kind {
        case .text: mime = "text/plain; charset=utf-8"
        case .image: mime = file.mime == "image/svg+xml" && inline ? "text/plain; charset=utf-8" : file.mime
        case .binary: mime = file.mime
        }
        var headers: [(String, String)] = [
            ("Content-Type", mime),
            ("Content-Disposition", HTTP.contentDisposition(filename: file.name, inline: inline && file.kind != .binary)),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ]
        let start: UInt64
        let length: UInt64
        let status: Int
        switch HTTP.parseRange(req.headers["range"], size: size) {
        case .full:
            status = 200; start = 0; length = size
        case .partial(let s, let e):
            status = 206; start = s; length = e - s + 1
            headers.append(("Content-Range", "bytes \(s)-\(e)/\(size)"))
        case .unsatisfiable:
            try? handle.close()
            return respondText(416, "Range not satisfiable.\n", extra: [("Content-Range", "bytes */\(size)")])
        }
        headers.append(("Content-Length", String(length)))
        if !isHead && start == 0 { store.recordHit(gist.token) }

        sendHead(status, headers) { [self] in
            guard !isHead, length > 0 else { try? handle.close(); return finish() }
            do { try handle.seek(toOffset: start) } catch { try? handle.close(); return conn.cancel() }
            stream(handle, remaining: length)
        }
    }

    private func stream(_ handle: FileHandle, remaining: UInt64) {
        if remaining == 0 { try? handle.close(); return finish() }
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: Int(min(remaining, UInt64(Self.chunk)))) ?? Data()
        } catch {
            try? handle.close(); return conn.cancel()
        }
        // An empty read means the file shrank under us; drop the connection so
        // the client sees a short body rather than a hang.
        if chunk.isEmpty { try? handle.close(); return conn.cancel() }
        conn.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { try? handle.close(); return conn.cancel() }
            stream(handle, remaining: remaining - UInt64(chunk.count))
        })
    }

    private func sendHead(_ status: Int, _ headers: [(String, String)], then: @escaping () -> Void) {
        var text = "HTTP/1.1 \(status) \(HTTP.reason(status))\r\n"
        for (k, v) in headers + [("Connection", "close"), ("Server", "MacGist")] { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { [self] error in
            if error != nil { return conn.cancel() }
            then()
        })
    }

    private func respondText(_ status: Int, _ body: String, head: Bool = false, extra: [(String, String)] = []) {
        let data = Data(body.utf8)
        sendHead(status, [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(data.count))] + extra) { [self] in
            if head { return finish() }
            conn.send(content: data, completion: .contentProcessed { [self] _ in finish() })
        }
    }

    private func respond(_ status: Int, html: String, head: Bool) {
        let data = Data(html.utf8)
        sendHead(status, [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", String(data.count)),
                          ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer")]) { [self] in
            if head { return finish() }
            conn.send(content: data, completion: .contentProcessed { [self] _ in finish() })
        }
    }

    private func finish() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [self] _ in conn.cancel() })
    }
}
