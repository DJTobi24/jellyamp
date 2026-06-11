import XCTest
@testable import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SmartSyncPlannerTests: XCTestCase {
    private func mix(_ id: String, items: [String]) -> MixDescriptor {
        MixDescriptor(id: id, title: id, itemIDs: items)
    }

    func testFavoritesAreDownloadedWhenEnabled() {
        let planner = SmartSyncPlanner(rules: SmartSyncRules(autoDownloadFavorites: true))
        let plan = planner.plan(favoriteIDs: ["f1", "f2"], mixes: [], downloadedIDs: ["f1"], pinnedIDs: [])
        XCTAssertEqual(plan.download, ["f2"])
        XCTAssertTrue(plan.evict.isEmpty)
    }

    func testOnlyLatestNMixesAreKept() {
        let planner = SmartSyncPlanner(rules: SmartSyncRules(keepLatestMixes: 1))
        let plan = planner.plan(
            favoriteIDs: [],
            mixes: [mix("new", items: ["a", "b"]), mix("old", items: ["c"])],
            downloadedIDs: ["c"],
            pinnedIDs: []
        )
        XCTAssertEqual(plan.download, ["a", "b"])
        XCTAssertEqual(plan.evict, ["c"], "tracks of older mixes are released")
    }

    func testPinnedDownloadsAreNeverEvicted() {
        let planner = SmartSyncPlanner(rules: SmartSyncRules())
        let plan = planner.plan(favoriteIDs: [], mixes: [], downloadedIDs: ["manual"], pinnedIDs: ["manual"])
        XCTAssertTrue(plan.evict.isEmpty)
        XCTAssertTrue(plan.download.isEmpty)
    }

    func testOverlappingRulesDeduplicate() {
        let planner = SmartSyncPlanner(rules: SmartSyncRules(autoDownloadFavorites: true, keepLatestMixes: 1))
        let plan = planner.plan(
            favoriteIDs: ["x"],
            mixes: [mix("m", items: ["x", "y"])],
            downloadedIDs: [],
            pinnedIDs: []
        )
        XCTAssertEqual(plan.download, ["x", "y"])
    }
}

final class SleepTimerTests: XCTestCase {
    func testCountdownAndStop() {
        var timer = SleepTimer(fadeOutDuration: 10)
        timer.start(duration: 60, now: 0)
        XCTAssertEqual(timer.remaining(now: 20) ?? -1, 40, accuracy: 1e-9)
        XCTAssertFalse(timer.shouldStop(now: 59))
        XCTAssertTrue(timer.shouldStop(now: 60))
    }

    func testFadeGainRampsInsideWindow() {
        var timer = SleepTimer(fadeOutDuration: 10)
        timer.start(duration: 60, now: 0)
        XCTAssertEqual(timer.fadeGain(now: 30), 1.0, accuracy: 1e-9)
        XCTAssertEqual(timer.fadeGain(now: 55), 0.5, accuracy: 1e-9)
        XCTAssertEqual(timer.fadeGain(now: 60), 0.0, accuracy: 1e-9)
    }

    func testExtendFromEndOfTrackSwitchesToDuration() {
        var timer = SleepTimer()
        timer.startEndOfTrack()
        timer.extend(by: 300, now: 100)
        XCTAssertEqual(timer.remaining(now: 100) ?? -1, 300, accuracy: 1e-9)
    }

    func testCancelDeactivates() {
        var timer = SleepTimer()
        timer.start(duration: 10, now: 0)
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remaining(now: 5))
        XCTAssertFalse(timer.shouldStop(now: 100))
    }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var body = Data()
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class ListenBrainzClientTests: XCTestCase {
    private let track = Track(id: "t1", title: "Song", artistName: "Artist", albumName: "Album", duration: 200)

    func testListenThresholdRule() {
        XCTAssertFalse(ListenBrainzClient.countsAsListen(playedSeconds: 99, trackDuration: 200))
        XCTAssertTrue(ListenBrainzClient.countsAsListen(playedSeconds: 100, trackDuration: 200))
        // Long tracks: 4 minutes suffice.
        XCTAssertTrue(ListenBrainzClient.countsAsListen(playedSeconds: 240, trackDuration: 3600))
        XCTAssertFalse(ListenBrainzClient.countsAsListen(playedSeconds: 10, trackDuration: 0))
    }

    func testSubmitListenRequestShape() async throws {
        let transport = RecordingTransport()
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submitListen(track: track, listenedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let request = transport.requests.first!
        XCTAssertTrue(request.url!.path.hasSuffix("1/submit-listens"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token tok")
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(json["listen_type"] as? String, "single")
        let listen = (json["payload"] as! [[String: Any]])[0]
        XCTAssertEqual(listen["listened_at"] as? Int, 1_700_000_000)
        let metadata = listen["track_metadata"] as! [String: Any]
        XCTAssertEqual(metadata["artist_name"] as? String, "Artist")
        XCTAssertEqual(metadata["track_name"] as? String, "Song")
        XCTAssertEqual(metadata["release_name"] as? String, "Album")
    }

    func testNowPlayingOmitsTimestamp() async throws {
        let transport = RecordingTransport()
        let client = ListenBrainzClient(token: "tok", transport: transport)
        try await client.submitNowPlaying(track: track)

        let json = try JSONSerialization.jsonObject(with: transport.requests.first!.httpBody!) as! [String: Any]
        XCTAssertEqual(json["listen_type"] as? String, "playing_now")
        let listen = (json["payload"] as! [[String: Any]])[0]
        XCTAssertNil(listen["listened_at"])
    }

    func testServerErrorThrows() async {
        let transport = RecordingTransport()
        transport.status = 503
        let client = ListenBrainzClient(token: "tok", transport: transport)
        do {
            try await client.submitListen(track: track, listenedAt: Date())
            XCTFail("expected error")
        } catch let error as ScrobbleError {
            XCTAssertEqual(error, .serverError(status: 503))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testValidateToken() async throws {
        let transport = RecordingTransport()
        transport.body = Data(#"{"valid": true}"#.utf8)
        let client = ListenBrainzClient(token: "tok", transport: transport)
        let valid = try await client.validateToken()
        XCTAssertTrue(valid)
        XCTAssertTrue(transport.requests.first!.url!.path.hasSuffix("1/validate-token"))
    }
}
