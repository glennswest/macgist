import Foundation
import Testing
@testable import MacGistCore

@Suite struct InboxUnitTests {
    @Test func inboxRoutes() {
        #expect(HTTP.route("/in/tok") == .inbox(token: "tok", item: nil))
        #expect(HTTP.route("/in/tok/") == .inbox(token: "tok", item: nil))
        #expect(HTTP.route("/in/tok/ping") == .inbox(token: "tok", item: "ping"))
        #expect(HTTP.route("/in/tok/clipboard?title=hi") == .inbox(token: "tok", item: "clipboard"))
        #expect(HTTP.route("/in/tok/a%20b.txt") == .inbox(token: "tok", item: "a b.txt"))
        #expect(HTTP.route("/in") == .inbox(token: nil, item: nil))
        #expect(HTTP.route("/in/tok/a/b") == .inbox(token: nil, item: nil))
        #expect(HTTP.query("/in/t/clipboard?title=Build%20log&x") == ["title": "Build log", "x": ""])
    }

    @Test func sanitizeFilename() {
        #expect(HTTP.sanitizeFilename("report.pdf") == "report.pdf")
        #expect(HTTP.sanitizeFilename("../../etc/passwd") == "passwd")
        #expect(HTTP.sanitizeFilename("..\\\\x\\\\y.txt") == "y.txt")
        #expect(HTTP.sanitizeFilename(".hidden") == "hidden")
        #expect(HTTP.sanitizeFilename("a\u{0}b:c\nd") == "abcd")
        #expect(HTTP.sanitizeFilename("..") == nil)
        #expect(HTTP.sanitizeFilename("/") == nil)
        #expect(HTTP.sanitizeFilename("") == nil)
        let long = String(repeating: "x", count: 300) + ".log"
        #expect(HTTP.sanitizeFilename(long)?.count == 194)
    }

    @Test func chunkedDecoder() throws {
        let wire = Data("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nTrailer: x\r\n\r\nGARBAGE".utf8)
        // Byte-at-a-time to cover every state boundary.
        var d = ChunkedDecoder()
        var out = Data()
        for b in wire { out += try d.feed(Data([b])) }
        #expect(String(decoding: out, as: UTF8.self) == "hello world")
        #expect(d.isDone)

        var whole = ChunkedDecoder()
        let decoded = try whole.feed(wire)
        #expect(decoded == Data("hello world".utf8))

        #expect(throws: (any Error).self) {
            var bad = ChunkedDecoder()
            _ = try bad.feed(Data("zz\r\n".utf8))
        }
        #expect(throws: (any Error).self) {
            var bad2 = ChunkedDecoder()
            _ = try bad2.feed(Data("2\r\nabX\r\n".utf8))
        }
    }

    @Test func subnets() {
        let s = Subnet(cidr: "192.168.5.0/24")!
        #expect(s.description == "192.168.5.0/24")
        #expect(s.contains(Subnet.parseIPv4("192.168.5.20")!))
        #expect(!s.contains(Subnet.parseIPv4("192.168.9.1")!))
        #expect(Subnet.parseIPv4("::ffff:192.168.5.1") == Subnet.parseIPv4("192.168.5.1"))
        #expect(Subnet.parseIPv4("192.168.5.1%en0") == Subnet.parseIPv4("192.168.5.1"))
        #expect(Subnet.parseIPv4("fe80::1") == nil)
        #expect(Subnet(cidr: "1.2.3.4/33") == nil)
        #expect(Subnet(cidr: "10.1.2.3")?.description == "10.1.2.3/32")
        #expect(!LocalAddress.localSubnets().isEmpty)
    }

    @Test func authorizeAndAllow() {
        let inbox = Inbox(root: URL(fileURLWithPath: "/nonexistent"), token: "abcdefghijklmnopqrstuv",
                          subnets: [Subnet(cidr: "192.168.5.0/24")!]) { _ in }
        #expect(inbox.authorize("abcdefghijklmnopqrstuv"))
        #expect(!inbox.authorize("abcdefghijklmnopqrstuX"))
        #expect(!inbox.authorize("abc"))
        #expect(!inbox.authorize(""))
        #expect(inbox.allows("192.168.5.20"))
        #expect(inbox.allows("::ffff:192.168.5.20"))
        #expect(inbox.allows("127.0.0.1"))
        #expect(!inbox.allows("192.168.9.5"))
        #expect(!inbox.allows("8.8.8.8"))
        #expect(!inbox.allows("fe80::1"))
    }

    @Test func uniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("a (2).txt"))
        #expect(Inbox.unique("a.txt", in: dir).lastPathComponent == "a (3).txt")
        #expect(Inbox.unique("b", in: dir).lastPathComponent == "b")
    }
}

/// End-to-end inbox tests: real server on loopback, driven with curl.
@Suite final class InboxServerTests {
    let token = "TESTtoken_0123456789ab"
    let root: URL
    let server: HTTPServer
    let inbox: Inbox
    let port: UInt16
    let got = Got()

    final class Got: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Received] = []
        func add(_ r: Received) { lock.withLock { items.append(r) } }
        var all: [Received] { lock.withLock { items } }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let got = self.got
        inbox = Inbox(root: root, token: token, maxFileBytes: 4 << 20) { got.add($0) }
        port = UInt16.random(in: 40000...60000)
        server = try HTTPServer(port: port, store: GistStore(), inbox: inbox)
        let ready = DispatchSemaphore(value: 0)
        server.start { if case .ready = $0 { ready.signal() } }
        guard ready.wait(timeout: .now() + 5) == .success else { throw ServerNotReady() }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    var base: String { "http://127.0.0.1:\(port)/in/\(token)" }

    /// Runs curl, returns (status, body). `-w` puts the status on the last line.
    func curl(_ args: [String], stdin: Data? = nil) throws -> (Int, String) {
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "10", "-w", "\n%{http_code}"] + args
        p.standardOutput = out
        p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(stdin) }
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let code = Int(lines.removeLast()) ?? -1
        return (code, lines.joined(separator: "\n"))
    }

    @Test func ping() throws {
        #expect(try curl(["\(base)/ping"]).0 == 200)
    }

    @Test func clipboard() throws {
        let (code, _) = try curl(["--data-binary", "@-", "-H", "Content-Type: text/plain", "\(base)/clipboard?title=Build%20log"],
                                 stdin: Data("héllo\nworld".utf8))
        #expect(code == 204)
        guard case .text(let t, let title) = got.all.first?.content else {
            Issue.record("no text received")
            return
        }
        #expect(t == "héllo\nworld")
        #expect(title == "Build log")
        #expect(got.all.first?.sender == "localhost")
    }

    @Test func clipboardTooLarge() throws {
        let big = Data(repeating: 0x61, count: Int(Inbox.defaultClipboardLimit) + 1)
        #expect(try curl(["--data-binary", "@-", "\(base)/clipboard"], stdin: big).0 == 413)
        #expect(got.all.isEmpty)
    }

    @Test func putFileWithContentLength() throws {
        let src = root.appendingPathComponent("src.bin")
        let payload = Data((0..<2_000_000).map { UInt8($0 % 253) })
        try payload.write(to: src)
        let (code, body) = try curl(["-T", src.path, "\(base)/report%20final.bin"])
        #expect(code == 201)
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let saved = URL(fileURLWithPath: json["saved"] as! String)
        #expect(json["bytes"] as? Int == payload.count)
        #expect(saved.lastPathComponent == "report final.bin")
        #expect(saved.deletingLastPathComponent().lastPathComponent == "From localhost")
        #expect(try Data(contentsOf: saved) == payload)

        // Same name again: no overwrite.
        let (code2, body2) = try curl(["-T", src.path, "\(base)/report%20final.bin"])
        #expect(code2 == 201)
        #expect(body2.contains("report final (2).bin"))
        #expect(got.all.count == 2)
        // Partial files are cleaned up.
        let partials = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".macgist-incoming").path)
        #expect(partials.isEmpty)
    }

    @Test func putChunkedFromStdin() throws {
        let (code, body) = try curl(["-T", "-", "\(base)/notes.txt"], stdin: Data("streamed body".utf8))
        #expect(code == 201)
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        #expect(try String(contentsOfFile: json["saved"] as! String) == "streamed body")
    }

    @Test func fileTooLarge() throws {
        let src = root.appendingPathComponent("big.bin")
        try Data(count: 5 << 20).write(to: src)
        #expect(try curl(["-T", src.path, "\(base)/big.bin"]).0 == 413)
        #expect(try curl(["-T", "-", "\(base)/big.bin"], stdin: Data(count: 5 << 20)).0 == 413)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("From localhost/big.bin").path))
    }

    @Test func forbidden() throws {
        let wrong = "http://127.0.0.1:\(port)/in/WRONGtoken_0123456789a"
        #expect(try curl(["\(wrong)/ping"]).0 == 403)
        #expect(try curl(["--data-binary", "x", "\(wrong)/clipboard"]).0 == 403)
        #expect(try curl(["http://127.0.0.1:\(port)/in"]).0 == 403)
        #expect(try curl(["http://127.0.0.1:\(port)/in/\(token)/a/b"]).0 == 403)
        inbox.enabled = false
        #expect(try curl(["\(base)/ping"]).0 == 403)
        #expect(got.all.isEmpty)
    }

    @Test func badRequests() throws {
        #expect(try curl(["-X", "PUT", "-H", "Content-Length:", "\(base)/x.txt"]).0 == 411)
        #expect(try curl(["--path-as-is", "-X", "PUT", "--data-binary", "x", "\(base)/.."]).0 == 400)
        #expect(try curl(["-X", "DELETE", "\(base)/x"]).0 == 405)
    }

    @Test func sendPage() throws {
        let (code, body) = try curl(["\(base)/"])
        #expect(code == 200)
        #expect(body.contains("Send to"))
        #expect(body.contains("'/in/\(token)/'"))
    }
}

@Suite struct PrivateRangeTests {
    @Test func privateRanges() {
        let inbox = Inbox(root: URL(fileURLWithPath: "/x"), token: "t", subnets: Subnet.privateRanges) { _ in }
        for ip in ["192.168.5.20", "192.168.10.5", "192.168.200.1", "10.1.2.3", "172.16.0.1", "172.31.255.254"] {
            #expect(inbox.allows(ip), Comment(rawValue: ip))
        }
        for ip in ["172.32.0.1", "8.8.8.8", "100.64.0.1", "193.168.1.1"] {
            #expect(!inbox.allows(ip), Comment(rawValue: ip))
        }
    }
}
