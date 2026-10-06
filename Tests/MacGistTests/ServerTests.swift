import XCTest
@testable import MacGistCore

/// End-to-end: a real server on a loopback port, fetched with URLSession.
final class ServerTests: XCTestCase {
    var dir: URL!
    var store: GistStore!
    var server: HTTPServer!
    var port: UInt16 = 0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-srv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = GistStore()
        port = UInt16.random(in: 40000...60000)
        server = try HTTPServer(port: port, store: store)
        let ready = expectation(description: "ready")
        server.start { if case .ready = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 5)
    }

    override func tearDownWithError() throws {
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

    func testPageRawDownloadRangeArchive() async throws {
        let g = try makeGist()

        let (s1, page, r1) = try await fetch("/g/\(g.token)", headers: ["Accept": "text/html"])
        XCTAssertEqual(s1, 200)
        XCTAssertEqual(r1.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("print(&#39;hi&#39;)"))
        XCTAssertTrue(html.contains("Download all (.zip)"))

        // curl-style request to a multi-file gist gets a URL listing.
        let (_, listing, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "*/*"])
        XCTAssertTrue(String(decoding: listing, as: UTF8.self).contains("/g/\(g.token)/raw/0/hello.py"))

        let (s2, raw, r2) = try await fetch("/g/\(g.token)/raw/0/hello.py")
        XCTAssertEqual(s2, 200)
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "print('hi')\n")
        XCTAssertEqual(r2.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")

        let (s3, bin, r3) = try await fetch("/g/\(g.token)/dl/1/data.bin")
        XCTAssertEqual(s3, 200)
        XCTAssertEqual(bin, try Data(contentsOf: g.entries[1].fileURL))
        XCTAssertTrue(r3.value(forHTTPHeaderField: "Content-Disposition")!.hasPrefix("attachment;"))

        let (s4, part, r4) = try await fetch("/g/\(g.token)/dl/1/data.bin", headers: ["Range": "bytes=2999990-"])
        XCTAssertEqual(s4, 206)
        XCTAssertEqual(part.count, 10)
        XCTAssertEqual(r4.value(forHTTPHeaderField: "Content-Range"), "bytes 2999990-2999999/3000000")

        let (s5, zip, _) = try await fetch("/g/\(g.token)/zip/x.zip")
        XCTAssertEqual(s5, 200)
        XCTAssertEqual(zip.prefix(2), Data("PK".utf8))

        XCTAssertGreaterThanOrEqual(store.lookup(g.token)!.hits, 3)
        g.cleanUp()
    }

    func testSingleFileGistServesRawToCurl() async throws {
        let g = try GistBuilder(tempRoot: dir.appendingPathComponent("tmp"))
            .build(snippets: [.init(name: "a.txt", text: "just text")], baseURL: "x")
        store.add(g)
        let (s, body, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "*/*"])
        XCTAssertEqual(s, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "just text")
        g.cleanUp()
    }

    func testUnknownAndRevoked() async throws {
        let (s1, _, _) = try await fetch("/g/nope")
        XCTAssertEqual(s1, 404)
        let (s2, _, _) = try await fetch("/")
        XCTAssertEqual(s2, 404)

        let g = try makeGist()
        store.remove(g.token)
        let (s3, body, _) = try await fetch("/g/\(g.token)", headers: ["Accept": "text/html"])
        XCTAssertEqual(s3, 404)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("This gist has expired"))
        let (s4, _, _) = try await fetch("/g/\(g.token)/raw/0/hello.py")
        XCTAssertEqual(s4, 404)
        g.cleanUp()
    }

    func testOutOfRangeIndex() async throws {
        let g = try makeGist()
        let (s, _, _) = try await fetch("/g/\(g.token)/raw/9/x")
        XCTAssertEqual(s, 404)
        g.cleanUp()
    }
}
