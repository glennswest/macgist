import XCTest
@testable import MacGistCore

final class HTTPTests: XCTestCase {
    func testParseRequest() {
        let r = HTTP.parse(Data("GET /g/abc HTTP/1.1\r\nHost: x:1\r\nRange: bytes=0-1".utf8))
        XCTAssertEqual(r?.method, "GET")
        XCTAssertEqual(r?.path, "/g/abc")
        XCTAssertEqual(r?.headers["host"], "x:1")
        XCTAssertEqual(r?.headers["range"], "bytes=0-1")
        XCTAssertNil(HTTP.parse(Data("garbage".utf8)))
        XCTAssertNil(HTTP.parse(Data("GET / SPDY/3".utf8)))
    }

    func testRoutes() {
        XCTAssertEqual(HTTP.route("/g/Ab-_9"), .page("Ab-_9"))
        XCTAssertEqual(HTTP.route("/g/tok/?x=1"), .page("tok"))
        XCTAssertEqual(HTTP.route("/g/tok/raw/2/a%20b.txt"), .raw("tok", 2))
        XCTAssertEqual(HTTP.route("/g/tok/dl/0"), .download("tok", 0))
        XCTAssertEqual(HTTP.route("/g/tok/zip/all.zip"), .archive("tok"))
        XCTAssertNil(HTTP.route("/"))
        XCTAssertNil(HTTP.route("/g/tok/raw/x"))
        XCTAssertNil(HTTP.route("/g/tok/raw/-1"))
        XCTAssertNil(HTTP.route("/g/to.k"))
        XCTAssertNil(HTTP.route("/x/tok"))
    }

    func testRanges() {
        XCTAssertEqual(HTTP.parseRange(nil, size: 10), .full)
        XCTAssertEqual(HTTP.parseRange("bytes=0-4", size: 10), .partial(start: 0, end: 4))
        XCTAssertEqual(HTTP.parseRange("bytes=5-", size: 10), .partial(start: 5, end: 9))
        XCTAssertEqual(HTTP.parseRange("bytes=-3", size: 10), .partial(start: 7, end: 9))
        XCTAssertEqual(HTTP.parseRange("bytes=-30", size: 10), .partial(start: 0, end: 9))
        XCTAssertEqual(HTTP.parseRange("bytes=2-99", size: 10), .partial(start: 2, end: 9))
        XCTAssertEqual(HTTP.parseRange("bytes=10-", size: 10), .unsatisfiable)
        XCTAssertEqual(HTTP.parseRange("bytes=0-1,4-5", size: 10), .full)
        XCTAssertEqual(HTTP.parseRange("bytes=5-2", size: 10), .full)
        XCTAssertEqual(HTTP.parseRange("items=0-1", size: 10), .full)
    }

    func testEscapingAndDisposition() {
        XCTAssertEqual(HTTP.escapeHTML("<a href=\"x\">'&'</a>"), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
        XCTAssertEqual(HTTP.encodePathSegment("a b/ü.txt"), "a%20b%2F%C3%BC.txt")
        XCTAssertEqual(HTTP.contentDisposition(filename: "ü \"q\".txt"),
                       "attachment; filename=\"_ _q_.txt\"; filename*=UTF-8''%C3%BC%20%22q%22.txt")
        XCTAssertTrue(HTTP.contentDisposition(filename: "a", inline: true).hasPrefix("inline;"))
    }

    func testTokenIsURLSafeAndUnique() {
        let a = GistStore.makeToken(), b = GistStore.makeToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 22)
        XCTAssertNotNil(HTTP.route("/g/\(a)"))
    }
}
