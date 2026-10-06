import XCTest
@testable import MacGistCore

final class InboxUnitTests: XCTestCase {
    func testInboxRoutes() {
        XCTAssertEqual(HTTP.route("/in/tok"), .inbox(token: "tok", item: nil))
        XCTAssertEqual(HTTP.route("/in/tok/"), .inbox(token: "tok", item: nil))
        XCTAssertEqual(HTTP.route("/in/tok/ping"), .inbox(token: "tok", item: "ping"))
        XCTAssertEqual(HTTP.route("/in/tok/clipboard?title=hi"), .inbox(token: "tok", item: "clipboard"))
        XCTAssertEqual(HTTP.route("/in/tok/a%20b.txt"), .inbox(token: "tok", item: "a b.txt"))
        XCTAssertEqual(HTTP.route("/in"), .inbox(token: nil, item: nil))
        XCTAssertEqual(HTTP.route("/in/tok/a/b"), .inbox(token: nil, item: nil))
        XCTAssertEqual(HTTP.query("/in/t/clipboard?title=Build%20log&x"), ["title": "Build log", "x": ""])
    }

    func testSanitizeFilename() {
        XCTAssertEqual(HTTP.sanitizeFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(HTTP.sanitizeFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(HTTP.sanitizeFilename("..\\\\x\\\\y.txt"), "y.txt")
        XCTAssertEqual(HTTP.sanitizeFilename(".hidden"), "hidden")
        XCTAssertEqual(HTTP.sanitizeFilename("a\u{0}b:c\nd"), "abcd")
        XCTAssertNil(HTTP.sanitizeFilename(".."))
        XCTAssertNil(HTTP.sanitizeFilename("/"))
        XCTAssertNil(HTTP.sanitizeFilename(""))
        let long = String(repeating: "x", count: 300) + ".log"
        XCTAssertEqual(HTTP.sanitizeFilename(long)?.count, 194)
    }

    func testChunkedDecoder() throws {
        let wire = Data("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nTrailer: x\r\n\r\nGARBAGE".utf8)
        // Byte-at-a-time to cover every state boundary.
        var d = ChunkedDecoder()
        var out = Data()
        for b in wire { out += try d.feed(Data([b])) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello world")
        XCTAssertTrue(d.isDone)

        var whole = ChunkedDecoder()
        XCTAssertEqual(try whole.feed(wire), Data("hello world".utf8))

        var bad = ChunkedDecoder()
        XCTAssertThrowsError(try bad.feed(Data("zz\r\n".utf8)))
        var bad2 = ChunkedDecoder()
        XCTAssertThrowsError(try bad2.feed(Data("2\r\nabX\r\n".utf8)))
    }

    func testSubnets() {
        let s = Subnet(cidr: "192.168.5.0/24")!
        XCTAssertEqual(s.description, "192.168.5.0/24")
        XCTAssertTrue(s.contains(Subnet.parseIPv4("192.168.5.20")!))
        XCTAssertFalse(s.contains(Subnet.parseIPv4("192.168.9.1")!))
        XCTAssertEqual(Subnet.parseIPv4("::ffff:192.168.5.1"), Subnet.parseIPv4("192.168.5.1"))
        XCTAssertEqual(Subnet.parseIPv4("192.168.5.1%en0"), Subnet.parseIPv4("192.168.5.1"))
        XCTAssertNil(Subnet.parseIPv4("fe80::1"))
        XCTAssertNil(Subnet(cidr: "1.2.3.4/33"))
        XCTAssertEqual(Subnet(cidr: "10.1.2.3")?.description, "10.1.2.3/32")
        XCTAssertFalse(LocalAddress.localSubnets().isEmpty)
    }

    func testAuthorizeAndAllow() {
        let inbox = Inbox(root: URL(fileURLWithPath: "/nonexistent"), token: "abcdefghijklmnopqrstuv",
                          subnets: [Subnet(cidr: "192.168.5.0/24")!]) { _ in }
        XCTAssertTrue(inbox.authorize("abcdefghijklmnopqrstuv"))
        XCTAssertFalse(inbox.authorize("abcdefghijklmnopqrstuX"))
        XCTAssertFalse(inbox.authorize("abc"))
        XCTAssertFalse(inbox.authorize(""))
        XCTAssertTrue(inbox.allows("192.168.5.20"))
        XCTAssertTrue(inbox.allows("::ffff:192.168.5.20"))
        XCTAssertTrue(inbox.allows("127.0.0.1"))
        XCTAssertFalse(inbox.allows("192.168.9.5"))
        XCTAssertFalse(inbox.allows("8.8.8.8"))
        XCTAssertFalse(inbox.allows("fe80::1"))
    }

    func testUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("a (2).txt"))
        XCTAssertEqual(Inbox.unique("a.txt", in: dir).lastPathComponent, "a (3).txt")
        XCTAssertEqual(Inbox.unique("b", in: dir).lastPathComponent, "b")
    }
}

/// End-to-end inbox tests: real server on loopback, driven with curl.
final class InboxServerTests: XCTestCase {
    let token = "TESTtoken_0123456789ab"
    var root: URL!
    var server: HTTPServer!
    var inbox: Inbox!
    var port: UInt16 = 0
    let got = Got()

    final class Got: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Received] = []
        func add(_ r: Received) { lock.withLock { items.append(r) } }
        var all: [Received] { lock.withLock { items } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let got = self.got
        inbox = Inbox(root: root, token: token, maxFileBytes: 4 << 20) { got.add($0) }
        port = UInt16.random(in: 40000...60000)
        server = try HTTPServer(port: port, store: GistStore(), inbox: inbox)
        let ready = expectation(description: "ready")
        server.start { if case .ready = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 5)
    }

    override func tearDownWithError() throws {
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

    func testPing() throws {
        XCTAssertEqual(try curl(["\(base)/ping"]).0, 200)
    }

    func testClipboard() throws {
        let (code, _) = try curl(["--data-binary", "@-", "-H", "Content-Type: text/plain", "\(base)/clipboard?title=Build%20log"],
                                 stdin: Data("héllo\nworld".utf8))
        XCTAssertEqual(code, 204)
        guard case .text(let t, let title) = got.all.first?.content else { return XCTFail("no text received") }
        XCTAssertEqual(t, "héllo\nworld")
        XCTAssertEqual(title, "Build log")
        XCTAssertEqual(got.all.first?.sender, "localhost")
    }

    func testClipboardTooLarge() throws {
        let big = Data(repeating: 0x61, count: Int(Inbox.defaultClipboardLimit) + 1)
        XCTAssertEqual(try curl(["--data-binary", "@-", "\(base)/clipboard"], stdin: big).0, 413)
        XCTAssertTrue(got.all.isEmpty)
    }

    func testPutFileWithContentLength() throws {
        let src = root.appendingPathComponent("src.bin")
        let payload = Data((0..<2_000_000).map { UInt8($0 % 253) })
        try payload.write(to: src)
        let (code, body) = try curl(["-T", src.path, "\(base)/report%20final.bin"])
        XCTAssertEqual(code, 201)
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let saved = URL(fileURLWithPath: json["saved"] as! String)
        XCTAssertEqual(json["bytes"] as? Int, payload.count)
        XCTAssertEqual(saved.lastPathComponent, "report final.bin")
        XCTAssertEqual(saved.deletingLastPathComponent().lastPathComponent, "From localhost")
        XCTAssertEqual(try Data(contentsOf: saved), payload)

        // Same name again: no overwrite.
        let (code2, body2) = try curl(["-T", src.path, "\(base)/report%20final.bin"])
        XCTAssertEqual(code2, 201)
        XCTAssertTrue(body2.contains("report final (2).bin"))
        XCTAssertEqual(got.all.count, 2)
        // Partial files are cleaned up.
        let partials = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".macgist-incoming").path)
        XCTAssertTrue(partials.isEmpty)
    }

    func testPutChunkedFromStdin() throws {
        let (code, body) = try curl(["-T", "-", "\(base)/notes.txt"], stdin: Data("streamed body".utf8))
        XCTAssertEqual(code, 201)
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        XCTAssertEqual(try String(contentsOfFile: json["saved"] as! String), "streamed body")
    }

    func testFileTooLarge() throws {
        let src = root.appendingPathComponent("big.bin")
        try Data(count: 5 << 20).write(to: src)
        XCTAssertEqual(try curl(["-T", src.path, "\(base)/big.bin"]).0, 413)
        XCTAssertEqual(try curl(["-T", "-", "\(base)/big.bin"], stdin: Data(count: 5 << 20)).0, 413)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("From localhost/big.bin").path))
    }

    func testForbidden() throws {
        let wrong = "http://127.0.0.1:\(port)/in/WRONGtoken_0123456789a"
        XCTAssertEqual(try curl(["\(wrong)/ping"]).0, 403)
        XCTAssertEqual(try curl(["--data-binary", "x", "\(wrong)/clipboard"]).0, 403)
        XCTAssertEqual(try curl(["http://127.0.0.1:\(port)/in"]).0, 403)
        XCTAssertEqual(try curl(["http://127.0.0.1:\(port)/in/\(token)/a/b"]).0, 403)
        inbox.enabled = false
        XCTAssertEqual(try curl(["\(base)/ping"]).0, 403)
        XCTAssertTrue(got.all.isEmpty)
    }

    func testBadRequests() throws {
        XCTAssertEqual(try curl(["-X", "PUT", "-H", "Content-Length:", "\(base)/x.txt"]).0, 411)
        XCTAssertEqual(try curl(["--path-as-is", "-X", "PUT", "--data-binary", "x", "\(base)/.."]).0, 400)
        XCTAssertEqual(try curl(["-X", "DELETE", "\(base)/x"]).0, 405)
    }

    func testSendPage() throws {
        let (code, body) = try curl(["\(base)/"])
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains("Send to"))
        XCTAssertTrue(body.contains("'/in/\(token)/'"))
    }
}

final class PrivateRangeTests: XCTestCase {
    func testPrivateRanges() {
        let inbox = Inbox(root: URL(fileURLWithPath: "/x"), token: "t", subnets: Subnet.privateRanges) { _ in }
        for ip in ["192.168.5.20", "192.168.10.5", "192.168.200.1", "10.1.2.3", "172.16.0.1", "172.31.255.254"] {
            XCTAssertTrue(inbox.allows(ip), ip)
        }
        for ip in ["172.32.0.1", "8.8.8.8", "100.64.0.1", "193.168.1.1"] {
            XCTAssertFalse(inbox.allows(ip), ip)
        }
    }
}
