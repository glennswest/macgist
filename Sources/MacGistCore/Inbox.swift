import Foundation
import Security

/// Something another machine sent to this Mac.
public struct Received: Sendable {
    public enum Content: Sendable {
        case text(String, title: String?)
        case file(URL)
    }
    public let content: Content
    public let sender: String
    public let size: UInt64
    public let date: Date
}

/// The receive side (issue #1): who may send, where files land, and the hand-off
/// to the app. Shared between the UI and the server queues.
public final class Inbox: @unchecked Sendable {
    public static let defaultClipboardLimit: UInt64 = 1 << 20

    private let lock = NSLock()
    private var _root: URL
    private var _clipboardLimit: UInt64 = Inbox.defaultClipboardLimit
    private var _token: String
    private var _enabled: Bool
    private var _maxFileBytes: UInt64
    private var _subnets: [Subnet]?
    private var senderNames: [String: String] = [:]
    private let onReceive: @Sendable (Received) -> Void

    public init(root: URL, token: String, enabled: Bool = true, maxFileBytes: UInt64 = 1 << 30,
                subnets: [Subnet]? = nil, onReceive: @escaping @Sendable (Received) -> Void) {
        _root = root
        _token = token
        _enabled = enabled
        _maxFileBytes = maxFileBytes
        _subnets = subnets
        self.onReceive = onReceive
    }

    /// Parent of the per-sender `From <sender>` folders (normally ~/Downloads).
    public var root: URL {
        get { lock.withLock { _root } }
        set { lock.withLock { _root = newValue } }
    }

    public var clipboardLimit: UInt64 {
        get { lock.withLock { _clipboardLimit } }
        set { lock.withLock { _clipboardLimit = newValue } }
    }

    public var token: String {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    public var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    public var maxFileBytes: UInt64 {
        get { lock.withLock { _maxFileBytes } }
        set { lock.withLock { _maxFileBytes = newValue } }
    }

    /// `nil` means "the Mac's own interface subnets", re-read on every check so
    /// it follows network changes.
    public var subnets: [Subnet]? {
        get { lock.withLock { _subnets } }
        set { lock.withLock { _subnets = newValue } }
    }

    /// Constant-time token comparison.
    public func authorize(_ candidate: String) -> Bool {
        let a = Array(token.utf8), b = Array(candidate.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Loopback always; otherwise the address must fall in an allowed subnet.
    public func allows(_ ip: String) -> Bool {
        guard let addr = Subnet.parseIPv4(ip) else { return false }
        if addr >> 24 == 127 { return true }
        let nets = subnets ?? LocalAddress.localSubnets()
        return nets.contains { $0.contains(addr) }
    }

    /// Short name for notifications and the folder name: first label of the
    /// reverse-DNS name (`buildbox.example.lan` → `buildbox`), else the IP.
    /// Only successes are cached: on macOS 15 the lookup fails until the user
    /// grants Local Network access, and it must start working once they do.
    public func senderName(for ip: String) -> String {
        if let cached = lock.withLock({ senderNames[ip] }) { return cached }
        guard let name = Self.reverseLookup(ip) else { return ip }
        lock.withLock { senderNames[ip] = name }
        return name
    }

    static func reverseLookup(_ ip: String) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0, let label = String(cString: host).split(separator: ".").first else { return nil }
        return HTTP.sanitizeFilename(String(label))
    }

    /// A partial file for an incoming body, on the same volume as the
    /// destination so finishing is a rename.
    func makePartial() throws -> URL {
        let dir = root.appendingPathComponent(".macgist-incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Moves a finished upload to `From <sender>/<name>` (never overwriting).
    func saveFile(partial: URL, name: String, size: UInt64, sender: String) throws -> URL {
        let dir = root.appendingPathComponent("From \(sender)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.unique(name, in: dir)
        try FileManager.default.moveItem(at: partial, to: dest)
        onReceive(Received(content: .file(dest), sender: sender, size: size, date: Date()))
        return dest
    }

    func deliverText(_ text: String, title: String?, sender: String) {
        onReceive(Received(content: .text(text, title: title), sender: sender, size: UInt64(text.utf8.count), date: Date()))
    }

    /// `name.txt`, `name (2).txt`, `name (3).txt`, …
    static func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return url
    }

    public static func makeToken() -> String { GistStore.makeToken() }
}

/// An IPv4 CIDR block.
public struct Subnet: Equatable, Sendable, CustomStringConvertible {
    public let network: UInt32
    public let mask: UInt32

    public init(network: UInt32, mask: UInt32) {
        self.network = network & mask
        self.mask = mask
    }

    /// `192.168.1.0/24`, or a bare address as /32.
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard let addr = Subnet.parseIPv4(String(parts[0])) else { return nil }
        let bits = parts.count == 2 ? Int(parts[1]) : 32
        guard let bits, (0...32).contains(bits) else { return nil }
        self.init(network: addr, mask: bits == 0 ? 0 : UInt32.max << (32 - bits))
    }

    public func contains(_ addr: UInt32) -> Bool { addr & mask == network }

    /// RFC 1918 private ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    public static let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].compactMap(Subnet.init(cidr:))

    public var description: String {
        let n = network
        return "\(n >> 24).\(n >> 16 & 255).\(n >> 8 & 255).\(n & 255)/\(mask.nonzeroBitCount)"
    }

    /// Dotted quad, also accepting the IPv4-mapped IPv6 form (`::ffff:a.b.c.d`).
    public static func parseIPv4(_ s: String) -> UInt32? {
        var str = s
        if let r = str.range(of: "::ffff:", options: [.caseInsensitive, .anchored]) { str.removeSubrange(r) }
        if let pct = str.firstIndex(of: "%") { str = String(str[..<pct]) }
        var a = in_addr()
        guard inet_pton(AF_INET, str, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }
}
