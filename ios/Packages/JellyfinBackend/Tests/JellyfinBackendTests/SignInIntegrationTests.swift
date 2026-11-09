import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in tests against a real Jellyfin server (see `scripts/dev-jellyfin/`).
/// Skipped unless `JELLYFIN_TEST_URL` is set:
///
///     docker run --rm --network host \
///       -e JELLYFIN_TEST_URL=http://localhost:8096 \
///       -e JELLYFIN_TEST_USER=demo -e JELLYFIN_TEST_PASSWORD=demo \
///       -v "$PWD":/w -w /w/ios/Packages/JellyfinBackend \
///       mirror.gcr.io/library/swift:6.0 swift test --filter SignInIntegrationTests
///
/// They only create (and revoke) their own sessions; the library is untouched.
final class SignInIntegrationTests: XCTestCase {
    private struct Server {
        var address: String
        var username: String
        var password: String
    }

    private func server() throws -> Server {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["JELLYFIN_TEST_URL"], !address.isEmpty else {
            throw XCTSkip("Set JELLYFIN_TEST_URL to run the Jellyfin integration tests")
        }
        return Server(
            address: address,
            username: environment["JELLYFIN_TEST_USER"] ?? "demo",
            password: environment["JELLYFIN_TEST_PASSWORD"] ?? "demo"
        )
    }

    private func freshSession(_ info: JellyfinServerInfo) -> JellyfinSession {
        JellyfinSession(serverURL: info.url, deviceID: "jellyamp-integration-\(UUID().uuidString)", deviceName: "Integration Test")
    }

    func testPublicInfoProbe() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertFalse(info.id.isEmpty)
        let version = try XCTUnwrap(JellyfinServerVersion(info.version), info.version)
        XCTAssertGreaterThanOrEqual(version, .minimumSupported)
    }

    /// The user-facing forms of the address must all end at the same server.
    func testProbeAcceptsSloppyAddressForms() async throws {
        let server = try server()
        let canonical = try await JellyfinServerDiscovery().discover(address: server.address)
        let withoutScheme = server.address.replacingOccurrences(of: "http://", with: "")
        for form in [withoutScheme, server.address + "/", server.address + "/web/index.html#/home.html"] {
            let info = try await JellyfinServerDiscovery().discover(address: form)
            XCTAssertEqual(info.id, canonical.id, form)
            XCTAssertEqual(info.url, canonical.url, form)
        }
    }

    func testProbeOfClosedPortIsUnreachable() async throws {
        _ = try server()
        do {
            _ = try await JellyfinServerDiscovery(timeout: 3).discover(address: "http://127.0.0.1:9")
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? JellyfinConnectionError, .unreachable)
        }
    }

    func testPasswordSignInValidateAndLogout() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        let authenticator = JellyfinAuthenticator()

        let result = try await authenticator.signIn(
            session: freshSession(info),
            username: server.username,
            password: server.password
        )
        XCTAssertTrue(result.session.isAuthenticated)
        XCTAssertEqual(result.userName.lowercased(), server.username.lowercased())

        let validity = await authenticator.validate(session: result.session)
        XCTAssertEqual(validity, .valid(userName: result.userName))

        // The token really works for library calls.
        let albums = try await MusicLibraryAPI(session: result.session).albums(limit: 1)
        XCTAssertFalse(albums.isEmpty)

        await authenticator.logout(session: result.session)
        let afterLogout = await authenticator.validate(session: result.session)
        XCTAssertEqual(afterLogout, .rejected, "logout must revoke the token server-side")
    }

    func testWrongPassword() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        do {
            _ = try await JellyfinAuthenticator().signIn(
                session: freshSession(info),
                username: server.username,
                password: server.password + "-wrong"
            )
            XCTFail("expected wrongCredentials")
        } catch {
            XCTAssertEqual(error as? JellyfinConnectionError, .wrongCredentials)
        }
    }

    func testBogusTokenIsRejectedAndReported() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        var session = freshSession(info)
        session.accessToken = "0123456789abcdef0123456789abcdef"
        session.userID = "0123456789abcdef0123456789abcdef"

        let validity = await JellyfinAuthenticator().validate(session: session)
        XCTAssertEqual(validity, .rejected)

        let reported = expectation(description: "401 reported")
        reported.assertForOverFulfill = false
        let api = MusicLibraryAPI(session: session, transport: UnauthorizedReportingTransport { reported.fulfill() })
        _ = try? await api.albums(limit: 1)
        await fulfillment(of: [reported], timeout: 5)
    }

    /// The whole Quick Connect round trip: initiate on a "new device", approve
    /// the code as the signed-in demo user, poll, exchange the secret.
    func testQuickConnectRoundTrip() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        let authenticator = JellyfinAuthenticator()

        // The already signed-in client that will approve the code.
        let approver = try await authenticator.signIn(
            session: freshSession(info),
            username: server.username,
            password: server.password
        ).session

        let newDevice = freshSession(info)
        let enabled = await authenticator.isQuickConnectEnabled(session: newDevice)
        try XCTSkipUnless(enabled, "Quick Connect is disabled on the test server")

        let state = try await authenticator.initiateQuickConnect(session: newDevice)
        XCTAssertFalse(state.secret.isEmpty)
        XCTAssertEqual(state.code.count, 6)

        let approvedBefore = try await authenticator.isQuickConnectApproved(session: newDevice, state: state)
        XCTAssertFalse(approvedBefore)

        // Start waiting first, approve while the poll loop is running.
        let waiting = Task {
            try await authenticator.waitForQuickConnectApproval(
                session: newDevice, state: state, pollInterval: 0.3, timeout: 20
            )
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let authorize = approver.request(
            path: "QuickConnect/Authorize",
            query: [
                URLQueryItem(name: "code", value: state.code),
                URLQueryItem(name: "userId", value: approver.userID),
            ],
            method: "POST"
        )
        let (_, authorizeResponse) = try await URLSessionTransport().send(authorize)
        XCTAssertEqual(authorizeResponse.statusCode, 200)
        try await waiting.value

        let result = try await authenticator.signInWithQuickConnect(session: newDevice, state: state)
        XCTAssertTrue(result.session.isAuthenticated)
        XCTAssertEqual(result.session.userID, approver.userID)
        XCTAssertNotEqual(result.session.accessToken, approver.accessToken, "the new device gets its own token")
        let validity = await authenticator.validate(session: result.session)
        XCTAssertEqual(validity, .valid(userName: result.userName))

        await authenticator.logout(session: result.session)
        await authenticator.logout(session: approver)
    }

    func testUnknownQuickConnectSecretExpires() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        let state = JellyfinAuthenticator.QuickConnectState(secret: "not-a-real-secret", code: "000000")
        do {
            try await JellyfinAuthenticator().waitForQuickConnectApproval(session: freshSession(info), state: state)
            XCTFail("expected quickConnectExpired")
        } catch {
            XCTAssertEqual(error as? JellyfinConnectionError, .quickConnectExpired)
        }
    }

    func testCancellingQuickConnectWaitStopsPolling() async throws {
        let server = try server()
        let info = try await JellyfinServerDiscovery().discover(address: server.address)
        let authenticator = JellyfinAuthenticator()
        let session = freshSession(info)
        let state = try await authenticator.initiateQuickConnect(session: session)
        let waiting = Task {
            try await authenticator.waitForQuickConnectApproval(session: session, state: state, pollInterval: 0.2)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
