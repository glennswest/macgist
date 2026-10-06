import Foundation
import MacGistCore

/// Every user-settable value, in one place: keys, defaults and validation.
/// Stored in `UserDefaults` (domain `com.glennswest.macgist`), so each is also
/// settable with `defaults write`.
enum Prefs {
    enum Key {
        static let lifetimeMinutes = "lifetimeMinutes"
        static let port = "port"
        static let host = "host"
        static let inlinePreviewKB = "inlinePreviewKB"
        static let highlightURL = "highlightURL"
        static let receive = "receive"
        static let receiveFolder = "receiveFolder"
        static let maxUploadMB = "maxUploadMB"
        static let clipboardLimitKB = "clipboardLimitKB"
        static let inboxSubnets = "inboxSubnets"
        static let inboxScope = "inboxScope"

        static let all = [lifetimeMinutes, port, host, inlinePreviewKB, highlightURL, receive,
                          receiveFolder, maxUploadMB, clipboardLimitKB, inboxSubnets, inboxScope]
    }

    /// Which senders the inbox accepts (the token is always required too).
    enum Scope: String, CaseIterable {
        case privateNetworks = "private"   // any RFC 1918 address: 10.x, 172.16–31.x, 192.168.x
        case localNetworks = "local"       // only the subnets this Mac is on right now
        case custom = "custom"             // the inboxSubnets list
    }

    static let lifetimeRange = 1...10_080          // 1 minute … 7 days
    static let portRange = 1024...65_535
    static let lifetimePresets = [5, 15, 30, 60, 240, 1440]

    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Key.lifetimeMinutes: 15,
            Key.port: 8642,
            Key.host: "",
            Key.inlinePreviewKB: 1024,
            Key.highlightURL: GistPage.defaultHighlightBase,
            Key.receive: true,
            Key.receiveFolder: "",
            Key.maxUploadMB: 1024,
            Key.clipboardLimitKB: 1024,
            Key.inboxSubnets: [String](),
            Key.inboxScope: Scope.privateNetworks.rawValue,
        ])
        // Before scopes existed, a non-empty subnet list meant "custom".
        if d.object(forKey: Key.inboxScope) == nil, !(d.stringArray(forKey: Key.inboxSubnets) ?? []).isEmpty {
            d.set(Scope.custom.rawValue, forKey: Key.inboxScope)
        }
    }

    private static func int(_ key: String, in range: ClosedRange<Int>) -> Int {
        min(max(d.integer(forKey: key), range.lowerBound), range.upperBound)
    }

    static var lifetimeMinutes: Int {
        get { int(Key.lifetimeMinutes, in: lifetimeRange) }
        set { d.set(newValue, forKey: Key.lifetimeMinutes) }
    }
    static var lifetime: TimeInterval { TimeInterval(lifetimeMinutes * 60) }

    static var port: UInt16 { UInt16(int(Key.port, in: portRange)) }

    /// `""` automatic, `iface:<name>`, `bonjour`, or a literal host/IP.
    static var host: String { d.string(forKey: Key.host) ?? "" }

    static var inlinePreviewBytes: UInt64 { UInt64(int(Key.inlinePreviewKB, in: 1...1_048_576)) << 10 }

    static var highlightURL: String { d.string(forKey: Key.highlightURL) ?? "" }

    static var receive: Bool {
        get { d.bool(forKey: Key.receive) }
        set { d.set(newValue, forKey: Key.receive) }
    }

    static var receiveFolder: URL {
        let path = (d.string(forKey: Key.receiveFolder) ?? "").trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var maxUploadBytes: UInt64 { UInt64(int(Key.maxUploadMB, in: 1...1_048_576)) << 20 }

    static var clipboardLimitBytes: UInt64 { UInt64(int(Key.clipboardLimitKB, in: 1...65_536)) << 10 }

    /// Raw subnet entries as typed (CIDRs or single addresses).
    static var subnetEntries: [String] {
        get { d.stringArray(forKey: Key.inboxSubnets) ?? [] }
        set { d.set(newValue, forKey: Key.inboxSubnets) }
    }

    static var scope: Scope {
        get { Scope(rawValue: d.string(forKey: Key.inboxScope) ?? "") ?? .privateNetworks }
        set { d.set(newValue.rawValue, forKey: Key.inboxScope) }
    }

    /// What the inbox checks senders against. `nil` = the Mac's own subnets,
    /// re-read per request. An empty custom list also falls back to that.
    static var subnets: [Subnet]? {
        switch scope {
        case .privateNetworks: return Subnet.privateRanges
        case .localNetworks: return nil
        case .custom:
            let parsed = subnetEntries.compactMap(Subnet.init(cidr:))
            return parsed.isEmpty ? nil : parsed
        }
    }

    static func describe(minutes: Int) -> String {
        if minutes % 1440 == 0 { return minutes == 1440 ? "1 day" : "\(minutes / 1440) days" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes) min"
    }
}
