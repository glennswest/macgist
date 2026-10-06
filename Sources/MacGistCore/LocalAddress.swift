import Foundation
import SystemConfiguration

public enum LocalAddress {
    public struct Interface: Equatable, Sendable {
        public let name: String      // en0, en1, utun3, …
        public let ip: String
        public let isPrimary: Bool   // carries the default route
    }

    /// Name of the interface carrying the IPv4 default route, if any.
    public static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacGist" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// Up, non-loopback IPv4 addresses: primary first, then `en*`, then the rest.
    public static func interfaces() -> [Interface] {
        let primary = primaryInterface()
        var found: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            found.append(Interface(name: name, ip: String(cString: host), isPrimary: name == primary))
        }
        func rank(_ i: Interface) -> Int { i.isPrimary ? 0 : i.name.hasPrefix("en") ? 1 : 2 }
        return found.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// IPv4 address of the interface carrying the default route, falling back
    /// to the first `en*` address. An IP rather than `<name>.local` so the link
    /// works from machines without mDNS.
    public static func primaryIPv4() -> String? {
        interfaces().first?.ip
    }

    /// The Mac's Bonjour name, e.g. `MacBook-Pro.local`.
    public static func bonjourName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// Where links should point. `choice` is the `host` setting:
    /// `""` automatic (primary interface), `iface:<name>` a specific interface,
    /// `bonjour` the `.local` name, anything else used as-is (IP or DNS name).
    public static func linkHost(for choice: String) -> String? {
        let c = choice.trimmingCharacters(in: .whitespaces)
        if c.isEmpty || c == "auto" { return primaryIPv4() }
        if c == "bonjour" { return bonjourName() }
        if c.hasPrefix("iface:") {
            let name = String(c.dropFirst("iface:".count))
            return interfaces().first(where: { $0.name == name })?.ip
        }
        return c
    }

    /// Subnets of the Mac's up, non-loopback IPv4 interfaces.
    public static func localSubnets() -> [Subnet] {
        var out: [Subnet] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, let nm = ifa.ifa_netmask, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let net = Subnet(network: addr, mask: mask)
            if !out.contains(net) { out.append(net) }
        }
        return out
    }
}
