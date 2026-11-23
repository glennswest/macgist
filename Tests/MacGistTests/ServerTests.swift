import Foundation
import Testing
@testable import MacGistCore

struct ServerNotReady: Error {}

/// End-to-end: a real server on a loopback port, fetched with URLSession.
@Suite final class ServerTests {
    let dir: URL
    let store: GistStore
    let server: HTTPServer
    let port: UInt16

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-srv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = GistStore()
        port = UInt16.random(in: 40000...60000)
        server = try HTTPServer(port: port, store: store)
        let ready = DispatchSemaphore(value: 0)
        server.start { if case .ready = $0 { ready.signal() } }
        guard ready.wait(timeout: .now() + 5) == .success else { throw ServerNotReady() }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func fetch(_ path: String, headers: [String: String] = [:]) async throws -> (Int, Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        return (http.statusCode, data, http)
    }

    func makeGist() throws -> Gist {
        let file = dir.appendingPathComponent("data.bin")
        try Data((0..<3_000_000).map { UInt8($0 % 251) }).write(to: file)
        let g = try GistBuilder(tempRoot: dir.appendingPathComponent("tmp"))
            .build(snippets: [.init(name: "hello.py", text: "print('hi')\n")], files: [file], baseURL: "http://127.0.0.1:\(port)")
        store.add(g)
        return g
    }

    @Test func pageRawDownloadRangeArchive() async throws {
        let g = try makeGist()

        let (s1, page, r1) = try await fetch("/g/\(g.token)", headers: ["Accept": "text/html"])
        #expect(s1 == 200)
        #expect(r1.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        let html = String(decoding: page, as: UTF8.self)
        #expect(html.contains("print(&#39;hi&#39;)"))
        #expect(html.contains("Download all (.zip)"))

        // curl-style request to a multi-file gist gets a URL listing.
        let (_, listing, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "*/*"])
        #expect(String(decoding: listing, as: UTF8.self).contains("/g/\(g.token)/raw/0/hello.py"))

        let (s2, raw, r2) = try await fetch("/g/\(g.token)/raw/0/hello.py")
        #expect(s2 == 200)
        #expect(String(decoding: raw, as: UTF8.self) == "print('hi')\n")
        #expect(r2.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")

        let (s3, bin, r3) = try await fetch("/g/\(g.token)/dl/1/data.bin")
        #expect(s3 == 200)
        #expect(bin == (try Data(contentsOf: g.entries[1].fileURL)))
        #expect(r3.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment;") == true)

        let (s4, part, r4) = try await fetch("/g/\(g.token)/dl/1/data.bin", headers: ["Range": "bytes=2999990-"])
        #expect(s4 == 206)
        #expect(part.count == 10)
        #expect(r4.value(forHTTPHeaderField: "Content-Range") == "bytes 2999990-2999999/3000000")

        let (s5, zip, _) = try await fetch("/g/\(g.token)/zip/x.zip")
        #expect(s5 == 200)
        #expect(zip.prefix(2) == Data("PK".utf8))

        #expect(store.lookup(g.token)!.hits >= 3)
        g.cleanUp()
    }

    @Test func singleFileGistServesRawToCurl() async throws {
        let g = try GistBuilder(tempRoot: dir.appendingPathComponent("tmp"))
            .build(snippets: [.init(name: "a.txt", text: "just text")], baseURL: "x")
        store.add(g)
        let (s, body, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "*/*"])
        #expect(s == 200)
        #expect(String(decoding: body, as: UTF8.self) == "just text")
        g.cleanUp()
    }

    @Test func unknownAndRevoked() async throws {
        let (s1, _, _) = try await fetch("/g/nope")
        #expect(s1 == 404)
        let (s2, _, _) = try await fetch("/")
        #expect(s2 == 404)

        let g = try makeGist()
        store.remove(g.token)
        let (s3, body, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "text/html"])
        #expect(s3 == 404)
        #expect(String(decoding: body, as: UTF8.self).contains("This gist has expired"))
        let (s4, _, _) = try await fetch("/g/\(g.token)/raw/0/hello.py")
        #expect(s4 == 404)
        g.cleanUp()
    }

    @Test func outOfRangeIndex() async throws {
        let g = try makeGist()
        let (s, _, _) = try await fetch("/g/\(g.token)/raw/9/x")
        #expect(s == 404)
        g.cleanUp()
    }
}
