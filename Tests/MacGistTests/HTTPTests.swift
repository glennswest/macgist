import Foundation
import Testing
@testable import MacGistCore

@Suite struct HTTPTests {
    @Test func parseRequest() {
        let r = HTTP.parse(Data("GET /g/abc HTTP/1.1\r\nHost: x:1\r\nRange: bytes=0-1".utf8))
        #expect(r?.method == "GET")
        #expect(r?.path == "/g/abc")
        #expect(r?.headers["host"] == "x:1")
        #expect(r?.headers["range"] == "bytes=0-1")
        #expect(HTTP.parse(Data("garbage".utf8)) == nil)
        #expect(HTTP.parse(Data("GET / SPDY/3".utf8)) == nil)
    }

    @Test func routes() {
        #expect(HTTP.route("/g/Ab-_9") == .page("Ab-_9"))
        #expect(HTTP.route("/g/tok/?x=1") == .page("tok"))
        #expect(HTTP.route("/g/tok/raw/2/a%20b.txt") == .raw("tok", 2))
        #expect(HTTP.route("/g/tok/dl/0") == .download("tok", 0))
        #expect(HTTP.route("/g/tok/zip/all.zip") == .archive("tok"))
        #expect(HTTP.route("/") == nil)
        #expect(HTTP.route("/g/tok/raw/x") == nil)
        #expect(HTTP.route("/g/tok/raw/-1") == nil)
        #expect(HTTP.route("/g/to.k") == nil)
        #expect(HTTP.route("/x/tok") == nil)
    }

    @Test func ranges() {
        #expect(HTTP.parseRange(nil, size: 10) == .full)
        #expect(HTTP.parseRange("bytes=0-4", size: 10) == .partial(start: 0, end: 4))
        #expect(HTTP.parseRange("bytes=5-", size: 10) == .partial(start: 5, end: 9))
        #expect(HTTP.parseRange("bytes=-3", size: 10) == .partial(start: 7, end: 9))
        #expect(HTTP.parseRange("bytes=-30", size: 10) == .partial(start: 0, end: 9))
        #expect(HTTP.parseRange("bytes=2-99", size: 10) == .partial(start: 2, end: 9))
        #expect(HTTP.parseRange("bytes=10-", size: 10) == .unsatisfiable)
        #expect(HTTP.parseRange("bytes=0-1,4-5", size: 10) == .full)
        #expect(HTTP.parseRange("bytes=5-2", size: 10) == .full)
        #expect(HTTP.parseRange("items=0-1", size: 10) == .full)
    }

    @Test func escapingAndDisposition() {
        #expect(HTTP.escapeHTML("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
        #expect(HTTP.encodePathSegment("a b/ü.txt") == "a%20b%2F%C3%BC.txt")
        #expect(HTTP.contentDisposition(filename: "ü \"q\".txt") ==
                "attachment; filename=\"_ _q_.txt\"; filename*=UTF-8''%C3%BC%20%22q%22.txt")
        #expect(HTTP.contentDisposition(filename: "a", inline: true).hasPrefix("inline;"))
    }

    @Test func tokenIsURLSafeAndUnique() {
        let a = GistStore.makeToken(), b = GistStore.makeToken()
        #expect(a != b)
        #expect(a.count == 22)
        #expect(HTTP.route("/g/\(a)") != nil)
    }
}
