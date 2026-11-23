import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacGistCore

@Suite final class GistTests {
    let dir: URL
    let builder: GistBuilder

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        builder = GistBuilder(tempRoot: dir.appendingPathComponent("tmp"))
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @Test func entryKinds() throws {
        #expect(try GistEntry(name: "a.swift", fileURL: write("a.swift", Data("let x = 1\n".utf8))).kind == .text)
        #expect(try GistEntry(name: "noext", fileURL: write("noext", Data("hello".utf8))).kind == .text)
        #expect(try GistEntry(name: "b.bin", fileURL: write("b.bin", Data([0, 1, 2, 0xff]))).kind == .binary)
        #expect(try GistEntry(name: "c.png", fileURL: write("c.png", Data([0x89, 0x50]))).kind == .image)
        let big = Data(repeating: 0x61, count: Int(GistEntry.inlineTextLimit) + 1)
        #expect(try GistEntry(name: "big.txt", fileURL: write("big.txt", big)).kind == .binary)
        // UTF-8 sequence split at the 8 KiB sniff boundary is still text.
        let split = Data(repeating: 0x61, count: 8191) + Data("é".utf8)
        #expect(try GistEntry(name: "s.txt", fileURL: write("s.txt", split)).kind == .text)
    }

    @Test func buildMixedGist() throws {
        let file = try write("notes.md", Data("# hi".utf8))
        let folder = dir.appendingPathComponent("proj")
        _ = try write("proj/main.c", Data("int main(){}".utf8))
        let g = try builder.build(snippets: [.init(name: "snippet.txt", text: "abc"), .init(name: "empty", text: "")],
                                  files: [file, folder], baseURL: "http://h:1")
        #expect(g.entries.map(\.name) == ["snippet.txt", "notes.md", "proj.zip"])
        #expect(g.title == "snippet.txt + 2 more")
        #expect(g.link == "http://h:1/g/\(g.token)")
        #expect(g.expires.timeIntervalSince(g.created) == 15 * 60)
        #expect(try String(contentsOf: g.entries[0].fileURL) == "abc")
        #expect(g.entries[1].fileURL == file)  // served in place, not copied
        #expect(FileManager.default.fileExists(atPath: g.entries[2].fileURL.path))

        let archive = try GistStore().archive(for: g)
        let list = try run("/usr/bin/unzip", ["-Z1", archive.path])
        #expect(list.contains("snippet.txt"))
        #expect(list.contains("notes.md"))
        #expect(list.contains("proj/main.c"))

        g.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: g.tempDir.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func buildDataFileGist() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let g = try builder.build(dataFiles: [.init(name: "Image 2026-11-23 at 09.41.12.png", data: bytes),
                                              .init(name: "empty.png", data: Data())],
                                  baseURL: "http://h:1")
        #expect(g.entries.map(\.name) == ["Image 2026-11-23 at 09.41.12.png"])
        #expect(g.entries[0].kind == .image)
        #expect(g.entries[0].size == UInt64(bytes.count))
        #expect(g.title == "Image 2026-11-23 at 09.41.12.png")
        // Lives in the gist's temp dir, so it dies with the gist.
        #expect(g.entries[0].fileURL.path.hasPrefix(g.tempDir.path))
        #expect(g.sources == [g.entries[0].fileURL])
        g.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: g.entries[0].fileURL.path))
    }

    @Test func heicIsConvertedToJPEGAndNeverServed() throws {
        let heic = dir.appendingPathComponent("photo.heic")
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        try #require(CGImageDestinationFinalize(dest))

        let g = try builder.build(files: [heic], baseURL: "http://h:1")
        #expect(g.entries.map(\.name) == ["photo.jpg"])
        #expect(g.entries[0].kind == .image)
        #expect(g.entries[0].fileURL.path.hasPrefix(g.tempDir.path))
        // "Download all" gets the JPEG too, not the original HEIC.
        #expect(g.sources == [g.entries[0].fileURL])
        let head = try Data(contentsOf: g.entries[0].fileURL).prefix(3)
        #expect(head == Data([0xff, 0xd8, 0xff]))
        g.cleanUp()
        #expect(FileManager.default.fileExists(atPath: heic.path))

        #expect(GistBuilder.jpegData(fromImageData: try Data(contentsOf: heic))?.prefix(3) == Data([0xff, 0xd8, 0xff]))
        #expect(GistBuilder.jpegData(fromImageData: Data("not an image".utf8)) == nil)
    }

    @Test func duplicateNamesAreUniqued() throws {
        let a = try write("x/a.txt", Data("1".utf8))
        let b = try write("y/a.txt", Data("2".utf8))
        let g = try builder.build(files: [a, b], baseURL: "http://h:1")
        #expect(g.entries.map(\.name) == ["a.txt", "a 2.txt"])
        g.cleanUp()
    }

    @Test func emptyIsRejected() {
        #expect(throws: (any Error).self) {
            try self.builder.build(snippets: [.init(name: "a", text: "")], baseURL: "http://h:1")
        }
    }

    @Test func storeExpiry() throws {
        let store = GistStore()
        let now = Date()
        let g = try builder.build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "http://h:1", now: now)
        store.add(g)
        #expect(store.lookup(g.token, at: now.addingTimeInterval(14 * 60)) != nil)
        #expect(store.lookup(g.token, at: now.addingTimeInterval(15 * 60)) == nil)
        #expect(store.purgeExpired(at: now.addingTimeInterval(60)).count == 0)
        #expect(store.purgeExpired(at: now.addingTimeInterval(16 * 60)).map(\.token) == [g.token])
        #expect(store.active.isEmpty)
        g.cleanUp()
    }

    @Test func pageEscapesContent() throws {
        let g = try builder.build(title: "<b>t</b>", snippets: [.init(name: "x.html", text: "<script>alert(1)</script>")],
                                  baseURL: "http://h:1")
        let html = GistPage.render(g, sharedBy: "mac")
        #expect(!html.contains("<script>alert(1)"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("&lt;b&gt;t&lt;/b&gt;"))
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
