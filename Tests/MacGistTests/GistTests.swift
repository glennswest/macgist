import XCTest
@testable import MacGistCore

final class GistTests: XCTestCase {
    var dir: URL!
    var builder: GistBuilder!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        builder = GistBuilder(tempRoot: dir.appendingPathComponent("tmp"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testEntryKinds() throws {
        XCTAssertEqual(try GistEntry(name: "a.swift", fileURL: write("a.swift", Data("let x = 1\n".utf8))).kind, .text)
        XCTAssertEqual(try GistEntry(name: "noext", fileURL: write("noext", Data("hello".utf8))).kind, .text)
        XCTAssertEqual(try GistEntry(name: "b.bin", fileURL: write("b.bin", Data([0, 1, 2, 0xff]))).kind, .binary)
        XCTAssertEqual(try GistEntry(name: "c.png", fileURL: write("c.png", Data([0x89, 0x50]))).kind, .image)
        let big = Data(repeating: 0x61, count: Int(GistEntry.inlineTextLimit) + 1)
        XCTAssertEqual(try GistEntry(name: "big.txt", fileURL: write("big.txt", big)).kind, .binary)
        // UTF-8 sequence split at the 8 KiB sniff boundary is still text.
        let split = Data(repeating: 0x61, count: 8191) + Data("é".utf8)
        XCTAssertEqual(try GistEntry(name: "s.txt", fileURL: write("s.txt", split)).kind, .text)
    }

    func testBuildMixedGist() throws {
        let file = try write("notes.md", Data("# hi".utf8))
        let folder = dir.appendingPathComponent("proj")
        _ = try write("proj/main.c", Data("int main(){}".utf8))
        let g = try builder.build(snippets: [.init(name: "snippet.txt", text: "abc"), .init(name: "empty", text: "")],
                                  files: [file, folder], baseURL: "http://h:1")
        XCTAssertEqual(g.entries.map(\.name), ["snippet.txt", "notes.md", "proj.zip"])
        XCTAssertEqual(g.title, "snippet.txt + 2 more")
        XCTAssertEqual(g.link, "http://h:1/g/\(g.token)")
        XCTAssertEqual(g.expires.timeIntervalSince(g.created), 15 * 60)
        XCTAssertEqual(try String(contentsOf: g.entries[0].fileURL), "abc")
        XCTAssertEqual(g.entries[1].fileURL, file)  // served in place, not copied
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.entries[2].fileURL.path))

        let archive = try GistStore().archive(for: g)
        let list = try run("/usr/bin/unzip", ["-Z1", archive.path])
        XCTAssertTrue(list.contains("snippet.txt"))
        XCTAssertTrue(list.contains("notes.md"))
        XCTAssertTrue(list.contains("proj/main.c"))

        g.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.tempDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testBuildDataFileGist() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let g = try builder.build(dataFiles: [.init(name: "Image 2026-11-23 at 09.41.12.png", data: bytes),
                                              .init(name: "empty.png", data: Data())],
                                  baseURL: "http://h:1")
        XCTAssertEqual(g.entries.map(\.name), ["Image 2026-11-23 at 09.41.12.png"])
        XCTAssertEqual(g.entries[0].kind, .image)
        XCTAssertEqual(g.entries[0].size, UInt64(bytes.count))
        XCTAssertEqual(g.title, "Image 2026-11-23 at 09.41.12.png")
        // Lives in the gist's temp dir, so it dies with the gist.
        XCTAssertTrue(g.entries[0].fileURL.path.hasPrefix(g.tempDir.path))
        XCTAssertEqual(g.sources, [g.entries[0].fileURL])
        g.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.entries[0].fileURL.path))
    }

    func testDuplicateNamesAreUniqued() throws {
        let a = try write("x/a.txt", Data("1".utf8))
        let b = try write("y/a.txt", Data("2".utf8))
        let g = try builder.build(files: [a, b], baseURL: "http://h:1")
        XCTAssertEqual(g.entries.map(\.name), ["a.txt", "a 2.txt"])
        g.cleanUp()
    }

    func testEmptyIsRejected() {
        XCTAssertThrowsError(try builder.build(snippets: [.init(name: "a", text: "")], baseURL: "http://h:1"))
    }

    func testStoreExpiry() throws {
        let store = GistStore()
        let now = Date()
        let g = try builder.build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "http://h:1", now: now)
        store.add(g)
        XCTAssertNotNil(store.lookup(g.token, at: now.addingTimeInterval(14 * 60)))
        XCTAssertNil(store.lookup(g.token, at: now.addingTimeInterval(15 * 60)))
        XCTAssertEqual(store.purgeExpired(at: now.addingTimeInterval(60)).count, 0)
        XCTAssertEqual(store.purgeExpired(at: now.addingTimeInterval(16 * 60)).map(\.token), [g.token])
        XCTAssertTrue(store.active.isEmpty)
        g.cleanUp()
    }

    func testPageEscapesContent() throws {
        let g = try builder.build(title: "<b>t</b>", snippets: [.init(name: "x.html", text: "<script>alert(1)</script>")],
                                  baseURL: "http://h:1")
        let html = GistPage.render(g, sharedBy: "mac")
        XCTAssertFalse(html.contains("<script>alert(1)"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;b&gt;t&lt;/b&gt;"))
        g.cleanUp()
    }

    @discardableResult
    func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }
}
