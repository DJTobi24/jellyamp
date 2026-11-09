import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport driven by a closure, so a test can answer per URL, count calls,
/// throw transport errors and simulate redirects.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var finalURL: URL?

        static func json(_ json: String, status: Int = 200, finalURL: URL? = nil) -> Reply {
            Reply(status: status, body: Data(json.utf8), finalURL: finalURL)
        }

        static func status(_ status: Int) -> Reply {
            Reply(status: status, body: Data(), finalURL: nil)
        }
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) async throws -> Reply

    /// - Parameter handler: receives the request and how many requests were
    ///   seen before it.
    init(_ handler: @escaping @Sendable (URLRequest, Int) async throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return recorded.count - 1
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = record(request)
        let reply = try await handler(request, index)
        let response = HTTPURLResponse(
            url: reply.finalURL ?? request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (reply.body, response)
    }
}

private let publicInfo = """
{"LocalAddress":"http://172.17.0.2:8096","ServerName":"Living Room","Version":"10.10.7",\
"ProductName":"Jellyfin Server","OperatingSystem":"","Id":"server-1","StartupWizardCompleted":true}
"""

private let authJSON = """
{"AccessToken":"token-abc-123","ServerId":"server-1","User":{"Id":"user-1","Name":"tobi"}}
"""

private let freshSession = JellyfinSession(serverURL: URL(string: "http://jellyfin.local:8096")!, deviceID: "d1")

private func assertThrows<T>(
    _ expected: JellyfinConnectionError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as JellyfinConnectionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

// MARK: - Address normalization

final class ServerAddressTests: XCTestCase {
    private func candidates(_ input: String) throws -> [String] {
        try ServerAddress.candidates(for: input).map(\.absoluteString)
    }

    func testBareHostTriesHTTPSThenDefaultPortThenHTTP() throws {
        XCTAssertEqual(
            try candidates("jellyfin.local"),
            ["https://jellyfin.local", "http://jellyfin.local:8096", "http://jellyfin.local"]
        )
    }

    func testHostWithPortTriesHTTPSThenHTTPOnThatPort() throws {
        XCTAssertEqual(try candidates("192.168.1.5:8096"), ["https://192.168.1.5:8096", "http://192.168.1.5:8096"])
    }

    func testExplicitSchemeIsRespected() throws {
        XCTAssertEqual(try candidates("http://jellyfin.local:8096"), ["http://jellyfin.local:8096"])
        XCTAssertEqual(try candidates("HTTPS://Music.Example.COM"), ["https://music.example.com"])
    }

    func testTrimsWhitespaceAndTrailingSlashes() throws {
        XCTAssertEqual(try candidates("  https://music.example.com///  \n"), ["https://music.example.com"])
    }

    func testStripsWebClientSuffixes() throws {
        XCTAssertEqual(try candidates("https://music.example.com/web/index.html"), ["https://music.example.com"])
        XCTAssertEqual(try candidates("https://music.example.com/web/"), ["https://music.example.com"])
        XCTAssertEqual(
            try candidates("https://music.example.com/web/index.html#/home.html?x=1"),
            ["https://music.example.com"]
        )
        XCTAssertEqual(try candidates("http://nas:8096/web/#/login.html"), ["http://nas:8096"])
    }

    func testKeepsReverseProxyBasePath() throws {
        XCTAssertEqual(
            try candidates("https://example.com/jellyfin/web/index.html"),
            ["https://example.com/jellyfin"]
        )
        XCTAssertEqual(
            try candidates("example.com/jellyfin/"),
            ["https://example.com/jellyfin", "http://example.com:8096/jellyfin", "http://example.com/jellyfin"]
        )
    }

    func testDropsCredentialsInURL() throws {
        XCTAssertEqual(try candidates("https://tobi:secret@music.example.com"), ["https://music.example.com"])
    }

    func testRejectsGarbage() {
        for input in ["", "   ", "ftp://example.com", "my server", "http://", "://", "#/home.html"] {
            XCTAssertThrowsError(try ServerAddress.candidates(for: input), input) { error in
                XCTAssertEqual(error as? JellyfinConnectionError, .invalidAddress, input)
            }
        }
    }
}

final class ServerVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(JellyfinServerVersion("10.10.7"), JellyfinServerVersion(major: 10, minor: 10, patch: 7))
        XCTAssertEqual(JellyfinServerVersion("10.9"), JellyfinServerVersion(major: 10, minor: 9, patch: 0))
        XCTAssertEqual(JellyfinServerVersion("10.11.0-rc2"), JellyfinServerVersion(major: 10, minor: 11, patch: 0))
        XCTAssertNil(JellyfinServerVersion("unstable"))
        XCTAssertNil(JellyfinServerVersion(""))
    }

    func testOrderingIsNumericNotLexical() {
        XCTAssertTrue(JellyfinServerVersion("10.8.13")! < .minimumSupported)
        XCTAssertFalse(JellyfinServerVersion("10.9.0")! < .minimumSupported)
        XCTAssertTrue(JellyfinServerVersion("10.9.11")! < JellyfinServerVersion("10.10.0")!)
    }
}

// MARK: - Discovery

final class ServerDiscoveryTests: XCTestCase {
    func testProbeReturnsServerInfo() async throws {
        let transport = ScriptedTransport { _, _ in .json(publicInfo) }
        let info = try await JellyfinServerDiscovery(transport: transport)
            .probe(url: URL(string: "http://jellyfin.local:8096")!)
        XCTAssertEqual(info.name, "Living Room")
        XCTAssertEqual(info.version, "10.10.7")
        XCTAssertEqual(info.id, "server-1")
        XCTAssertEqual(info.url.absoluteString, "http://jellyfin.local:8096")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "http://jellyfin.local:8096/System/Info/Public")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testDiscoverFallsBackToHTTPWhenHTTPSFails() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.url?.scheme == "https" { throw URLError(.cannotConnectToHost) }
            return .json(publicInfo)
        }
        let info = try await JellyfinServerDiscovery(transport: transport).discover(address: "192.168.1.5:8096")
        XCTAssertEqual(info.url.absoluteString, "http://192.168.1.5:8096")
    }

    func testDiscoverPrefersHTTPSEvenWhenHTTPAnswersFirst() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.url?.scheme == "https" {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            return .json(publicInfo)
        }
        let info = try await JellyfinServerDiscovery(transport: transport).discover(address: "music.example.com")
        XCTAssertEqual(info.url.absoluteString, "https://music.example.com")
    }

    func testDiscoverBareHostFindsDefaultPort() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.url?.port == 8096 { return .json(publicInfo) }
            throw URLError(.cannotConnectToHost)
        }
        let info = try await JellyfinServerDiscovery(transport: transport).discover(address: "jellyfin.local")
        XCTAssertEqual(info.url.absoluteString, "http://jellyfin.local:8096")
    }

    func testAdoptsRedirectTarget() async throws {
        let transport = ScriptedTransport { _, _ in
            .json(publicInfo, finalURL: URL(string: "https://music.example.com/jellyfin/System/Info/Public")!)
        }
        let info = try await JellyfinServerDiscovery(transport: transport)
            .probe(url: URL(string: "http://music.example.com/jellyfin")!)
        XCTAssertEqual(info.url.absoluteString, "https://music.example.com/jellyfin")
    }

    func testIgnoresRedirectToUnrelatedPage() {
        let requested = URL(string: "http://router.local")!
        XCTAssertEqual(
            JellyfinServerDiscovery.baseURL(afterRedirectTo: URL(string: "http://router.local/login.html"), requested: requested),
            requested
        )
    }

    func testUnreachableHost() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.cannotFindHost) }
        await assertThrows(.unreachable) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "nope.invalid")
        }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testTLSProblemIsReportedOverUnreachable() async {
        let transport = ScriptedTransport { request, _ in
            if request.url?.scheme == "https" { throw URLError(.serverCertificateUntrusted) }
            throw URLError(.cannotConnectToHost)
        }
        await assertThrows(.tlsFailure) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "music.example.com")
        }
    }

    func testNotJellyfin() async {
        let html = ScriptedTransport { _, _ in .json("<html><body>Router</body></html>") }
        await assertThrows(.notJellyfin) {
            try await JellyfinServerDiscovery(transport: html).discover(address: "http://router.local")
        }
        let notFound = ScriptedTransport { _, _ in .status(404) }
        await assertThrows(.notJellyfin) {
            try await JellyfinServerDiscovery(transport: notFound).discover(address: "http://router.local")
        }
        // Emby: same endpoint and shape, but no ProductName.
        let emby = ScriptedTransport { _, _ in
            .json(#"{"ServerName":"emby","Version":"4.8.10.0","Id":"abc","LocalAddress":"http://x:8096"}"#)
        }
        await assertThrows(.notJellyfin) {
            try await JellyfinServerDiscovery(transport: emby).discover(address: "http://emby.local:8096")
        }
    }

    func testServerTooOld() async {
        let old = publicInfo.replacingOccurrences(of: "10.10.7", with: "10.8.13")
        let transport = ScriptedTransport { _, _ in .json(old) }
        await assertThrows(.serverTooOld(version: "10.8.13", minimum: "10.9")) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "http://old.local:8096")
        }
    }

    func testTooOldBeatsOtherFailures() async {
        let old = publicInfo.replacingOccurrences(of: "10.10.7", with: "10.8.13")
        let transport = ScriptedTransport { request, _ in
            if request.url?.scheme == "https" { throw URLError(.secureConnectionFailed) }
            return .json(old)
        }
        await assertThrows(.serverTooOld(version: "10.8.13", minimum: "10.9")) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "old.local:8096")
        }
    }

    func testServerNotSetUp() async {
        let fresh = publicInfo.replacingOccurrences(of: "\"StartupWizardCompleted\":true", with: "\"StartupWizardCompleted\":false")
        let transport = ScriptedTransport { _, _ in .json(fresh) }
        await assertThrows(.serverNotSetUp) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "http://new.local:8096")
        }
    }

    func testBadGatewayIsServerUnavailable() async {
        let transport = ScriptedTransport { _, _ in .status(502) }
        await assertThrows(.serverUnavailable(status: 502)) {
            try await JellyfinServerDiscovery(transport: transport).discover(address: "https://music.example.com")
        }
    }

    func testMissingServerNameFallsBackToHost() async throws {
        let transport = ScriptedTransport { _, _ in
            .json(#"{"Version":"10.9.0","ProductName":"Jellyfin Server","Id":"x"}"#)
        }
        let info = try await JellyfinServerDiscovery(transport: transport).probe(url: URL(string: "http://nas:8096")!)
        XCTAssertEqual(info.name, "nas")
    }

    func testCancellationIsNotReportedAsFailure() async {
        let transport = ScriptedTransport { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .json(publicInfo)
        }
        let task = Task { try await JellyfinServerDiscovery(transport: transport).discover(address: "slow.local") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

// MARK: - Password sign-in

final class PasswordSignInTests: XCTestCase {
    func testSignInReturnsSessionAndUserName() async throws {
        let transport = ScriptedTransport { _, _ in .json(authJSON) }
        let result = try await JellyfinAuthenticator(transport: transport)
            .signIn(session: freshSession, username: "tobi", password: "pw")
        XCTAssertEqual(result.userName, "tobi")
        XCTAssertEqual(result.session.accessToken, "token-abc-123")
        XCTAssertEqual(result.session.userID, "user-1")
        XCTAssertTrue(result.session.isAuthenticated)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/Users/AuthenticateByName")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["Username": "tobi", "Pw": "pw"])
    }

    func testStatusMapping() async {
        let cases: [(Int, JellyfinConnectionError)] = [
            (401, .wrongCredentials),
            (403, .userDisabled),
            (503, .serverUnavailable(status: 503)),
            (404, .unexpectedResponse),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in .status(status) }
            await assertThrows(expected) {
                try await JellyfinAuthenticator(transport: transport)
                    .signIn(session: freshSession, username: "tobi", password: "bad")
            }
        }
    }

    func testGarbageSuccessBodyIsUnexpectedResponse() async {
        let transport = ScriptedTransport { _, _ in .json("<html>") }
        await assertThrows(.unexpectedResponse) {
            try await JellyfinAuthenticator(transport: transport)
                .signIn(session: freshSession, username: "tobi", password: "pw")
        }
    }

    func testTransportErrorsAreTyped() async {
        let offline = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await assertThrows(.unreachable) {
            try await JellyfinAuthenticator(transport: offline)
                .signIn(session: freshSession, username: "tobi", password: "pw")
        }
        let tls = ScriptedTransport { _, _ in throw URLError(.serverCertificateHasBadDate) }
        await assertThrows(.tlsFailure) {
            try await JellyfinAuthenticator(transport: tls)
                .signIn(session: freshSession, username: "tobi", password: "pw")
        }
    }

    func testLegacyAuthenticateByNameKeepsJellyfinError() async {
        let transport = ScriptedTransport { _, _ in .status(403) }
        do {
            _ = try await JellyfinAuthenticator(transport: transport)
                .authenticateByName(session: freshSession, username: "tobi", password: "pw")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .unauthorized)
        }
    }
}

// MARK: - Quick Connect

final class QuickConnectTests: XCTestCase {
    private let state = JellyfinAuthenticator.QuickConnectState(secret: "s3cret", code: "123456")
    private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

    func testEnabledProbe() async {
        let on = ScriptedTransport { _, _ in .json("true") }
        let onResult = await JellyfinAuthenticator(transport: on).isQuickConnectEnabled(session: freshSession)
        XCTAssertTrue(onResult)
        XCTAssertEqual(on.requests.first?.url?.path, "/QuickConnect/Enabled")

        let off = ScriptedTransport { _, _ in .json("false") }
        let offResult = await JellyfinAuthenticator(transport: off).isQuickConnectEnabled(session: freshSession)
        XCTAssertFalse(offResult)

        let broken = ScriptedTransport { _, _ in throw URLError(.timedOut) }
        let brokenResult = await JellyfinAuthenticator(transport: broken).isQuickConnectEnabled(session: freshSession)
        XCTAssertFalse(brokenResult)
    }

    func testInitiate() async throws {
        let transport = ScriptedTransport { _, _ in
            .json(#"{"Authenticated":false,"Secret":"s3cret","Code":"123456","DeviceId":"d1"}"#)
        }
        let initiated = try await JellyfinAuthenticator(transport: transport).initiateQuickConnect(session: freshSession)
        XCTAssertEqual(initiated, state)
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
        XCTAssertEqual(transport.requests.first?.url?.path, "/QuickConnect/Initiate")
    }

    func testInitiateWhenDisabled() async {
        let transport = ScriptedTransport { _, _ in .status(401) }
        await assertThrows(.quickConnectDisabled) {
            try await JellyfinAuthenticator(transport: transport).initiateQuickConnect(session: freshSession)
        }
    }

    func testWaitPollsUntilApprovedRidingOutHiccups() async throws {
        let transport = ScriptedTransport { request, index in
            XCTAssertEqual(request.url?.query, "secret=s3cret")
            switch index {
            case 0: return .json(#"{"Authenticated":false}"#)
            case 1: throw URLError(.networkConnectionLost)
            case 2: return .status(503)
            default: return .json(#"{"Authenticated":true}"#)
            }
        }
        try await JellyfinAuthenticator(transport: transport, sleep: noSleep)
            .waitForQuickConnectApproval(session: freshSession, state: state)
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testWaitTimesOut() async {
        let transport = ScriptedTransport { _, _ in .json(#"{"Authenticated":false}"#) }
        await assertThrows(.quickConnectExpired) {
            try await JellyfinAuthenticator(transport: transport, sleep: self.noSleep)
                .waitForQuickConnectApproval(session: freshSession, state: self.state, pollInterval: 2, timeout: 10)
        }
        // t = 0, 2, 4, 6, 8, 10 s
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testWaitStopsWhenSecretIsUnknown() async {
        let transport = ScriptedTransport { _, _ in .json("\"Unknown secret\"", status: 404) }
        await assertThrows(.quickConnectExpired) {
            try await JellyfinAuthenticator(transport: transport, sleep: self.noSleep)
                .waitForQuickConnectApproval(session: freshSession, state: self.state)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testWaitCancelsCleanly() async {
        let transport = ScriptedTransport { _, _ in .json(#"{"Authenticated":false}"#) }
        let authenticator = JellyfinAuthenticator(transport: transport)
        let state = self.state
        let task = Task {
            try await authenticator.waitForQuickConnectApproval(session: freshSession, state: state, pollInterval: 30)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSignInWithQuickConnect() async throws {
        let transport = ScriptedTransport { _, _ in .json(authJSON) }
        let result = try await JellyfinAuthenticator(transport: transport)
            .signInWithQuickConnect(session: freshSession, state: state)
        XCTAssertEqual(result.userName, "tobi")
        XCTAssertEqual(result.session.accessToken, "token-abc-123")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/Users/AuthenticateWithQuickConnect")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["Secret": "s3cret"])
    }

    func testSignInWithUnapprovedSecret() async {
        let transport = ScriptedTransport { _, _ in .status(401) }
        await assertThrows(.quickConnectExpired) {
            try await JellyfinAuthenticator(transport: transport)
                .signInWithQuickConnect(session: freshSession, state: self.state)
        }
    }
}

// MARK: - Session lifecycle

final class SessionLifecycleTests: XCTestCase {
    private let signedIn = JellyfinSession(
        serverURL: URL(string: "http://jellyfin.local:8096")!,
        deviceID: "d1",
        accessToken: "token-abc-123",
        userID: "user-1"
    )

    func testValidToken() async {
        let transport = ScriptedTransport { _, _ in .json(#"{"Name":"tobi","Id":"user-1"}"#) }
        let validity = await JellyfinAuthenticator(transport: transport).validate(session: signedIn)
        XCTAssertEqual(validity, .valid(userName: "tobi"))
        XCTAssertEqual(transport.requests.first?.url?.path, "/Users/Me")
        XCTAssertTrue(transport.requests.first?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc-123\"") ?? false)
    }

    func testRejectedToken() async {
        let transport = ScriptedTransport { _, _ in .status(401) }
        let validity = await JellyfinAuthenticator(transport: transport).validate(session: signedIn)
        XCTAssertEqual(validity, .rejected)
    }

    func testOfflineAndServerTroubleKeepTheSession() async {
        let offline = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let offlineResult = await JellyfinAuthenticator(transport: offline).validate(session: signedIn)
        XCTAssertEqual(offlineResult, .indeterminate)

        for status in [403, 404, 500, 502, 503] {
            let transport = ScriptedTransport { _, _ in .status(status) }
            let validity = await JellyfinAuthenticator(transport: transport).validate(session: signedIn)
            XCTAssertEqual(validity, .indeterminate, "\(status)")
        }

        let captivePortal = ScriptedTransport { _, _ in .json("<html>Please log in to the Wi-Fi</html>") }
        let portalResult = await JellyfinAuthenticator(transport: captivePortal).validate(session: signedIn)
        XCTAssertEqual(portalResult, .indeterminate)
    }

    func testSessionWithoutTokenIsRejectedWithoutNetwork() async {
        let transport = ScriptedTransport { _, _ in .status(200) }
        let validity = await JellyfinAuthenticator(transport: transport).validate(session: freshSession)
        XCTAssertEqual(validity, .rejected)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLogoutPostsAndSwallowsFailures() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await JellyfinAuthenticator(transport: transport).logout(session: signedIn)
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
        XCTAssertEqual(transport.requests.first?.url?.path, "/Sessions/Logout")

        let unauthenticated = ScriptedTransport { _, _ in .status(204) }
        await JellyfinAuthenticator(transport: unauthenticated).logout(session: freshSession)
        XCTAssertTrue(unauthenticated.requests.isEmpty)
    }

    func testUnauthorizedReportingTransportReportsOnlyAuthenticated401s() async throws {
        let counter = Counter()
        let base = ScriptedTransport { request, _ in
            .status(request.url!.path.contains("ok") ? 200 : 401)
        }
        let transport = UnauthorizedReportingTransport(base: base) { counter.increment() }

        _ = try await transport.send(signedIn.request(path: "ok"))
        XCTAssertEqual(counter.value, 0)

        // Wrong password during sign-in: 401, but no token involved.
        _ = try await transport.send(freshSession.request(path: "Users/AuthenticateByName", method: "POST"))
        XCTAssertEqual(counter.value, 0)

        let (_, response) = try await transport.send(signedIn.request(path: "Items"))
        XCTAssertEqual(response.statusCode, 401, "the response still reaches the caller")
        XCTAssertEqual(counter.value, 1)
    }

    func testUnauthorizedReportingTransportWorksUnderAPIClients() async {
        let counter = Counter()
        let base = ScriptedTransport { _, _ in .status(401) }
        let api = MusicLibraryAPI(
            session: signedIn,
            transport: UnauthorizedReportingTransport(base: base) { counter.increment() }
        )
        _ = try? await api.albums()
        XCTAssertEqual(counter.value, 1)
    }

    func testAccountDecodesFromOldAndNewStoredSessions() throws {
        // What app versions before the account fields wrote to the Keychain.
        let old = Data(#"{"serverURL":"http://jellyfin.local:8096","deviceID":"d1","accessToken":"t","userID":"u"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(JellyfinAccount.self, from: old), JellyfinAccount())

        let account = JellyfinAccount(serverName: "Living Room", serverVersion: "10.10.7", userName: "tobi")
        let roundTripped = try JSONDecoder().decode(JellyfinAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(roundTripped, account)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
