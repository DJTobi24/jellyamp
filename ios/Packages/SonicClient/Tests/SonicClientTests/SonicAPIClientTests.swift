import XCTest
@testable import SonicClient
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Replays canned fixture responses and records requests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(match: String, status: Int, body: Data)] = []
    private(set) var requests: [URLRequest] = []

    func stub(pathContains: String, status: Int = 200, fixture: String? = nil) {
        var body = Data()
        if let fixture {
            let url = Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "json")!
            body = try! Data(contentsOf: url)
        }
        responses.append((pathContains, status, body))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        guard let stubbed = responses.first(where: { path.contains($0.match) }) else {
            throw SonicError.invalidResponse
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stubbed.status, httpVersion: nil, headerFields: nil)!
        return (stubbed.body, response)
    }
}

final class SonicAPIClientTests: XCTestCase {
    private var transport: StubTransport!
    private var client: SonicAPIClient!

    override func setUp() {
        super.setUp()
        transport = StubTransport()
        client = SonicAPIClient(baseURL: URL(string: "http://sonic.local:8095")!, apiKey: "secret", transport: transport)
    }

    func testInfoDecodesCapabilities() async throws {
        transport.stub(pathContains: "info", fixture: "info")
        let capabilities = await client.capabilities
        XCTAssertEqual(capabilities.capabilities, Set(SonicCapability.allCases))
        XCTAssertEqual(capabilities.analysisProgress?.tracksAnalyzed, 12034)
        XCTAssertEqual(capabilities.analysisProgress?.tracksTotal, 12500)
    }

    func testSimilarTracksDecodesAndSendsAPIKey() async throws {
        transport.stub(pathContains: "similar/tracks", fixture: "similar_tracks")
        let items = try await client.similarTracks(to: "seed", limit: 3)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].itemID, "a1b2c3d4e5f60718293a4b5c6d7e8f90")
        XCTAssertEqual(items[0].distance, 0.12, accuracy: 1e-9)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "X-Api-Key"), "secret")
        XCTAssertTrue(transport.requests.first!.url!.query!.contains("limit=3"))
    }

    func testAdventureReturnsPathInPositionOrder() async throws {
        transport.stub(pathContains: "adventure", fixture: "adventure")
        let path = try await client.adventure(from: "x", to: "y", steps: 2)
        XCTAssertEqual(path.count, 4)
        XCTAssertEqual(path.first, "0000000000000000000000000000from")
        XCTAssertEqual(path.last, "00000000000000000000000000000to0")
    }

    func testMixesDecode() async throws {
        transport.stub(pathContains: "mixes", fixture: "mixes")
        let mixes = try await client.mixes(forUser: "user1")
        XCTAssertEqual(mixes.count, 2)
        XCTAssertEqual(mixes[0].id, "mix-2026-w24-1")
        XCTAssertEqual(mixes[0].itemIDs.count, 3)
        XCTAssertEqual(mixes[1].description, "Based on your late-night listening")
    }

    func testStationPostsBodyAndDecodes() async throws {
        transport.stub(pathContains: "stations", fixture: "station")
        let ids = try await client.station(type: .genre, seed: "Shoegaze", count: 3)
        XCTAssertEqual(ids.count, 3)
        let request = transport.requests.first!
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONDecoder().decode(StationRequest.self, from: request.httpBody!)
        XCTAssertEqual(body.type, "genre")
        XCTAssertEqual(body.seed, "Shoegaze")
        XCTAssertEqual(body.count, 3)
    }

    func testLoudnessDecodes() async throws {
        transport.stub(pathContains: "loudness", fixture: "loudness")
        let loudness = try await client.loudness(forTrack: "t1")
        XCTAssertEqual(loudness.integratedLufs, -9.4, accuracy: 1e-9)
        XCTAssertEqual(loudness.truePeak, -0.3, accuracy: 1e-9)
    }

    func testUnauthorizedMapsToError() async throws {
        transport.stub(pathContains: "similar/tracks", status: 401)
        do {
            _ = try await client.similarTracks(to: "seed", limit: 5)
            XCTFail("expected unauthorized")
        } catch let error as SonicError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}

final class SonicServerDiscoveryTests: XCTestCase {
    func testHealthyServerIsAvailable() async {
        let transport = StubTransport()
        transport.stub(pathContains: "info", fixture: "info")
        let outcome = await SonicServerDiscovery(transport: transport).probe(
            baseURL: URL(string: "http://sonic.local:8095")!,
            apiKey: "secret"
        )
        guard case .available(let capabilities) = outcome else {
            return XCTFail("expected available, got \(outcome)")
        }
        XCTAssertTrue(capabilities.supports(.adventure))
    }

    func testUnauthorized() async {
        let transport = StubTransport()
        transport.stub(pathContains: "info", status: 401)
        let outcome = await SonicServerDiscovery(transport: transport).probe(
            baseURL: URL(string: "http://sonic.local:8095")!,
            apiKey: "wrong"
        )
        XCTAssertEqual(outcome, .unauthorized)
    }

    func testUnreachable() async {
        let outcome = await SonicServerDiscovery(transport: StubTransport()).probe(
            baseURL: URL(string: "http://sonic.local:8095")!,
            apiKey: "secret"
        )
        XCTAssertEqual(outcome, .unreachable)
    }
}

final class JellyfinFallbackTests: XCTestCase {
    struct FakeSource: JellyfinSmartSource {
        func instantMix(seedID: String, limit: Int) async throws -> [String] {
            Array(["\(seedID)", "m1", "m2", "m3"].prefix(limit))
        }

        func similarItems(to itemID: String, limit: Int) async throws -> [String] {
            Array(["s1", "s2"].prefix(limit))
        }

        func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String] {
            if let genre { return ["g-\(genre)-1", "g-\(genre)-2"] }
            if let yearRange { return ["y-\(yearRange.lowerBound)-1"] }
            return []
        }
    }

    private let provider = JellyfinFallbackSonicProvider(source: FakeSource())

    func testCapabilitiesExcludeAdventureAndMixes() {
        let capabilities = provider.capabilities
        XCTAssertTrue(capabilities.supports(.similar))
        XCTAssertTrue(capabilities.supports(.stations))
        XCTAssertFalse(capabilities.supports(.adventure))
        XCTAssertFalse(capabilities.supports(.mixes))
    }

    func testSimilarTracksExcludesSeedAndRanks() async throws {
        let items = try await provider.similarTracks(to: "seed", limit: 2)
        XCTAssertEqual(items.map(\.itemID), ["m1", "m2"])
        XCTAssertEqual(items.map(\.distance), [0, 1])
    }

    func testDecadeStationParsesSeed() async throws {
        let ids = try await provider.station(type: .decade, seed: "1990s", count: 10)
        XCTAssertEqual(ids, ["y-1990-1"])
    }

    func testGenreStation() async throws {
        let ids = try await provider.station(type: .genre, seed: "Shoegaze", count: 10)
        XCTAssertEqual(ids, ["g-Shoegaze-1", "g-Shoegaze-2"])
    }

    func testAdventureThrowsUnsupported() async {
        do {
            _ = try await provider.adventure(from: "a", to: "b", steps: 5)
            XCTFail("expected unsupported")
        } catch let error as SonicError {
            XCTAssertEqual(error, .unsupported(.adventure))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
