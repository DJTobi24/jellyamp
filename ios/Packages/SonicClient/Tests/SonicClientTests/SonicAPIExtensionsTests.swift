import XCTest
@testable import SonicClient
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// API 1.1 (docs/SONIC-API.md): scan status and analysis info in `/info`,
/// `POST /scan`, Sonic Sage, and the additive-compatibility rules.
final class SonicAPIExtensionsTests: XCTestCase {
    private var transport: StubTransport!
    private var client: SonicAPIClient!
    private let baseURL = URL(string: "http://sonic.local:8095")!

    override func setUp() {
        super.setUp()
        transport = StubTransport()
        client = SonicAPIClient(baseURL: baseURL, apiKey: "secret", transport: transport)
    }

    private func stub(_ match: String, status: Int = 200, json: String) {
        transport.responses.append((match, status, Data(json.utf8)))
    }

    private func assertThrows<T>(
        _ expected: SonicError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SonicError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - /info

    func testInfoDecodesAnalysisBackendAndScanStatus() async throws {
        transport.stub(pathContains: "info", fixture: "info")
        let capabilities = await client.capabilities

        XCTAssertTrue(capabilities.supports(.sage))
        XCTAssertEqual(capabilities.analysisBackend, SonicAnalysisBackend(name: "dsp", version: "1"))
        let scan = try XCTUnwrap(capabilities.scan)
        XCTAssertEqual(scan.state, .scanning)
        XCTAssertTrue(scan.isScanning)
        XCTAssertEqual(scan.tracksPending, 463)
        XCTAssertEqual(scan.tracksFailed, 3)
        XCTAssertNil(scan.finishedAt)
        XCTAssertNil(scan.lastError)
        // 2026-06-10T08:00:10Z
        XCTAssertEqual(try XCTUnwrap(scan.startedAt).timeIntervalSince1970, 1_781_078_410, accuracy: 0.5)
    }

    func testInfoFromVersion1_0ServerStillDecodes() async throws {
        transport.stub(pathContains: "info", fixture: "info_v1_0")
        let capabilities = await client.capabilities

        XCTAssertEqual(capabilities.capabilities, [.similar, .adventure, .mixes, .stations, .loudness])
        XCTAssertNil(capabilities.scan)
        XCTAssertNil(capabilities.analysisBackend)
        XCTAssertEqual(capabilities.analysisProgress?.tracksAnalyzed, 12034)
    }

    func testUnknownCapabilitiesFieldsAndScanStatesFromNewerServersAreIgnored() async throws {
        stub("info", json: """
        {
          "version": "1.7", "jellyfinServerId": "abc", "tracksTotal": 10, "tracksAnalyzed": 4,
          "capabilities": ["similar", "telepathy"],
          "analysis": {"backend": "clap", "version": "3", "device": "gpu"},
          "scan": {"state": "paused", "tracksPending": 6, "queue": [1, 2]},
          "somethingNew": {"nested": true}
        }
        """)
        let info = try await client.serverInfo()

        XCTAssertEqual(info.version, "1.7")
        XCTAssertEqual(info.jellyfinServerID, "abc")
        XCTAssertEqual(info.capabilities.capabilities, [.similar])
        XCTAssertEqual(info.capabilities.analysisBackend?.name, "clap")
        XCTAssertEqual(info.capabilities.scan?.state, .idle)
        XCTAssertEqual(info.capabilities.scan?.tracksPending, 6)
        XCTAssertEqual(info.capabilities.scan?.tracksFailed, 0)
    }

    func testServerInfoThrowsWhenUnreachableWhileCapabilitiesDegrade() async {
        let capabilities = await client.capabilities
        XCTAssertEqual(capabilities, SonicCapabilities(capabilities: []))
        await assertThrows(.invalidResponse) { try await self.client.serverInfo() }
    }

    func testAnalysisProgressFraction() {
        typealias Progress = SonicCapabilities.AnalysisProgress
        XCTAssertEqual(Progress(tracksAnalyzed: 0, tracksTotal: 0).fraction, 0)
        XCTAssertFalse(Progress(tracksAnalyzed: 0, tracksTotal: 0).isComplete)
        XCTAssertEqual(Progress(tracksAnalyzed: 25, tracksTotal: 100).fraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(Progress(tracksAnalyzed: 120, tracksTotal: 100).fraction, 1)
        XCTAssertTrue(Progress(tracksAnalyzed: 100, tracksTotal: 100).isComplete)
    }

    func testCapabilitiesInitIsSourceCompatible() {
        // The app shell builds these with the two original labels.
        let legacy = SonicCapabilities(capabilities: [.similar], analysisProgress: .init(tracksAnalyzed: 1, tracksTotal: 2))
        XCTAssertNil(legacy.scan)
        XCTAssertNil(legacy.analysisBackend)
        XCTAssertTrue(SonicCapabilities(capabilities: [.sage]).supports(.sage))
    }

    // MARK: - Discovery

    func testDiscoveryAcceptsNewerMinorVersionAndCarriesScanStatus() async {
        transport.stub(pathContains: "info", fixture: "info")
        let outcome = await SonicServerDiscovery(transport: transport).probe(baseURL: baseURL, apiKey: "secret")
        guard case .available(let capabilities) = outcome else {
            return XCTFail("expected available, got \(outcome)")
        }
        XCTAssertEqual(capabilities.scan?.state, .scanning)
        XCTAssertEqual(capabilities.analysisProgress?.tracksTotal, 12500)
    }

    func testDiscoveryRejectsAnotherMajorVersion() async {
        stub("info", json: """
        {"version": "2.0", "jellyfinServerId": "x", "tracksTotal": 1, "tracksAnalyzed": 1, "capabilities": []}
        """)
        let outcome = await SonicServerDiscovery(transport: transport).probe(baseURL: baseURL, apiKey: "secret")
        XCTAssertEqual(outcome, .incompatibleVersion("2.0"))
    }

    func testProbeDetailsReturnsPairedJellyfinServer() async {
        transport.stub(pathContains: "info", fixture: "info")
        let result = await SonicServerDiscovery(transport: transport).probeDetails(baseURL: baseURL, apiKey: "secret")
        XCTAssertEqual(result.info?.jellyfinServerID, "f0c3a1b2c3d4e5f60718293a4b5c6d7e")
        XCTAssertEqual(result.info?.version, "1.1")
        guard case .available = result.outcome else {
            return XCTFail("expected available, got \(result.outcome)")
        }

        let failing = StubTransport()
        failing.stub(pathContains: "info", status: 401)
        let denied = await SonicServerDiscovery(transport: failing).probeDetails(baseURL: baseURL, apiKey: "wrong")
        XCTAssertEqual(denied.outcome, .unauthorized)
        XCTAssertNil(denied.info)
    }

    // MARK: - Sonic Sage

    func testSagePostsPromptAndDecodesPlaylist() async throws {
        transport.stub(pathContains: "sage", fixture: "sage")
        let playlist = try await client.sagePlaylist(prompt: "hazy guitars for a rainy sunday", count: 30)

        XCTAssertEqual(playlist.title, "Rainy Sunday Shoegaze")
        XCTAssertEqual(playlist.description, "Hazy guitars from the early nineties for a slow afternoon.")
        XCTAssertEqual(playlist.itemIDs.count, 3)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/sage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)
        let body = try JSONDecoder().decode(SageRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.prompt, "hazy guitars for a rainy sunday")
        XCTAssertEqual(body.count, 30)
    }

    func testSageDisabledSurfacesServerExplanation() async {
        stub("sage", status: 409, json: #"{"detail": "Sonic Sage is disabled (no ANTHROPIC_API_KEY configured)"}"#)
        await assertThrows(.unavailable("Sonic Sage is disabled (no ANTHROPIC_API_KEY configured)")) {
            try await self.client.sagePlaylist(prompt: "x", count: 5)
        }
    }

    func testSageUpstreamFailureAndNoMatch() async {
        stub("sage", status: 502, json: #"{"detail": "the language model is rate limited; try again later"}"#)
        await assertThrows(.upstreamFailure("the language model is rate limited; try again later")) {
            try await self.client.sagePlaylist(prompt: "x", count: 5)
        }

        transport.responses.removeAll()
        stub("sage", status: 404, json: #"{"detail": "no analyzed tracks match this request"}"#)
        await assertThrows(.notFound("sage")) {
            try await self.client.sagePlaylist(prompt: "polka", count: 5)
        }
    }

    func testValidationErrorsAreJoined() async {
        stub("sage", status: 422, json: """
        {"detail": [
          {"type": "less_than_equal", "loc": ["body", "count"], "msg": "Input should be less than or equal to 200"},
          {"type": "string_too_short", "loc": ["body", "prompt"], "msg": "String should have at least 1 character"}
        ]}
        """)
        await assertThrows(.invalidRequest("Input should be less than or equal to 200; String should have at least 1 character")) {
            try await self.client.sagePlaylist(prompt: "", count: 999)
        }
    }

    func testErrorWithoutParseableBodyStillMapsByStatus() async {
        stub("scan", status: 409, json: "<html>proxy error</html>")
        await assertThrows(.unavailable("")) { try await self.client.startScan(retryFailed: false) }

        transport.responses.removeAll()
        stub("scan", status: 500, json: "")
        await assertThrows(.serverError(status: 500)) { try await self.client.startScan(retryFailed: false) }
    }

    // MARK: - Scan

    func testStartScanPostsAndDecodesStatus() async throws {
        transport.stub(pathContains: "scan", fixture: "scan")
        let status = try await client.startScan(retryFailed: false)

        XCTAssertEqual(status.state, .scanning)
        XCTAssertEqual(status.tracksFailed, 3)
        XCTAssertEqual(status.lastError, "Jellyfin unreachable: connection refused")
        XCTAssertNotNil(status.startedAt)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/scan")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "secret")
    }

    func testStartScanCanRetryFailedTracks() async throws {
        transport.stub(pathContains: "scan", fixture: "scan")
        _ = try await client.startScan(retryFailed: true)
        XCTAssertEqual(transport.requests.first?.url?.query, "retryFailed=true")
    }

    // MARK: - Similar tracks

    func testSimilarTracksCanExcludeTheSeedsAlbum() async throws {
        transport.stub(pathContains: "similar/tracks", fixture: "similar_tracks")
        _ = try await client.similarTracks(to: "seed", limit: 7, excludingSameAlbum: true)
        _ = try await client.similarTracks(to: "seed", limit: 7, excludingSameAlbum: false)

        let queries = transport.requests.map { $0.url?.query ?? "" }
        XCTAssertTrue(queries[0].contains("limit=7"))
        XCTAssertTrue(queries[0].contains("excludeSameAlbum=true"))
        XCTAssertFalse(queries[1].contains("excludeSameAlbum"))
    }
}

/// Conformers written against the 1.0 protocol keep compiling and get
/// sensible defaults for the 1.1 requirements.
final class SonicProvidingDefaultsTests: XCTestCase {
    struct Source: JellyfinSmartSource {
        func instantMix(seedID: String, limit: Int) async throws -> [String] { [seedID, "m1", "m2"] }
        func similarItems(to itemID: String, limit: Int) async throws -> [String] { [] }
        func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String] { [] }
    }

    private let provider: SonicProviding = JellyfinFallbackSonicProvider(source: Source())

    func testFallbackHasNoSage() async {
        let capabilities = await provider.capabilities
        XCTAssertFalse(capabilities.supports(.sage))
        XCTAssertNil(capabilities.scan)
        do {
            _ = try await provider.sagePlaylist(prompt: "anything", count: 10)
            XCTFail("expected unsupported")
        } catch let error as SonicError {
            XCTAssertEqual(error, .unsupported(.sage))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFallbackHasNoScan() async {
        do {
            _ = try await provider.startScan(retryFailed: false)
            XCTFail("expected unavailable")
        } catch let error as SonicError {
            guard case .unavailable = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAlbumExclusionFallsBackToPlainSimilarity() async throws {
        let items = try await provider.similarTracks(to: "seed", limit: 2, excludingSameAlbum: true)
        XCTAssertEqual(items.map(\.itemID), ["m1", "m2"])
    }
}
