import XCTest
@testable import JellyfinBackend

final class ServerHostPrivacyTests: XCTestCase {
    func testPrivateIPv4Ranges() {
        for host in [
            "10.0.0.1", "10.255.255.254",
            "172.16.0.1", "172.31.255.1",
            "192.168.1.5",
            "169.254.10.20",
            "127.0.0.1", "127.1.2.3",
            "100.64.0.1", "100.100.100.100", "100.127.255.254",
        ] {
            XCTAssertTrue(ServerHostPrivacy.isPrivateHost(host), host)
        }
    }

    func testPublicIPv4() {
        for host in [
            "8.8.8.8", "1.1.1.1", "203.0.113.7",
            "172.15.0.1", "172.32.0.1",          // just outside 172.16/12
            "192.167.1.1", "192.169.1.1",
            "100.63.255.255", "100.128.0.1",     // just outside 100.64/10
            "169.253.1.1", "11.0.0.1",
        ] {
            XCTAssertFalse(ServerHostPrivacy.isPrivateHost(host), host)
        }
    }

    func testIPv6() {
        for host in ["::1", "[::1]", "fd12:3456:789a::1", "fc00::1", "[fd7a:115c:a1e0::1]", "fe80::1", "fe80::1%en0", "febf::1", "::ffff:192.168.1.5"] {
            XCTAssertTrue(ServerHostPrivacy.isPrivateHost(host), host)
        }
        for host in ["2001:db8::1", "2a00:1450:4001:81b::200e", "fec0::1", "fe00::1", "::ffff:8.8.8.8", "::"] {
            XCTAssertFalse(ServerHostPrivacy.isPrivateHost(host), host)
        }
    }

    func testLocalNames() {
        for host in ["localhost", "nas", "JELLYFIN", "jellyfin.local", "media.home.arpa", "server.lan", "box.internal", "pi.fritz.box", "mini.tail1234.ts.net", "nas.local."] {
            XCTAssertTrue(ServerHostPrivacy.isPrivateHost(host), host)
        }
    }

    func testPublicNamesAndGarbage() {
        for host in ["jellyfin.example.com", "example.org", "my-local.example.com", "local.example.net", ""] {
            XCTAssertFalse(ServerHostPrivacy.isPrivateHost(host), host)
        }
        // Not valid addresses; must not be mistaken for single-label names.
        for host in ["999.1.1.1", "10.0.0", "1234", "10.0.0.1.5"] {
            XCTAssertFalse(ServerHostPrivacy.isPrivateHost(host), host)
        }
    }

    func testClearTextWarningOnlyForPublicHTTP() {
        func warns(_ string: String) -> Bool {
            ServerHostPrivacy.sendsCredentialsInClearText(to: URL(string: string)!)
        }
        XCTAssertTrue(warns("http://jellyfin.example.com:8096"))
        XCTAssertTrue(warns("http://203.0.113.7:8096/jellyfin"))
        XCTAssertTrue(warns("HTTP://Example.com"))
        XCTAssertFalse(warns("https://jellyfin.example.com"))
        XCTAssertFalse(warns("https://203.0.113.7"))
        XCTAssertFalse(warns("http://192.168.1.5:8096"))
        XCTAssertFalse(warns("http://jellyfin.local:8096"))
        XCTAssertFalse(warns("http://nas:8096"))
        XCTAssertFalse(warns("http://100.101.102.103:8096"))
        XCTAssertFalse(warns("http://[fd00::10]:8096"))
        XCTAssertTrue(warns("http://[2001:db8::1]:8096"))
    }

    func testCandidatesFromServerAddressClassify() throws {
        // The URLs onboarding really probes for typed input.
        let typed = try ServerAddress.candidates(for: "192.168.1.5:8096")
        XCTAssertTrue(typed.allSatisfy { !ServerHostPrivacy.sendsCredentialsInClearText(to: $0) })
        let publicName = try ServerAddress.candidates(for: "music.example.com")
        XCTAssertEqual(publicName.map { ServerHostPrivacy.sendsCredentialsInClearText(to: $0) }, [false, true, true])
    }
}
