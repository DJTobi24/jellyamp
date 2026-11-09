import XCTest
@testable import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Test doubles

/// Answers each request with the next canned response (the last one repeats).
private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = "{}"
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var recorded: [URLRequest] = []
    var failure: Error?

    init(_ responses: [Response] = [Response()]) {
        self.responses = responses
    }

    convenience init(status: Int = 200, body: String, headers: [String: String] = [:]) {
        self.init([Response(status: status, body: body, headers: headers)])
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response = try lock.withLock {
            recorded.append(request)
            if let failure { throw failure }
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (Data(response.body.utf8), http)
    }
}

/// Decodes a form body back into its fields.
private func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0]).removingPercentEncoding ?? ""
        let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
        fields[name] = value
    }
    return fields
}

private actor FakeTarget: ScrobbleTarget {
    nonisolated let service: ScrobbleServiceID
    nonisolated let maxBatchSize: Int
    private(set) var submitted: [[ScrobbleListen]] = []
    private(set) var nowPlaying: [ScrobbleListen] = []
    private var failures: [ScrobbleDeliveryError] = []

    init(service: ScrobbleServiceID, maxBatchSize: Int = 50) {
        self.service = service
        self.maxBatchSize = maxBatchSize
    }

    /// The next submits fail with these errors, in order.
    func fail(with errors: [ScrobbleDeliveryError]) {
        failures = errors
    }

    func sendNowPlaying(_ listen: ScrobbleListen) async throws {
        nowPlaying.append(listen)
    }

    func submit(_ listens: [ScrobbleListen]) async throws {
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        submitted.append(listens)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func makeListen(_ index: Int, startedAt: Date? = nil) -> ScrobbleListen {
    ScrobbleListen(
        trackID: "t\(index)",
        title: "T\(index)",
        artist: "A\(index)",
        album: "Album",
        duration: 200,
        trackNumber: index,
        startedAt: startedAt ?? epoch.addingTimeInterval(TimeInterval(index))
    )
}

// MARK: - MD5

final class MD5Tests: XCTestCase {
    func testRFC1321Vectors() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "d174ab98d277d9f5a5611c2c9f419d9f"),
            (
                "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
                "57edf4a22be3c955ac49da2e2107b67a"
            ),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(MD5.hexDigest(of: input), expected, "MD5(\"\(input)\")")
        }
    }

    func testPaddingBoundariesAndMultiBlockInput() {
        // 55 bytes fit one block with padding, 56 force a second, 64 is a
        // full block; reference values from Python's hashlib.
        XCTAssertEqual(MD5.hexDigest(of: String(repeating: "x", count: 55)), "04364420e25c512fd958a70738aa8f72")
        XCTAssertEqual(MD5.hexDigest(of: String(repeating: "x", count: 56)), "668a72d5ba17f08e62dabcafad6db14b")
        XCTAssertEqual(MD5.hexDigest(of: String(repeating: "x", count: 64)), "c1bb4f81d892b2d57947682aeb252456")
        XCTAssertEqual(MD5.hexDigest(of: String(repeating: "a", count: 1000)), "cabe45dcc9ae5b66ba86600cca6b8ba8")
    }

    func testHashesUTF8Bytes() {
        XCTAssertEqual(MD5.hexDigest(of: "The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(MD5.digest(Array("abc".utf8)).count, 16)
    }
}

// MARK: - Last.fm

final class LastFMClientTests: XCTestCase {
    private let credentials = LastFMCredentials(apiKey: "KEY", sharedSecret: "SECRET")

    func testCredentialsFromConfigurationRejectMissingOrUnexpandedValues() {
        XCTAssertNil(LastFMCredentials(configuredAPIKey: nil, configuredSecret: "s"))
        XCTAssertNil(LastFMCredentials(configuredAPIKey: "", configuredSecret: "s"))
        XCTAssertNil(LastFMCredentials(configuredAPIKey: "$(LASTFM_API_KEY)", configuredSecret: "$(LASTFM_API_SECRET)"))
        XCTAssertEqual(
            LastFMCredentials(configuredAPIKey: " abc \n", configuredSecret: "def"),
            LastFMCredentials(apiKey: "abc", sharedSecret: "def")
        )
    }

    func testSignatureSortsParametersAndSkipsFormat() {
        // md5("api_keyKEYmethodauth.getTokenSECRET")
        XCTAssertEqual(
            LastFMClient.signature(parameters: ["method": "auth.getToken", "api_key": "KEY", "format": "json"], secret: "SECRET"),
            "66ee63a18da3c919f987b342697d913c"
        )
        XCTAssertEqual(
            LastFMClient.signature(
                parameters: ["token": "TOK", "method": "auth.getSession", "api_key": "KEY", "callback": "x"],
                secret: "SECRET"
            ),
            "0bf279e021f3a81b4553dd7e76cf72ad"
        )
    }

    func testSignatureUsesRawUTF8ValuesNotEncodedOnes() {
        let parameters = [
            "method": "track.updateNowPlaying", "api_key": "KEY", "sk": "SK",
            "artist": "Sigur Rós", "track": "Hoppípolla & more=1+1", "album": "Takk...",
            "duration": "269", "trackNumber": "3",
        ]
        XCTAssertEqual(LastFMClient.signature(parameters: parameters, secret: "SECRET"), "6ab53bb85241377fe1ad645eb82aa1c0")
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(LastFMClient.percentEncode("AC/DC & Friends=1+1 é~"), "AC%2FDC%20%26%20Friends%3D1%2B1%20%C3%A9~")
        XCTAssertEqual(
            LastFMClient.formEncode(["track[0]": "a b", "artist[0]": "x&y"]),
            "artist%5B0%5D=x%26y&track%5B0%5D=a%20b"
        )
    }

    func testGetTokenRequestAndAuthorizationURL() async throws {
        let transport = CannedTransport(body: #"{"token":"cf45fe5a3e3cebe168480a086d7fe481"}"#)
        let client = LastFMClient(credentials: credentials, transport: transport)
        let token = try await client.getToken()
        XCTAssertEqual(token, "cf45fe5a3e3cebe168480a086d7fe481")

        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://ws.audioscrobbler.com/2.0/")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(formFields(request), [
            "method": "auth.getToken",
            "api_key": "KEY",
            "api_sig": "66ee63a18da3c919f987b342697d913c",
            "format": "json",
        ])

        XCTAssertEqual(
            client.authorizationURL(token: token).absoluteString,
            "https://www.last.fm/api/auth/?api_key=KEY&token=cf45fe5a3e3cebe168480a086d7fe481"
        )
    }

    func testGetSessionParsesSessionAndSignsToken() async throws {
        let transport = CannedTransport(body: #"{"session":{"subscriber":0,"name":"rj","key":"d580d57f32848f5dcf574d1ce18d78b2"}}"#)
        let client = LastFMClient(credentials: credentials, transport: transport)
        let session = try await client.getSession(token: "TOK")
        XCTAssertEqual(session, LastFMSession(username: "rj", key: "d580d57f32848f5dcf574d1ce18d78b2"))

        let fields = formFields(transport.requests[0])
        XCTAssertEqual(fields["method"], "auth.getSession")
        XCTAssertEqual(fields["token"], "TOK")
        XCTAssertEqual(fields["api_sig"], "0bf279e021f3a81b4553dd7e76cf72ad")
        XCTAssertNil(fields["sk"], "auth calls carry no session key")
    }

    func testGetSessionBeforeApprovalIsAuthorizationPending() async {
        let transport = CannedTransport(status: 403, body: #"{"error":14,"message":"This token has not been authorized"}"#)
        let client = LastFMClient(credentials: credentials, transport: transport)
        do {
            _ = try await client.getSession(token: "TOK")
            XCTFail("expected error")
        } catch let error as LastFMError {
            XCTAssertEqual(error, .api(code: 14, message: "This token has not been authorized"))
            XCTAssertEqual(error.kind, .authorizationPending)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testErrorKinds() {
        func kind(_ code: Int) -> LastFMError.Kind { LastFMError.api(code: code, message: "").kind }
        XCTAssertEqual(kind(9), .invalidSession)
        XCTAssertEqual(kind(11), .retryLater)
        XCTAssertEqual(kind(16), .retryLater)
        XCTAssertEqual(kind(29), .retryLater)
        XCTAssertEqual(kind(8), .retryLater)
        XCTAssertEqual(kind(4), .invalidToken)
        XCTAssertEqual(kind(15), .invalidToken)
        XCTAssertEqual(kind(14), .authorizationPending)
        XCTAssertEqual(kind(10), .invalidAPIKey)
        XCTAssertEqual(kind(26), .invalidAPIKey)
        XCTAssertEqual(kind(6), .other)
        XCTAssertEqual(LastFMError.http(status: 503).kind, .retryLater)
        XCTAssertEqual(LastFMError.http(status: 404).kind, .other)
    }

    func testErrorBodyWinsOverHTTPStatus() async {
        // Last.fm sometimes reports errors with HTTP 200.
        let transport = CannedTransport(status: 200, body: #"{"error":9,"message":"Invalid session key - Please re-authenticate"}"#)
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        do {
            try await client.updateNowPlaying(makeListen(1))
            XCTFail("expected error")
        } catch let error as LastFMError {
            XCTAssertEqual(error.kind, .invalidSession)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNonJSONServerFailureIsHTTPError() async {
        let transport = CannedTransport(status: 502, body: "<html>Bad Gateway</html>")
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        do {
            _ = try await client.scrobble([makeListen(1)])
            XCTFail("expected error")
        } catch let error as LastFMError {
            XCTAssertEqual(error, .http(status: 502))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAuthenticatedCallWithoutSessionKeyDoesNotHitTheNetwork() async {
        let transport = CannedTransport()
        let client = LastFMClient(credentials: credentials, transport: transport)
        do {
            try await client.updateNowPlaying(makeListen(1))
            XCTFail("expected error")
        } catch let error as LastFMError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUpdateNowPlayingFields() async throws {
        let transport = CannedTransport(body: ##"{"nowplaying":{"artist":{"corrected":"0","#text":"Sigur Rós"},"ignoredMessage":{"code":"0","#text":""}}}"##)
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        let listen = ScrobbleListen(
            trackID: "x", title: "Hoppípolla & more=1+1", artist: "Sigur Rós", album: "Takk...",
            duration: 269.4, trackNumber: 3, startedAt: epoch
        )
        try await client.updateNowPlaying(listen)

        let request = transport.requests[0]
        let raw = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(raw.contains("artist=Sigur%20R%C3%B3s"), raw)
        XCTAssertTrue(raw.contains("track=Hopp%C3%ADpolla%20%26%20more%3D1%2B1"), raw)
        XCTAssertEqual(formFields(request), [
            "method": "track.updateNowPlaying",
            "api_key": "KEY",
            "sk": "SK",
            "artist": "Sigur Rós",
            "track": "Hoppípolla & more=1+1",
            "album": "Takk...",
            "duration": "269",
            "trackNumber": "3",
            "api_sig": "6ab53bb85241377fe1ad645eb82aa1c0",
            "format": "json",
        ])
    }

    func testScrobbleBatchUsesIndexedParametersAndSignature() async throws {
        let transport = CannedTransport(body: #"{"scrobbles":{"@attr":{"accepted":11,"ignored":0},"scrobble":[]}}"#)
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        let listens = (0..<11).map {
            ScrobbleListen(trackID: "t\($0)", title: "T\($0)", artist: "A\($0)", startedAt: epoch.addingTimeInterval(TimeInterval($0)))
        }
        let result = try await client.scrobble(listens)
        XCTAssertEqual(result, LastFMScrobbleResult(accepted: 11, ignored: 0))

        let fields = formFields(transport.requests[0])
        XCTAssertEqual(fields["method"], "track.scrobble")
        XCTAssertEqual(fields["artist[0]"], "A0")
        XCTAssertEqual(fields["track[10]"], "T10")
        XCTAssertEqual(fields["timestamp[10]"], "1700000010")
        XCTAssertNil(fields["album[0]"], "absent metadata is omitted, not sent empty")
        // Signature over 11 entries: byte order puts artist[10] before artist[1].
        XCTAssertEqual(fields["api_sig"], "e58cc87f39c6cfd8e9d1cf6af1313656")
        XCTAssertEqual(fields.count, 3 * 11 + 5)
    }

    func testScrobbleSendsOptionalMetadata() async throws {
        let transport = CannedTransport(body: #"{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"},"scrobble":{}}}"#)
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        var listen = makeListen(7)
        listen.albumArtist = "Various Artists"
        let result = try await client.scrobble([listen])
        XCTAssertEqual(result.accepted, 1, "string counts are tolerated")

        let fields = formFields(transport.requests[0])
        XCTAssertEqual(fields["album[0]"], "Album")
        XCTAssertEqual(fields["albumArtist[0]"], "Various Artists")
        XCTAssertEqual(fields["duration[0]"], "200")
        XCTAssertEqual(fields["trackNumber[0]"], "7")
        XCTAssertEqual(fields["timestamp[0]"], "1700000007")
    }

    func testScrobbleSplitsIntoRequestsOfFifty() async throws {
        let transport = CannedTransport([
            .init(body: #"{"scrobbles":{"@attr":{"accepted":50,"ignored":0}}}"#),
            .init(body: #"{"scrobbles":{"@attr":{"accepted":49,"ignored":1}}}"#),
            .init(body: #"{"scrobbles":{"@attr":{"accepted":20,"ignored":0}}}"#),
        ])
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        let result = try await client.scrobble((0..<120).map { makeListen($0) })
        XCTAssertEqual(result, LastFMScrobbleResult(accepted: 119, ignored: 1))
        XCTAssertEqual(transport.requests.count, 3)
        let last = formFields(transport.requests[2])
        XCTAssertEqual(last["track[19]"], "T119")
        XCTAssertNil(last["track[20]"])
    }

    func testGetUserInfo() async throws {
        let transport = CannedTransport(body: #"{"user":{"name":"rj","playcount":"150316","url":"https://www.last.fm/user/RJ"}}"#)
        let client = LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport)
        let user = try await client.getUserInfo()
        XCTAssertEqual(user.name, "rj")
        XCTAssertEqual(user.playCount, 150_316)
        XCTAssertEqual(user.profileURL?.absoluteString, "https://www.last.fm/user/RJ")
        let fields = formFields(transport.requests[0])
        XCTAssertEqual(fields["method"], "user.getInfo")
        XCTAssertEqual(fields["sk"], "SK")
    }

    func testTargetMapsErrorsForTheQueue() async {
        func deliveryError(status: Int = 200, body: String, failure: Error? = nil) async -> ScrobbleDeliveryError? {
            let transport = CannedTransport(status: status, body: body)
            transport.failure = failure
            let target = LastFMScrobbleTarget(client: LastFMClient(credentials: credentials, sessionKey: "SK", transport: transport))
            do {
                try await target.submit([makeListen(1)])
                return nil
            } catch {
                return error as? ScrobbleDeliveryError
            }
        }

        let invalidSession = await deliveryError(status: 403, body: #"{"error":9,"message":"Invalid session key"}"#)
        guard case .reauthenticate = invalidSession else { return XCTFail("\(String(describing: invalidSession))") }

        let offline = await deliveryError(body: #"{"error":11,"message":"Service Offline"}"#)
        guard case .retryLater(let offlineDelay, _) = offline else { return XCTFail("\(String(describing: offline))") }
        XCTAssertNil(offlineDelay)

        let rateLimited = await deliveryError(status: 429, body: #"{"error":29,"message":"Rate Limit Exceeded"}"#)
        guard case .retryLater(let rateDelay, _) = rateLimited else { return XCTFail("\(String(describing: rateLimited))") }
        XCTAssertEqual(rateDelay, 300)

        let invalidParameters = await deliveryError(status: 400, body: #"{"error":6,"message":"Invalid parameters"}"#)
        guard case .rejected = invalidParameters else { return XCTFail("\(String(describing: invalidParameters))") }

        let noNetwork = await deliveryError(body: "{}", failure: URLError(.notConnectedToInternet))
        XCTAssertEqual(noNetwork, .offline)

        let accepted = await deliveryError(body: #"{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}"#)
        XCTAssertNil(accepted)
    }
}

// MARK: - ListenBrainz

final class ListenBrainzScrobblingTests: XCTestCase {
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    func testSingleListenCarriesAdditionalInfo() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", transport: transport, clientVersion: "1.0")
        try await client.submit(listens: [makeListen(4)])

        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.listenbrainz.org/1/submit-listens")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try json(request)
        XCTAssertEqual(body["listen_type"] as? String, "single")
        let listen = try XCTUnwrap((body["payload"] as? [[String: Any]])?.first)
        XCTAssertEqual(listen["listened_at"] as? Int, 1_700_000_004)
        let metadata = try XCTUnwrap(listen["track_metadata"] as? [String: Any])
        XCTAssertEqual(metadata["artist_name"] as? String, "A4")
        XCTAssertEqual(metadata["track_name"] as? String, "T4")
        XCTAssertEqual(metadata["release_name"] as? String, "Album")
        let info = try XCTUnwrap(metadata["additional_info"] as? [String: Any])
        XCTAssertEqual(info["media_player"] as? String, "Jellyamp")
        XCTAssertEqual(info["submission_client"] as? String, "Jellyamp")
        XCTAssertEqual(info["submission_client_version"] as? String, "1.0")
        XCTAssertEqual(info["duration_ms"] as? Int, 200_000)
        XCTAssertEqual(info["tracknumber"] as? Int, 4)
    }

    func testUnknownMetadataIsOmitted() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submit(listens: [ScrobbleListen(trackID: "x", title: "T", artist: "A", startedAt: epoch)])
        let listen = try XCTUnwrap((try json(transport.requests[0])["payload"] as? [[String: Any]])?.first)
        let metadata = try XCTUnwrap(listen["track_metadata"] as? [String: Any])
        XCTAssertNil(metadata["release_name"])
        let info = try XCTUnwrap(metadata["additional_info"] as? [String: Any])
        XCTAssertEqual(Set(info.keys), ["media_player", "submission_client"])
    }

    func testSeveralListensGoAsImport() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submit(listens: [makeListen(1), makeListen(2), makeListen(3)])
        XCTAssertEqual(transport.requests.count, 1)
        let body = try json(transport.requests[0])
        XCTAssertEqual(body["listen_type"] as? String, "import")
        let payload = try XCTUnwrap(body["payload"] as? [[String: Any]])
        XCTAssertEqual(payload.compactMap { $0["listened_at"] as? Int }, [1_700_000_001, 1_700_000_002, 1_700_000_003])
    }

    func testImportIsSplitAtOneThousandListens() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submit(listens: (0..<1001).map { makeListen($0) })
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual((try json(transport.requests[0])["payload"] as? [[String: Any]])?.count, 1000)
        XCTAssertEqual((try json(transport.requests[1])["payload"] as? [[String: Any]])?.count, 1)
    }

    func testNowPlayingHasNoTimestamp() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submitNowPlaying(listen: makeListen(1))
        let body = try json(transport.requests[0])
        XCTAssertEqual(body["listen_type"] as? String, "playing_now")
        let listen = try XCTUnwrap((body["payload"] as? [[String: Any]])?.first)
        XCTAssertNil(listen["listened_at"])
    }

    func testCustomServerURL() async throws {
        let transport = CannedTransport(body: #"{"status":"ok"}"#)
        let client = ListenBrainzClient(token: "tok", baseURL: URL(string: "https://maloja.example/apis/listenbrainz")!, transport: transport)
        try await client.submit(listens: [makeListen(1)])
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://maloja.example/apis/listenbrainz/1/submit-listens")
    }

    func testTokenOwner() async throws {
        let valid = CannedTransport(body: #"{"code":200,"message":"Token valid.","valid":true,"user_name":"rob"}"#)
        let owner = try await ListenBrainzClient(token: "tok", transport: valid).tokenOwner()
        XCTAssertEqual(owner, "rob")
        XCTAssertEqual(valid.requests[0].url?.absoluteString, "https://api.listenbrainz.org/1/validate-token")
        XCTAssertEqual(valid.requests[0].value(forHTTPHeaderField: "Authorization"), "Token tok")

        let invalid = CannedTransport(body: #"{"code":200,"message":"Token invalid.","valid":false}"#)
        let nobody = try await ListenBrainzClient(token: "bad", transport: invalid).tokenOwner()
        XCTAssertNil(nobody)
        let isValid = try await ListenBrainzClient(token: "bad", transport: invalid).validateToken()
        XCTAssertFalse(isValid)
    }

    func testRateLimitHeaders() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-RateLimit-Limit": "30", "x-ratelimit-remaining": "0", "X-RateLimit-Reset-In": "7"]
        )!
        XCTAssertEqual(ListenBrainzRateLimit(response: response), ListenBrainzRateLimit(remaining: 0, resetIn: 7))
    }

    func testStatusCodesMapToTypedErrors() async {
        func submitError(status: Int, body: String = "{}", headers: [String: String] = [:]) async -> ScrobbleError? {
            let transport = CannedTransport(status: status, body: body, headers: headers)
            do {
                try await ListenBrainzClient(token: "tok", transport: transport).submit(listens: [makeListen(1)])
                return nil
            } catch {
                return error as? ScrobbleError
            }
        }
        let tooMany = await submitError(status: 429, headers: ["X-RateLimit-Reset-In": "12"])
        XCTAssertEqual(tooMany, .rateLimited(retryAfter: 12))
        let unauthorized = await submitError(status: 401, body: #"{"code":401,"error":"Invalid authorization token."}"#)
        XCTAssertEqual(unauthorized, .unauthorized)
        let bad = await submitError(status: 400, body: #"{"code":400,"error":"JSON document is too large."}"#)
        XCTAssertEqual(bad, .rejected(status: 400, message: "JSON document is too large."))
        let down = await submitError(status: 503)
        XCTAssertEqual(down, .serverError(status: 503))
    }

    func testTargetMapsErrorsForTheQueue() async {
        func deliveryError(status: Int, headers: [String: String] = [:], failure: Error? = nil) async -> ScrobbleDeliveryError? {
            let transport = CannedTransport(status: status, body: "{}", headers: headers)
            transport.failure = failure
            let target = ListenBrainzScrobbleTarget(client: ListenBrainzClient(token: "tok", transport: transport))
            do {
                try await target.submit([makeListen(1)])
                return nil
            } catch {
                return error as? ScrobbleDeliveryError
            }
        }
        let limited = await deliveryError(status: 429, headers: ["X-RateLimit-Reset-In": "9"])
        guard case .retryLater(let delay, _) = limited else { return XCTFail("\(String(describing: limited))") }
        XCTAssertEqual(delay, 9)
        let unauthorized = await deliveryError(status: 401)
        guard case .reauthenticate = unauthorized else { return XCTFail("\(String(describing: unauthorized))") }
        let unavailable = await deliveryError(status: 502)
        guard case .retryLater = unavailable else { return XCTFail("\(String(describing: unavailable))") }
        let refused = await deliveryError(status: 400)
        guard case .rejected = refused else { return XCTFail("\(String(describing: refused))") }
        let offline = await deliveryError(status: 200, failure: URLError(.timedOut))
        XCTAssertEqual(offline, .offline)
    }
}

// MARK: - Coordinator

final class ScrobbleCoordinatorTests: XCTestCase {
    private func track(_ id: String = "t1", duration: TimeInterval = 200) -> Track {
        Track(id: id, title: "Song \(id)", artistName: "Artist", albumName: "Album", indexNumber: 2, duration: duration)
    }

    /// Plays normally: one sample per second from `from` to `to` seconds of
    /// position, wall clock advancing in step. Returns the actions emitted.
    private func play(
        _ coordinator: inout ScrobbleCoordinator,
        from: Int,
        to: Int,
        clock: inout Date
    ) -> [ScrobbleAction] {
        var actions: [ScrobbleAction] = []
        for second in from...to {
            actions += coordinator.progress(position: TimeInterval(second), at: clock)
            if second < to { clock = clock.addingTimeInterval(1) }
        }
        return actions
    }

    private func scrobbles(_ actions: [ScrobbleAction]) -> [ScrobbleListen] {
        actions.compactMap { action in
            if case .scrobble(let listen) = action { return listen }
            return nil
        }
    }

    private func nowPlayings(_ actions: [ScrobbleAction]) -> [ScrobbleListen] {
        actions.compactMap { action in
            if case .nowPlaying(let listen) = action { return listen }
            return nil
        }
    }

    func testRequiredPlayTimeRule() {
        XCTAssertNil(ScrobbleCoordinator.requiredPlayTime(forDuration: 30), "30 s or shorter never scrobbles")
        XCTAssertEqual(ScrobbleCoordinator.requiredPlayTime(forDuration: 31), 15.5)
        XCTAssertEqual(ScrobbleCoordinator.requiredPlayTime(forDuration: 200), 100)
        XCTAssertEqual(ScrobbleCoordinator.requiredPlayTime(forDuration: 3600), 240)
        XCTAssertEqual(ScrobbleCoordinator.requiredPlayTime(forDuration: nil), 240)
        XCTAssertEqual(ScrobbleCoordinator.requiredPlayTime(forDuration: 0), 240)
        XCTAssertTrue(ScrobbleCoordinator.qualifies(playedSeconds: 100, duration: 200))
        XCTAssertFalse(ScrobbleCoordinator.qualifies(playedSeconds: 99.9, duration: 200))
        XCTAssertFalse(ScrobbleCoordinator.qualifies(playedSeconds: 29, duration: 29))
    }

    func testNowPlayingOnStartAndScrobbleOnceAtHalf() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        XCTAssertTrue(coordinator.trackChanged(to: track(), at: clock).isEmpty, "nothing is announced before audio plays")
        let started = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertEqual(nowPlayings(started).map(\.trackID), ["t1"])

        let firstHalf = play(&coordinator, from: 0, to: 99, clock: &clock)
        XCTAssertTrue(scrobbles(firstHalf).isEmpty)
        XCTAssertEqual(coordinator.playedSeconds, 99, accuracy: 1e-6)

        clock = clock.addingTimeInterval(1)
        let rest = play(&coordinator, from: 100, to: 200, clock: &clock)
        let listens = scrobbles(rest)
        XCTAssertEqual(listens.count, 1, "exactly one scrobble per play")
        XCTAssertEqual(listens[0].startedAt, epoch, "timestamp is the start of the play")
        XCTAssertEqual(listens[0].title, "Song t1")
        XCTAssertEqual(listens[0].album, "Album")
        XCTAssertEqual(listens[0].trackNumber, 2)
        XCTAssertEqual(listens[0].duration, 200)
        XCTAssertTrue(coordinator.hasScrobbledCurrentPlay)
    }

    func testLongTrackScrobblesAfterFourMinutes() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(duration: 3600), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertTrue(scrobbles(play(&coordinator, from: 0, to: 239, clock: &clock)).isEmpty)
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(scrobbles(coordinator.progress(position: 240, at: clock)).count, 1)
    }

    func testShortTrackNeverScrobbles() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(duration: 30), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertTrue(scrobbles(play(&coordinator, from: 0, to: 30, clock: &clock)).isEmpty)
    }

    func testSeekingForwardDoesNotCheat() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = play(&coordinator, from: 0, to: 10, clock: &clock)
        // Jump from 0:10 to 3:10 within one second.
        clock = clock.addingTimeInterval(1)
        let afterSeek = play(&coordinator, from: 190, to: 200, clock: &clock)
        XCTAssertTrue(scrobbles(afterSeek).isEmpty, "position is past 50% but only ~21 s were heard")
        XCTAssertEqual(coordinator.playedSeconds, 21, accuracy: 1e-6)
    }

    func testSeekingBackKeepsAccumulatedTime() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = play(&coordinator, from: 0, to: 60, clock: &clock)
        clock = clock.addingTimeInterval(1)
        // Back to 0:20, then listen on: 60 s + 40 s reaches the threshold at 1:00.
        let replayed = play(&coordinator, from: 20, to: 60, clock: &clock)
        XCTAssertEqual(scrobbles(replayed).count, 1)
        XCTAssertEqual(scrobbles(replayed)[0].startedAt, epoch, "a seek back mid-track is still the same play")
    }

    func testPausedTimeDoesNotCount() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = play(&coordinator, from: 0, to: 50, clock: &clock)
        _ = coordinator.playbackStateChanged(isPlaying: false, at: clock)
        // Ten minutes pass; stray samples while paused must not add time.
        clock = clock.addingTimeInterval(600)
        XCTAssertTrue(coordinator.progress(position: 50, at: clock).isEmpty)
        XCTAssertTrue(coordinator.progress(position: 50.4, at: clock.addingTimeInterval(1)).isEmpty)
        clock = clock.addingTimeInterval(2)
        let resumed = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertEqual(nowPlayings(resumed).count, 1, "now-playing is refreshed after a long pause")
        let rest = play(&coordinator, from: 50, to: 99, clock: &clock)
        XCTAssertTrue(scrobbles(rest).isEmpty)
        XCTAssertEqual(coordinator.playedSeconds, 99, accuracy: 1e-6)
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(scrobbles(coordinator.progress(position: 100, at: clock)).count, 1)
    }

    func testBufferingFlapsDoNotRepeatNowPlaying() {
        var coordinator = ScrobbleCoordinator()
        let clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        XCTAssertEqual(coordinator.playbackStateChanged(isPlaying: true, at: clock).count, 1)
        _ = coordinator.playbackStateChanged(isPlaying: false, at: clock.addingTimeInterval(2))
        XCTAssertTrue(coordinator.playbackStateChanged(isPlaying: true, at: clock.addingTimeInterval(3)).isEmpty)
    }

    func testStalledPositionDoesNotCount() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        // "Playing" for five minutes, but the position never moves (stalled stream).
        for _ in 0..<300 {
            clock = clock.addingTimeInterval(1)
            XCTAssertTrue(coordinator.progress(position: 5, at: clock).isEmpty)
        }
        XCTAssertEqual(coordinator.playedSeconds, 0)
    }

    func testSkippingEarlyDoesNotScrobbleAndNextTrackStartsFresh() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track("a"), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertTrue(scrobbles(play(&coordinator, from: 0, to: 40, clock: &clock)).isEmpty)

        clock = clock.addingTimeInterval(1)
        let switched = coordinator.trackChanged(to: track("b"), at: clock)
        XCTAssertEqual(nowPlayings(switched).map(\.trackID), ["b"])
        XCTAssertEqual(coordinator.playedSeconds, 0)
        let startOfB = clock

        // The player may still report the old track's position for one tick.
        XCTAssertTrue(coordinator.progress(position: 41, at: clock).isEmpty)
        clock = clock.addingTimeInterval(1)
        let actions = play(&coordinator, from: 0, to: 100, clock: &clock)
        XCTAssertTrue(nowPlayings(actions).isEmpty, "the stale position is not mistaken for a replay")
        let listens = scrobbles(actions)
        XCTAssertEqual(listens.map(\.trackID), ["b"])
        XCTAssertEqual(listens[0].startedAt, startOfB)
    }

    func testStalePositionNearEndOfPreviousTrackIsNotAReplay() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = coordinator.trackChanged(to: track("b", duration: 180), at: clock)
        // Stale sample from the previous (longer) track, right at its end.
        _ = coordinator.progress(position: 199.9, at: clock)
        clock = clock.addingTimeInterval(1)
        let actions = play(&coordinator, from: 0, to: 10, clock: &clock)
        XCTAssertTrue(actions.isEmpty)
    }

    func testRepeatOneCountsEveryFullPlay() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertEqual(scrobbles(play(&coordinator, from: 0, to: 199, clock: &clock)).count, 1)

        // The same track wraps around: position jumps from the end to 0.
        clock = clock.addingTimeInterval(1)
        let secondStart = clock
        let second = play(&coordinator, from: 0, to: 199, clock: &clock)
        XCTAssertEqual(nowPlayings(second).count, 1, "the replay is announced again")
        let listens = scrobbles(second)
        XCTAssertEqual(listens.count, 1, "the replay earns its own scrobble")
        XCTAssertEqual(listens[0].startedAt, secondStart)

        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(scrobbles(play(&coordinator, from: 0, to: 120, clock: &clock)).count, 1)
    }

    func testSeekToStartBeforeScrobbleIsNotANewPlay() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = play(&coordinator, from: 0, to: 60, clock: &clock)
        clock = clock.addingTimeInterval(1)
        let again = play(&coordinator, from: 0, to: 40, clock: &clock)
        XCTAssertTrue(nowPlayings(again).isEmpty)
        let listens = scrobbles(again)
        XCTAssertEqual(listens.count, 1)
        XCTAssertEqual(listens[0].startedAt, epoch)
    }

    func testStoppingClearsThePlay() {
        var coordinator = ScrobbleCoordinator()
        var clock = epoch
        _ = coordinator.trackChanged(to: track(), at: clock)
        _ = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        _ = play(&coordinator, from: 0, to: 80, clock: &clock)
        XCTAssertTrue(coordinator.trackChanged(to: nil, at: clock).isEmpty)
        XCTAssertTrue(coordinator.progress(position: 150, at: clock.addingTimeInterval(100)).isEmpty)
        XCTAssertEqual(coordinator.playedSeconds, 0)
    }

    func testTrackSetWhilePausedGetsItsTimestampWhenPlaybackStarts() {
        var coordinator = ScrobbleCoordinator()
        _ = coordinator.trackChanged(to: track(), at: epoch)
        var clock = epoch.addingTimeInterval(500)
        let started = coordinator.playbackStateChanged(isPlaying: true, at: clock)
        XCTAssertEqual(nowPlayings(started).first?.startedAt, clock)
        let begin = clock
        let listens = scrobbles(play(&coordinator, from: 0, to: 100, clock: &clock))
        XCTAssertEqual(listens.first?.startedAt, begin)
    }
}

// MARK: - Queue

final class ScrobbleQueueTests: XCTestCase {
    func testEnqueueDeduplicatesPerService() {
        var queue = ScrobbleQueue()
        XCTAssertTrue(queue.enqueue(makeListen(1), for: .lastFM, now: epoch))
        XCTAssertFalse(queue.enqueue(makeListen(1), for: .lastFM, now: epoch), "same play, same service")
        XCTAssertTrue(queue.enqueue(makeListen(1), for: .listenBrainz, now: epoch), "other service has its own entry")
        XCTAssertTrue(queue.enqueue(makeListen(1, startedAt: epoch.addingTimeInterval(300)), for: .lastFM, now: epoch), "a later play of the same track")
        XCTAssertEqual(queue.count(for: .lastFM), 2)
        XCTAssertEqual(queue.count(for: .listenBrainz), 1)
    }

    func testBatchesAreOldestFirstAndLimited() {
        var queue = ScrobbleQueue()
        for index in [5, 1, 4, 2, 3] {
            queue.enqueue(makeListen(index), for: .lastFM, now: epoch)
        }
        queue.enqueue(makeListen(0), for: .listenBrainz, now: epoch)
        XCTAssertEqual(queue.nextBatch(for: .lastFM, limit: 3).map(\.listen.trackID), ["t1", "t2", "t3"])
        XCTAssertEqual(queue.nextBatch(for: .lastFM, limit: 50).count, 5)
    }

    func testCapDropsOldest() {
        var queue = ScrobbleQueue(policy: ScrobbleQueuePolicy(maxEntries: 3))
        for index in 1...5 {
            queue.enqueue(makeListen(index), for: .lastFM, now: epoch)
        }
        XCTAssertEqual(queue.entries.map(\.listen.trackID), ["t3", "t4", "t5"])
    }

    func testPruneDropsExpiredAndOverRetried() {
        var queue = ScrobbleQueue(policy: ScrobbleQueuePolicy(maxAge: 1000, maxAttempts: 2))
        queue.enqueue(makeListen(1, startedAt: epoch), for: .lastFM, now: epoch)
        queue.enqueue(makeListen(2, startedAt: epoch.addingTimeInterval(900)), for: .lastFM, now: epoch)
        queue.enqueue(makeListen(3, startedAt: epoch.addingTimeInterval(950)), for: .lastFM, now: epoch)
        let retried = Set(queue.entries.filter { $0.listen.trackID == "t3" }.map(\.id))
        queue.recordFailedAttempt(ids: retried)
        queue.recordFailedAttempt(ids: retried)
        XCTAssertEqual(queue.prune(now: epoch.addingTimeInterval(1001)), 2)
        XCTAssertEqual(queue.entries.map(\.listen.trackID), ["t2"])
    }

    func testEntriesSurviveACodableRoundTrip() throws {
        var queue = ScrobbleQueue()
        queue.enqueue(makeListen(1), for: .lastFM, now: epoch)
        queue.enqueue(makeListen(2), for: .listenBrainz, now: epoch)
        let data = try JSONEncoder().encode(queue.entries)
        let decoded = try JSONDecoder().decode([PendingScrobble].self, from: data)
        XCTAssertEqual(decoded, queue.entries)
    }
}

// MARK: - Engine

final class ScrobbleEngineTests: XCTestCase {
    func testScrobbleIsDeliveredToEveryTargetAndLeavesTheQueue() async {
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, now: { epoch.addingTimeInterval(60) })
        let lastFM = FakeTarget(service: .lastFM)
        let listenBrainz = FakeTarget(service: .listenBrainz)
        _ = await engine.configure(targets: [lastFM, listenBrainz])

        let status = await engine.perform([.nowPlaying(makeListen(1)), .scrobble(makeListen(1))])
        XCTAssertEqual(status.totalPending, 0)
        let lastFMNowPlaying = await lastFM.nowPlaying
        let lastFMSubmitted = await lastFM.submitted
        let listenBrainzSubmitted = await listenBrainz.submitted
        XCTAssertEqual(lastFMNowPlaying.count, 1)
        XCTAssertEqual(lastFMSubmitted, [[makeListen(1)]])
        XCTAssertEqual(listenBrainzSubmitted, [[makeListen(1)]])
        XCTAssertTrue(store.loadPendingScrobbles().isEmpty)
    }

    func testOfflineListensAreQueuedPersistedAndFlushedOldestFirstInBatches() async {
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, now: { epoch.addingTimeInterval(60) })
        let target = FakeTarget(service: .lastFM, maxBatchSize: 2)
        _ = await engine.configure(targets: [target])

        await target.fail(with: [.offline, .offline, .offline])
        for index in [3, 1, 2] {
            let status = await engine.perform([.scrobble(makeListen(index))])
            XCTAssertNotNil(status.lastError[.lastFM])
        }
        XCTAssertEqual(store.loadPendingScrobbles().count, 3, "queued listens are on disk")
        XCTAssertEqual(store.loadPendingScrobbles().map(\.attempts), [0, 0, 0], "being offline does not use up attempts")

        let status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        XCTAssertNil(status.lastError[.lastFM])
        let submitted = await target.submitted
        XCTAssertEqual(submitted.map { $0.map(\.trackID) }, [["t1", "t2"], ["t3"]])
        XCTAssertTrue(store.loadPendingScrobbles().isEmpty)
    }

    func testQueueSurvivesRelaunch() async {
        let store = InMemoryScrobbleQueueStore()
        let first = ScrobbleEngine(store: store, now: { epoch.addingTimeInterval(60) })
        let offlineTarget = FakeTarget(service: .listenBrainz)
        await offlineTarget.fail(with: [.offline])
        _ = await first.configure(targets: [offlineTarget])
        _ = await first.perform([.scrobble(makeListen(1))])

        // A new engine (next launch) picks the listen up from the store.
        let second = ScrobbleEngine(store: store, now: { epoch.addingTimeInterval(60) })
        let target = FakeTarget(service: .listenBrainz)
        let configured = await second.configure(targets: [target])
        XCTAssertEqual(configured.pending[.listenBrainz], 1)
        let status = await second.flush()
        XCTAssertEqual(status.totalPending, 0)
        let submitted = await target.submitted
        XCTAssertEqual(submitted, [[makeListen(1)]])
    }

    func testRetryLaterBacksOffAndCountsAttempts() async {
        let clock = Clock(epoch.addingTimeInterval(10))
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, now: { clock.now })
        let target = FakeTarget(service: .lastFM)
        _ = await engine.configure(targets: [target])

        await target.fail(with: [.retryLater(after: 120, message: "Rate Limit Exceeded")])
        var status = await engine.perform([.scrobble(makeListen(1))])
        XCTAssertEqual(status.pending[.lastFM], 1)
        XCTAssertEqual(status.lastError[.lastFM], "Rate Limit Exceeded")
        XCTAssertEqual(store.loadPendingScrobbles().first?.attempts, 1)

        // Still inside the backoff window: the service is left alone.
        clock.advance(60)
        status = await engine.flush()
        XCTAssertEqual(status.pending[.lastFM], 1)
        var submitted = await target.submitted
        XCTAssertTrue(submitted.isEmpty)

        clock.advance(61)
        status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        submitted = await target.submitted
        XCTAssertEqual(submitted.count, 1)
    }

    func testExplicitFlushIgnoresBackoff() async {
        let clock = Clock(epoch.addingTimeInterval(10))
        let engine = ScrobbleEngine(store: InMemoryScrobbleQueueStore(), now: { clock.now })
        let target = FakeTarget(service: .lastFM)
        _ = await engine.configure(targets: [target])
        await target.fail(with: [.retryLater(after: 3600, message: "later")])
        _ = await engine.perform([.scrobble(makeListen(1))])
        let status = await engine.flush(ignoringBackoff: true)
        XCTAssertEqual(status.totalPending, 0)
    }

    func testListensAreDroppedAfterTooManyAttempts() async {
        let clock = Clock(epoch.addingTimeInterval(10))
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, policy: ScrobbleQueuePolicy(maxAttempts: 2), now: { clock.now })
        let target = FakeTarget(service: .lastFM)
        _ = await engine.configure(targets: [target])
        await target.fail(with: [.retryLater(after: 1, message: "x"), .retryLater(after: 1, message: "x")])
        _ = await engine.perform([.scrobble(makeListen(1))])
        clock.advance(5)
        _ = await engine.flush()
        clock.advance(5)
        let status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        let submitted = await target.submitted
        XCTAssertTrue(submitted.isEmpty, "given up, not delivered")
    }

    func testExpiredListensAreDropped() async {
        let clock = Clock(epoch)
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, now: { clock.now })
        let target = FakeTarget(service: .lastFM)
        _ = await engine.configure(targets: [target])
        await target.fail(with: [.offline])
        _ = await engine.perform([.scrobble(makeListen(1))])
        clock.advance(15 * 24 * 3600)
        let status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        let submitted = await target.submitted
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(store.loadPendingScrobbles().isEmpty)
    }

    func testRejectedBatchIsDroppedAndTheRestStillGoesOut() async {
        let engine = ScrobbleEngine(store: InMemoryScrobbleQueueStore(), now: { epoch.addingTimeInterval(60) })
        let target = FakeTarget(service: .lastFM, maxBatchSize: 1)
        _ = await engine.configure(targets: [target])
        await target.fail(with: [.offline, .offline])
        _ = await engine.perform([.scrobble(makeListen(1))])
        _ = await engine.perform([.scrobble(makeListen(2))])

        await target.fail(with: [.rejected(message: "Invalid parameters")])
        let status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        let submitted = await target.submitted
        XCTAssertEqual(submitted.map { $0.map(\.trackID) }, [["t2"]])
    }

    func testInvalidSessionStopsDeliveryButKeepsQueueingUntilReconnected() async {
        let engine = ScrobbleEngine(store: InMemoryScrobbleQueueStore(), now: { epoch.addingTimeInterval(60) })
        let stale = FakeTarget(service: .lastFM)
        let listenBrainz = FakeTarget(service: .listenBrainz)
        _ = await engine.configure(targets: [stale, listenBrainz])
        await stale.fail(with: [.reauthenticate(message: "Invalid session key")])

        var status = await engine.perform([.scrobble(makeListen(1))])
        XCTAssertEqual(status.needsReauthentication, [.lastFM])
        XCTAssertEqual(status.pending, [.lastFM: 1], "the other service is unaffected")

        // The app drops the session: Last.fm stays switched on, queue only.
        status = await engine.configure(targets: [listenBrainz], queueOnly: [.lastFM])
        status = await engine.perform([.scrobble(makeListen(2))])
        XCTAssertEqual(status.pending[.lastFM], 2)
        XCTAssertNil(status.pending[.listenBrainz])

        // Reconnected: a fresh target clears the flag and receives the backlog.
        let fresh = FakeTarget(service: .lastFM)
        status = await engine.configure(targets: [fresh, listenBrainz])
        XCTAssertTrue(status.needsReauthentication.isEmpty)
        status = await engine.flush()
        XCTAssertEqual(status.totalPending, 0)
        let submitted = await fresh.submitted
        XCTAssertEqual(submitted.map { $0.map(\.trackID) }, [["t1", "t2"]])
    }

    func testNothingIsQueuedForServicesThatAreOff() async {
        let store = InMemoryScrobbleQueueStore()
        let engine = ScrobbleEngine(store: store, now: { epoch.addingTimeInterval(60) })
        _ = await engine.configure(targets: [])
        let status = await engine.perform([.nowPlaying(makeListen(1)), .scrobble(makeListen(1))])
        XCTAssertEqual(status, ScrobbleStatus())
        XCTAssertTrue(store.loadPendingScrobbles().isEmpty)
    }

    func testDiscardPendingForgetsOneService() async {
        let engine = ScrobbleEngine(store: InMemoryScrobbleQueueStore(), now: { epoch.addingTimeInterval(60) })
        let lastFM = FakeTarget(service: .lastFM)
        let listenBrainz = FakeTarget(service: .listenBrainz)
        await lastFM.fail(with: [.offline])
        await listenBrainz.fail(with: [.offline])
        _ = await engine.configure(targets: [lastFM, listenBrainz])
        _ = await engine.perform([.scrobble(makeListen(1))])
        let status = await engine.discardPending(for: .lastFM)
        XCTAssertEqual(status.pending, [.listenBrainz: 1])
        XCTAssertNil(status.lastError[.lastFM])
    }

    func testCoordinatorToEngineEndToEnd() async {
        let engine = ScrobbleEngine(store: InMemoryScrobbleQueueStore(), now: { epoch.addingTimeInterval(60) })
        let target = FakeTarget(service: .listenBrainz)
        _ = await engine.configure(targets: [target])
        var coordinator = ScrobbleCoordinator()
        let track = Track(id: "t", title: "Song", artistName: "Artist", albumName: "Album", duration: 100)

        var clock = epoch
        _ = await engine.perform(coordinator.trackChanged(to: track, at: clock))
        _ = await engine.perform(coordinator.playbackStateChanged(isPlaying: true, at: clock))
        for second in 0...60 {
            _ = await engine.perform(coordinator.progress(position: TimeInterval(second), at: clock))
            clock = clock.addingTimeInterval(1)
        }
        let nowPlaying = await target.nowPlaying
        let submitted = await target.submitted
        XCTAssertEqual(nowPlaying.count, 1)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.first?.startedAt, epoch)
    }
}
