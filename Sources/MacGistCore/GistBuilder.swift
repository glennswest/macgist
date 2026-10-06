import Foundation

public enum GistBuilderError: LocalizedError {
    case nothingToShare
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToShare: return "Nothing to share."
        case .zipFailed(let msg): return "Could not zip: \(msg)"
        }
    }
}

/// Turns a Finder selection or a piece of text into a `Gist`. Files are served
/// in place; folders are zipped into the gist's temp dir; text is written there.
public struct GistBuilder: Sendable {
    public let tempRoot: URL
    public let lifetime: TimeInterval
    public let inlineLimit: UInt64

    public init(tempRoot: URL = GistBuilder.defaultTempRoot, lifetime: TimeInterval = GistStore.defaultLifetime,
                inlineLimit: UInt64 = GistEntry.inlineTextLimit) {
        self.tempRoot = tempRoot
        self.lifetime = lifetime
        self.inlineLimit = inlineLimit
    }

    public static var defaultTempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacGist", isDirectory: true)
    }

    public static func archiveName(for gist: Gist) -> String {
        let base = gist.title.replacingOccurrences(of: "/", with: "-")
        return base.lowercased().hasSuffix(".zip") ? base : base + ".zip"
    }

    public struct Snippet: Sendable {
        public var name: String
        public var text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    /// Blocking: zipping a large folder can take a while. Snippets come first on
    /// the page, then files in selection order.
    public func build(title: String? = nil, snippets: [Snippet] = [], files urls: [URL] = [],
                      baseURL: String, now: Date = Date()) throws -> Gist {
        let snippets = snippets.filter { !$0.text.isEmpty }
        let items = urls.map { $0.standardizedFileURL }
        guard !snippets.isEmpty || !items.isEmpty else { throw GistBuilderError.nothingToShare }
        let token = GistStore.makeToken()
        let dir = tempRoot.appendingPathComponent(token, isDirectory: true)
        do {
            var entries: [GistEntry] = []
            var used = Set<String>()
            func unique(_ name: String) -> String {
                var candidate = name, n = 2
                let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
                while used.contains(candidate) {
                    candidate = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                    n += 1
                }
                used.insert(candidate)
                return candidate
            }

            for (i, snip) in snippets.enumerated() {
                let raw = snip.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                let name = unique(raw.isEmpty ? "snippet.txt" : raw)
                let file = dir.appendingPathComponent("text/\(i)", isDirectory: true).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(snip.text.utf8).write(to: file)
                entries.append(try GistEntry(name: name, fileURL: file, inlineLimit: inlineLimit))
            }
            for item in items {
                if isDirectory(item) {
                    let zip = try Zipper.zip([item], to: dir.appendingPathComponent("folders/\(UUID().uuidString)", isDirectory: true)
                        .appendingPathComponent(item.lastPathComponent + ".zip"))
                    entries.append(try GistEntry(name: unique(item.lastPathComponent + ".zip"), fileURL: zip, inlineLimit: inlineLimit))
                } else {
                    entries.append(try GistEntry(name: unique(item.lastPathComponent), fileURL: item, inlineLimit: inlineLimit))
                }
            }

            let explicit = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let derived = entries.count == 1 ? entries[0].name : "\(entries[0].name) + \(entries.count - 1) more"
            // "Download all" zips the snippets' temp files plus the original Finder items.
            let sources = entries.prefix(snippets.count).map(\.fileURL) + items
            return Gist(token: token, title: explicit.isEmpty ? derived : explicit, entries: entries, sources: sources,
                        link: "\(baseURL)/g/\(token)", created: now, expires: now.addingTimeInterval(lifetime), tempDir: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}

public enum Zipper {
    /// Zips `items` to `out` (parent dirs created). Items are staged as symlinks,
    /// which zip follows, so the archive gets clean top-level names without copying.
    public static func zip(_ items: [URL], to out: URL) throws -> URL {
        let fm = FileManager.default
        let staging = out.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var names: [String] = []
        for item in items {
            var entry = item.lastPathComponent
            var n = 2
            while names.contains(entry) {
                let ext = item.pathExtension
                entry = "\(item.deletingPathExtension().lastPathComponent) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }
            names.append(entry)
            try fm.createSymbolicLink(at: staging.appendingPathComponent(entry), withDestinationURL: item)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = staging
        proc.arguments = ["-r", "-q", "-X", out.path] + names + ["-x", "*.DS_Store"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            try? fm.removeItem(at: out)
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GistBuilderError.zipFailed(msg?.isEmpty == false ? msg! : "zip exited \(proc.terminationStatus)")
        }
        return out
    }
}
