import Foundation
import Security
import UniformTypeIdentifiers

public enum EntryKind: Equatable, Sendable {
    case text      // rendered inline on the page
    case image     // shown inline with <img>
    case binary    // download card only
}

/// One file in a gist. Folders are zipped at creation and appear as a `.zip` entry.
public struct GistEntry: Sendable {
    public let name: String
    public let fileURL: URL
    public let size: UInt64
    public let kind: EntryKind
    public let mime: String

    /// Default size above which text files are offered for download instead of inlined.
    public static let inlineTextLimit: UInt64 = 1 << 20

    public init(name: String, fileURL: URL, inlineLimit: UInt64 = GistEntry.inlineTextLimit) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        self.name = name
        self.fileURL = fileURL
        self.size = size
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if let type, type.conforms(to: .image), ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "ico"]
            .contains((name as NSString).pathExtension.lowercased()) {
            kind = .image
        } else if size <= inlineLimit, Self.looksLikeText(fileURL, type: type) {
            kind = .text
        } else {
            kind = .binary
        }
        mime = type?.preferredMIMEType ?? (kind == .text ? "text/plain" : "application/octet-stream")
    }

    /// UTType says text, or the first 8 KiB is valid UTF-8 with no NUL bytes.
    static func looksLikeText(_ url: URL, type: UTType?) -> Bool {
        if let type, type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .archive) || type.conforms(to: .pdf) {
            return false
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 8192)) ?? Data()
        if head.isEmpty { return type?.conforms(to: .text) ?? true }
        if head.contains(0) { return false }
        // Allow a multi-byte UTF-8 sequence cut off at the 8 KiB boundary.
        for trim in 0...3 where head.count > trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }
}

public struct Gist: Sendable {
    public let token: String
    public let title: String
    public let entries: [GistEntry]
    /// Original Finder items (used to build "Download all").
    public let sources: [URL]
    public let link: String
    public let created: Date
    public var expires: Date
    /// Per-gist scratch dir (zips, text snippets). Removed when the gist ends.
    public let tempDir: URL
    public var hits: Int = 0

    public init(token: String, title: String, entries: [GistEntry], sources: [URL], link: String,
                created: Date, expires: Date, tempDir: URL) {
        self.token = token
        self.title = title
        self.entries = entries
        self.sources = sources
        self.link = link
        self.created = created
        self.expires = expires
        self.tempDir = tempDir
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expires }

    public var totalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }

    public func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

/// Thread-safe, in-memory table of live gists. The HTTP server reads it from
/// its own queues; the UI mutates it from the main thread.
public final class GistStore: @unchecked Sendable {
    public static let defaultLifetime: TimeInterval = 15 * 60

    private let lock = NSLock()
    private let zipLock = NSLock()
    private var gists: [String: Gist] = [:]

    public init() {}

    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func add(_ gist: Gist) {
        lock.withLock { gists[gist.token] = gist }
    }

    /// Returns the gist only while it is still valid.
    public func lookup(_ token: String, at now: Date = Date()) -> Gist? {
        lock.withLock {
            guard let g = gists[token], !g.isExpired(at: now) else { return nil }
            return g
        }
    }

    /// Pushes a live gist's expiry out by `interval` from now (or from its
    /// current expiry, whichever is later). Returns the new expiry.
    @discardableResult
    public func extend(_ token: String, by interval: TimeInterval, now: Date = Date()) -> Date? {
        lock.withLock {
            guard let g = gists[token], !g.isExpired(at: now) else { return nil }
            let new = max(g.expires, now).addingTimeInterval(interval)
            gists[token]?.expires = new
            return new
        }
    }

    public func recordHit(_ token: String) {
        lock.withLock { gists[token]?.hits += 1 }
    }

    @discardableResult
    public func remove(_ token: String) -> Gist? {
        lock.withLock { gists.removeValue(forKey: token) }
    }

    public func removeAll() -> [Gist] {
        lock.withLock {
            let all = Array(gists.values)
            gists.removeAll()
            return all
        }
    }

    /// Drops expired gists and returns them so the caller can clean up.
    public func purgeExpired(at now: Date = Date()) -> [Gist] {
        lock.withLock {
            let expired = gists.values.filter { $0.isExpired(at: now) }
            for g in expired { gists.removeValue(forKey: g.token) }
            return expired
        }
    }

    public var active: [Gist] {
        lock.withLock { gists.values.sorted { $0.expires < $1.expires } }
    }

    /// Builds (once) and returns the "Download all" archive for a gist.
    public func archive(for gist: Gist) throws -> URL {
        let out = gist.tempDir.appendingPathComponent("all", isDirectory: true)
            .appendingPathComponent(GistBuilder.archiveName(for: gist))
        return try zipLock.withLock {
            if FileManager.default.fileExists(atPath: out.path) { return out }
            return try Zipper.zip(gist.sources, to: out)
        }
    }
}
