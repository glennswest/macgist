import Foundation

public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]   // keys lowercased
}

public enum Route: Equatable {
    /// `/in/<token>[/<item>]`. `token` is nil when the path is malformed
    /// (answered 403 like a bad token). `item` is percent-decoded.
    case inbox(token: String?, item: String?)
    case page(String)
    case raw(String, Int)
    case download(String, Int)
    case archive(String)

    public var token: String? {
        switch self {
        case .page(let t), .raw(let t, _), .download(let t, _), .archive(let t): return t
        case .inbox: return nil
        }
    }
}

public enum ByteRange: Equatable {
    case full
    case partial(start: UInt64, end: UInt64)   // inclusive
    case unsatisfiable
}

public enum HTTP {
    /// Parses the request line and headers (everything before the blank line).
    public static func parse(_ head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    /// `/g/<token>`, `/g/<token>/raw/<i>/<name>`, `/g/<token>/dl/<i>/<name>`, `/g/<token>/zip/<name>`.
    /// Trailing name segments are cosmetic (they give `curl -O`/`wget` a filename).
    public static func route(_ path: String) -> Route? {
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let comps = pathOnly.split(separator: "/", omittingEmptySubsequences: true)
        if comps.first == "in" {
            guard (2...3).contains(comps.count) else { return .inbox(token: nil, item: nil) }
            let item = comps.count == 3 ? String(comps[2]).removingPercentEncoding : nil
            if comps.count == 3, item == nil { return .inbox(token: nil, item: nil) }
            return .inbox(token: String(comps[1]), item: item)
        }
        guard comps.count >= 2, comps[0] == "g" else { return nil }
        let token = String(comps[1])
        guard token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        if comps.count == 2 { return .page(token) }
        switch comps[2] {
        case "raw", "dl":
            guard comps.count >= 4, let i = Int(comps[3]), i >= 0 else { return nil }
            return comps[2] == "raw" ? .raw(token, i) : .download(token, i)
        case "zip":
            return .archive(token)
        default:
            return nil
        }
    }

    /// Query parameters (`?a=1&b=2`), percent-decoded.
    public static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            out[key] = value
        }
        return out
    }

    /// A name an uploader chose, made safe to create in the inbox: last path
    /// component only, no control characters, no leading dots, bounded length.
    public static func sanitizeFilename(_ raw: String) -> String? {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0 != ":" && $0.value != 0x7f }
            .map(Character.init))
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            name = String(name.prefix(190)) + (ext.isEmpty || ext.count > 9 ? "" : ".\(ext)")
        }
        return name.isEmpty ? nil : name
    }

    /// Single-range support (`bytes=a-b`, `bytes=a-`, `bytes=-n`). Multi-range
    /// and malformed headers fall back to the full body, as RFC 9110 allows.
    public static func parseRange(_ header: String?, size: UInt64) -> ByteRange {
        guard let header, header.hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .full }
        let a = spec[..<dash], b = spec[spec.index(after: dash)...]
        if a.isEmpty {
            guard let n = UInt64(b) else { return .full }
            if n == 0 || size == 0 { return .unsatisfiable }
            return .partial(start: size - min(n, size), end: size - 1)
        }
        guard let start = UInt64(a) else { return .full }
        if start >= size { return .unsatisfiable }
        if b.isEmpty { return .partial(start: start, end: size - 1) }
        guard let end = UInt64(b), end >= start else { return .full }
        return .partial(start: start, end: min(end, size - 1))
    }

    /// Percent-encodes a filename for use as a URL path segment.
    public static func encodePathSegment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "download"
    }

    /// `Content-Disposition` with an ASCII fallback plus the RFC 5987 UTF-8 name.
    public static func contentDisposition(filename: String, inline: Bool = false) -> String {
        let fallback = String(filename.unicodeScalars.map {
            $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 0x20 ? Character($0) : "_"
        })
        return "\(inline ? "inline" : "attachment"); filename=\"\(fallback)\"; filename*=UTF-8''\(encodePathSegment(filename))"
    }

    public static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    public static func formatSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 100: return "Continue"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
