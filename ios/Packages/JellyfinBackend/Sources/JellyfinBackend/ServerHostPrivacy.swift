import Foundation

/// Decides whether a server address stays on a network the user controls.
///
/// The app allows plain HTTP because most self-hosted servers are reached as
/// `http://192.168.…:8096` at home, where TLS is neither available nor
/// needed. The same `http://` against a public address sends the password
/// and the access token readable across the internet; onboarding uses this
/// to show a hint in that case (and only then). Purely lexical: no DNS
/// lookup, so a public name that resolves to a private address counts as
/// public — a hint too many is the safe side.
public enum ServerHostPrivacy {
    /// True when `http://host` cannot leave a private network: loopback,
    /// RFC 1918, link-local, carrier-grade NAT (100.64/10 — what Tailscale
    /// and other overlay VPNs hand out), IPv6 unique-local / link-local, and
    /// names that only resolve locally (single label, `.local`, …).
    public static func isPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Zone ID of a link-local IPv6 address (`fe80::1%en0`).
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        // A name. Something that looks like a broken IP address (all digits
        // and dots) is not a local name.
        guard host.contains(where: { $0.isLetter }) else { return false }
        if !host.contains(".") { return true }          // "nas", "jellyfin", "localhost"
        return localSuffixes.contains { host.hasSuffix($0) }
    }

    /// True when signing in at `url` would send credentials unencrypted
    /// beyond the user's own network.
    public static func sendsCredentialsInClearText(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty else { return false }
        return !isPrivateHost(host)
    }

    // MARK: - Names

    /// Suffixes that never resolve on the public internet: mDNS, the
    /// special-use names of RFC 6761 / 6762 / 8375 / 9476, common router
    /// defaults, and Tailscale's MagicDNS (reachable only inside the tailnet,
    /// where WireGuard encrypts the traffic).
    private static let localSuffixes = [
        ".local", ".localhost", ".lan", ".home", ".internal", ".intranet", ".home.arpa", ".fritz.box", ".ts.net",
    ]

    // MARK: - IPv4

    static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): return true                       // 10.0.0.0/8
        case (172, 16...31): return true                // 172.16.0.0/12
        case (192, 168): return true                    // 192.168.0.0/16
        case (169, 254): return true                    // link-local
        case (127, _): return true                      // loopback
        case (100, 64...127): return true               // CGNAT 100.64.0.0/10
        default: return false
        }
    }

    // MARK: - IPv6

    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" { return true }
        // IPv4-mapped / -compatible (`::ffff:192.168.1.5`).
        if let lastColon = host.lastIndex(of: ":") {
            let tail = String(host[host.index(after: lastColon)...])
            if tail.contains("."), let octets = ipv4Octets(tail) {
                return isPrivateIPv4(octets)
            }
        }
        let firstGroup = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !firstGroup.isEmpty, firstGroup.count <= 4, let value = UInt16(firstGroup, radix: 16) else { return false }
        if value & 0xFE00 == 0xFC00 { return true }     // fc00::/7 unique local
        if value & 0xFFC0 == 0xFE80 { return true }     // fe80::/10 link-local
        return false
    }
}
