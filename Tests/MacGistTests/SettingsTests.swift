import XCTest
@testable import MacGistCore

final class SettingsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLifetimeIsConfigurable() throws {
        let now = Date()
        let g = try GistBuilder(tempRoot: dir, lifetime: 90).build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "b", now: now)
        XCTAssertEqual(g.expires.timeIntervalSince(now), 90)
    }

    func testExtend() throws {
        let store = GistStore()
        let now = Date()
        let g = try GistBuilder(tempRoot: dir, lifetime: 60).build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "b", now: now)
        store.add(g)
        // From the current expiry when still live…
        XCTAssertEqual(store.extend(g.token, by: 600, now: now)?.timeIntervalSince(now), 660)
        XCTAssertNotNil(store.lookup(g.token, at: now.addingTimeInterval(650)))
        // …and nothing for expired or unknown gists.
        XCTAssertNil(store.extend(g.token, by: 600, now: now.addingTimeInterval(700)))
        XCTAssertNil(store.extend("nope", by: 600))
    }

    func testInlineLimitIsConfigurable() throws {
        let f = dir.appendingPathComponent("t.txt")
        try Data(repeating: 0x61, count: 2048).write(to: f)
        XCTAssertEqual(try GistEntry(name: "t.txt", fileURL: f, inlineLimit: 4096).kind, .text)
        XCTAssertEqual(try GistEntry(name: "t.txt", fileURL: f, inlineLimit: 1024).kind, .binary)
    }

    func testHighlighterCanBeOffOrMoved() throws {
        let g = try GistBuilder(tempRoot: dir).build(snippets: [.init(name: "a.py", text: "x=1")], baseURL: "b")
        XCTAssertTrue(GistPage.render(g, sharedBy: "m").contains("cdnjs.cloudflare.com"))
        let off = GistPage.render(g, sharedBy: "m", highlightBase: "")
        XCTAssertFalse(off.contains("highlight.min.js"))
        XCTAssertTrue(off.contains("x=1"))
        let local = GistPage.render(g, sharedBy: "m", highlightBase: "http://intranet/hljs/")
        XCTAssertTrue(local.contains("src=\"http://intranet/hljs/highlight.min.js\""))
    }

    func testLinkHostChoices() {
        XCTAssertEqual(LocalAddress.linkHost(for: ""), LocalAddress.primaryIPv4())
        XCTAssertEqual(LocalAddress.linkHost(for: "auto"), LocalAddress.primaryIPv4())
        XCTAssertEqual(LocalAddress.linkHost(for: "mac.example.lan"), "mac.example.lan")
        XCTAssertEqual(LocalAddress.linkHost(for: "10.1.2.3"), "10.1.2.3")
        XCTAssertNil(LocalAddress.linkHost(for: "iface:nonexistent9"))
        if let first = LocalAddress.interfaces().first {
            XCTAssertEqual(LocalAddress.linkHost(for: "iface:\(first.name)"), first.ip)
            XCTAssertEqual(LocalAddress.interfaces().filter(\.isPrimary).count <= 1, true)
        }
        XCTAssertEqual(LocalAddress.bonjourName()?.hasSuffix(".local"), true)
    }

    func testInboxLimitsAndRootAreLive() {
        let inbox = Inbox(root: dir, token: "t") { _ in }
        XCTAssertEqual(inbox.clipboardLimit, Inbox.defaultClipboardLimit)
        inbox.clipboardLimit = 10
        inbox.root = dir.appendingPathComponent("elsewhere")
        XCTAssertEqual(inbox.clipboardLimit, 10)
        XCTAssertEqual(inbox.root.lastPathComponent, "elsewhere")
    }
}
