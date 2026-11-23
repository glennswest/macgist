import Foundation
import Testing
@testable import MacGistCore

@Suite final class SettingsTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macgist-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func lifetimeIsConfigurable() throws {
        let now = Date()
        let g = try GistBuilder(tempRoot: dir, lifetime: 90).build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "b", now: now)
        #expect(g.expires.timeIntervalSince(now) == 90)
    }

    @Test func extend() throws {
        let store = GistStore()
        let now = Date()
        let g = try GistBuilder(tempRoot: dir, lifetime: 60).build(snippets: [.init(name: "a.txt", text: "x")], baseURL: "b", now: now)
        store.add(g)
        // From the current expiry when still live…
        #expect(store.extend(g.token, by: 600, now: now)?.timeIntervalSince(now) == 660)
        #expect(store.lookup(g.token, at: now.addingTimeInterval(650)) != nil)
        // …and nothing for expired or unknown gists.
        #expect(store.extend(g.token, by: 600, now: now.addingTimeInterval(700)) == nil)
        #expect(store.extend("nope", by: 600) == nil)
    }

    @Test func inlineLimitIsConfigurable() throws {
        let f = dir.appendingPathComponent("t.txt")
        try Data(repeating: 0x61, count: 2048).write(to: f)
        #expect(try GistEntry(name: "t.txt", fileURL: f, inlineLimit: 4096).kind == .text)
        #expect(try GistEntry(name: "t.txt", fileURL: f, inlineLimit: 1024).kind == .binary)
    }

    @Test func highlighterCanBeOffOrMoved() throws {
        let g = try GistBuilder(tempRoot: dir).build(snippets: [.init(name: "a.py", text: "x=1")], baseURL: "b")
        #expect(GistPage.render(g, sharedBy: "m").contains("cdnjs.cloudflare.com"))
        let off = GistPage.render(g, sharedBy: "m", highlightBase: "")
        #expect(!off.contains("highlight.min.js"))
        #expect(off.contains("x=1"))
        let local = GistPage.render(g, sharedBy: "m", highlightBase: "http://intranet/hljs/")
        #expect(local.contains("src=\"http://intranet/hljs/highlight.min.js\""))
    }

    @Test func linkHostChoices() {
        #expect(LocalAddress.linkHost(for: "") == LocalAddress.primaryIPv4())
        #expect(LocalAddress.linkHost(for: "auto") == LocalAddress.primaryIPv4())
        #expect(LocalAddress.linkHost(for: "mac.example.lan") == "mac.example.lan")
        #expect(LocalAddress.linkHost(for: "10.1.2.3") == "10.1.2.3")
        #expect(LocalAddress.linkHost(for: "iface:nonexistent9") == nil)
        if let first = LocalAddress.interfaces().first {
            #expect(LocalAddress.linkHost(for: "iface:\(first.name)") == first.ip)
            #expect(LocalAddress.interfaces().filter(\.isPrimary).count <= 1)
        }
        #expect(LocalAddress.bonjourName()?.hasSuffix(".local") == true)
    }

    @Test func inboxLimitsAndRootAreLive() {
        let inbox = Inbox(root: dir, token: "t") { _ in }
        #expect(inbox.clipboardLimit == Inbox.defaultClipboardLimit)
        inbox.clipboardLimit = 10
        inbox.root = dir.appendingPathComponent("elsewhere")
        #expect(inbox.clipboardLimit == 10)
        #expect(inbox.root.lastPathComponent == "elsewhere")
    }
}
