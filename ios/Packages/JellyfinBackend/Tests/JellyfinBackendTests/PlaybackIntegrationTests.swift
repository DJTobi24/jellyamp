import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let unitSession = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096")!,
    deviceID: "device-1",
    accessToken: "token-abc-123",
    userID: "user-1"
)

final class ProgressiveStreamURLTests: XCTestCase {
    private func query(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testDirectPlayIsTheOriginalFile() {
        let url = StreamURLBuilder.progressiveURL(for: "t1", request: .directPlay, startTime: 30, session: unitSession)
        XCTAssertEqual(url, StreamURLBuilder.url(for: "t1", request: .directPlay, session: unitSession))
    }

    func testTranscodeIsAProgressiveMP3NotHLS() {
        let request = StreamRequest.transcode(codec: "aac", container: "ts", maxBitrate: 192_000)
        let url = StreamURLBuilder.progressiveURL(for: "t1", request: request, playSessionID: "ps", session: unitSession)
        XCTAssertTrue(url.path.hasSuffix("/Audio/t1/stream.mp3"))
        let items = query(of: url)
        XCTAssertEqual(items["audioCodec"], "mp3")
        XCTAssertEqual(items["audioBitRate"], "192000")
        XCTAssertEqual(items["api_key"], "token-abc-123")
        XCTAssertEqual(items["playSessionId"], "ps")
        XCTAssertEqual(items["deviceId"], "device-1")
        XCTAssertNil(items["startTimeTicks"])
    }

    func testTranscodeSeekAndBitrateClamp() {
        let high = StreamURLBuilder.progressiveURL(
            for: "t1", request: .transcode(codec: "aac", container: "ts", maxBitrate: 2_000_000), startTime: 12.5, session: unitSession)
        XCTAssertEqual(query(of: high)["audioBitRate"], "320000")
        XCTAssertEqual(query(of: high)["startTimeTicks"], "125000000")
        let low = StreamURLBuilder.progressiveURL(
            for: "t1", request: .transcode(codec: "aac", container: "ts", maxBitrate: 1), session: unitSession)
        XCTAssertEqual(query(of: low)["audioBitRate"], "64000")
    }
}

final class PlaybackReportingRequestTests: XCTestCase {
    func testPerReportPlayMethodOverridesTheDefault() throws {
        let api = PlaybackReportingAPI(session: unitSession)
        let request = try api.makeRequest(for: .started(trackID: "t1", positionTicks: 0), playSessionID: "ps", playMethod: "Transcode")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["PlayMethod"] as? String, "Transcode")
        XCTAssertEqual(body["PlaySessionId"] as? String, "ps")
        let fallback = try api.makeRequest(for: .started(trackID: "t1", positionTicks: 0), playSessionID: "ps")
        let fallbackBody = try XCTUnwrap(JSONSerialization.jsonObject(with: fallback.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(fallbackBody["PlayMethod"] as? String, "DirectStream")
    }

    func testPauseIsAProgressReportWithIsPaused() throws {
        let api = PlaybackReportingAPI(session: unitSession)
        let request = try api.makeRequest(for: .progress(trackID: "t1", positionTicks: 42, isPaused: true), playSessionID: "ps", playMethod: "DirectPlay")
        XCTAssertTrue(request.url!.path.hasSuffix("/Sessions/Playing/Progress"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["IsPaused"] as? Bool, true)
        XCTAssertEqual(body["PositionTicks"] as? Int, 42)
    }
}

/// Runs against a real Jellyfin server. Opt-in:
///
///     JELLYFIN_TEST_URL=http://localhost:8096 swift test --filter PlaybackIntegrationTests
///
/// (`JELLYFIN_TEST_USER` / `JELLYFIN_TEST_PASSWORD` default to demo/demo, the
/// account `scripts/dev-jellyfin/up.sh` creates.) Skipped when the variable is
/// not set, so CI and offline runs stay green.
final class PlaybackIntegrationTests: XCTestCase {
    private struct ItemDetail: Decodable {
        struct UserDataDto: Decodable {
            var PlayCount: Int?
            var LastPlayedDate: String?
            var Played: Bool?
        }
        var Id: String
        var UserData: UserDataDto?
    }

    private struct SessionInfo: Decodable {
        struct PlayStateDto: Decodable {
            var PositionTicks: Int64?
            var IsPaused: Bool?
            var PlayMethod: String?
        }
        struct NowPlaying: Decodable { var Id: String }
        var DeviceId: String?
        var PlayState: PlayStateDto?
        var NowPlayingItem: NowPlaying?
    }

    private let transport = URLSessionTransport()

    private func liveSession() async throws -> JellyfinSession {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["JELLYFIN_TEST_URL"], let url = URL(string: raw) else {
            throw XCTSkip("JELLYFIN_TEST_URL not set — skipping live Jellyfin test")
        }
        // A device of its own, so the test never touches another client's session.
        let fresh = JellyfinSession(serverURL: url, deviceID: "jellyamp-integration-\(UUID().uuidString)", deviceName: "Integration Test")
        return try await JellyfinAuthenticator().authenticateByName(
            session: fresh,
            username: environment["JELLYFIN_TEST_USER"] ?? "demo",
            password: environment["JELLYFIN_TEST_PASSWORD"] ?? "demo"
        )
    }

    private func userData(of itemID: String, session: JellyfinSession) async throws -> ItemDetail.UserDataDto {
        let request = session.request(path: "Users/\(session.userID ?? "")/Items/\(itemID)")
        let (data, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 200)
        return try XCTUnwrap(JSONDecoder().decode(ItemDetail.self, from: data).UserData)
    }

    private func ownSession(_ session: JellyfinSession) async throws -> SessionInfo? {
        let (data, _) = try await transport.send(session.request(path: "Sessions"))
        return try JSONDecoder().decode([SessionInfo].self, from: data).first { $0.DeviceId == session.deviceID }
    }

    private func send(_ reports: [PlaybackReport], ledger: inout PlaySessionLedger, api: PlaybackReportingAPI) async throws {
        for report in reports {
            try await api.send(report, playSessionID: ledger.sessionID(for: report), playMethod: "DirectPlay")
        }
    }

    /// The exact sequence the engine produces for: play, progress tick, seek,
    /// pause, resume, natural end into the next track, stop.
    func testReportSequenceUpdatesPlayCountSessionAndRecentlyPlayed() async throws {
        let session = try await liveSession()
        let library = MusicLibraryAPI(session: session)
        let albums = try await library.albums(limit: 1)
        let tracks = try await library.tracks(inAlbum: try XCTUnwrap(albums.first).id)
        guard tracks.count >= 2 else { throw XCTSkip("test library needs an album with two tracks") }
        let first = tracks[0], second = tracks[1]

        let api = PlaybackReportingAPI(session: session)
        var reporter = PlaybackReporter(progressInterval: 10)
        var ledger = PlaySessionLedger()

        let before = try await userData(of: first.id, session: session)
        let secondBefore = try await userData(of: second.id, session: session)

        // Start: Jellyfin counts the play and stamps LastPlayedDate here.
        try await send(reporter.trackStarted(id: first.id, at: 0), ledger: &ledger, api: api)
        let started = try await userData(of: first.id, session: session)
        XCTAssertEqual(started.PlayCount ?? 0, (before.PlayCount ?? 0) + 1)
        XCTAssertNotNil(started.LastPlayedDate)
        XCTAssertNotEqual(started.LastPlayedDate, before.LastPlayedDate)

        // Periodic progress, then a seek and a pause: same session, no extra play.
        try await send(reporter.playbackTick(position: 5, isPaused: false, now: 100), ledger: &ledger, api: api)
        try await send(reporter.stateChanged(position: 20, isPaused: false, now: 101), ledger: &ledger, api: api)
        try await send(reporter.stateChanged(position: 21, isPaused: true, now: 102), ledger: &ledger, api: api)
        let paused = try await ownSession(session)
        XCTAssertEqual(paused?.NowPlayingItem?.Id, first.id)
        XCTAssertEqual(paused?.PlayState?.IsPaused, true)
        XCTAssertEqual(paused?.PlayState?.PositionTicks, 210_000_000)
        XCTAssertEqual(paused?.PlayState?.PlayMethod, "DirectPlay")
        let afterSeek = try await userData(of: first.id, session: session)
        XCTAssertEqual(afterSeek.PlayCount, started.PlayCount, "seek/pause must not count as another play")

        // Resume.
        try await send(reporter.stateChanged(position: 21, isPaused: false, now: 103), ledger: &ledger, api: api)
        let resumed = try await ownSession(session)
        XCTAssertEqual(resumed?.PlayState?.IsPaused, false)

        // Natural end → next track: stop(first, final position) + start(second).
        let handover = reporter.trackStarted(id: second.id, at: 0, previousPosition: first.duration)
        XCTAssertEqual(handover.count, 2)
        try await send(handover, ledger: &ledger, api: api)
        let nowSecond = try await ownSession(session)
        XCTAssertEqual(nowSecond?.NowPlayingItem?.Id, second.id)
        let secondStarted = try await userData(of: second.id, session: session)
        XCTAssertEqual(secondStarted.PlayCount ?? 0, (secondBefore.PlayCount ?? 0) + 1)
        let firstFinal = try await userData(of: first.id, session: session)
        XCTAssertEqual(firstFinal.PlayCount, started.PlayCount)
        XCTAssertEqual(firstFinal.Played, true)

        // Stop: the session no longer shows a playing item.
        try await send(reporter.stopped(at: 12), ledger: &ledger, api: api)
        let stopped = try await ownSession(session)
        XCTAssertNil(stopped?.NowPlayingItem)

        // "Recently played" (what the Home shelf queries) now leads with the two tracks.
        let recent = try await library.recentlyPlayedTracks(limit: 5).map(\.id)
        XCTAssertEqual(Array(recent.prefix(2)), [second.id, first.id])
    }

    /// The transcode URL the engine uses must be a progressive MP3 the stream
    /// parser can sync to, and `startTimeTicks` must shorten it.
    func testProgressiveTranscodeStreamsMP3AndSeeks() async throws {
        let session = try await liveSession()
        let library = MusicLibraryAPI(session: session)
        let albums = try await library.albums(limit: 1)
        let albumTracks = try await library.tracks(inAlbum: try XCTUnwrap(albums.first).id)
        let track = try XCTUnwrap(albumTracks.first)
        let request = StreamRequest.transcode(codec: "aac", container: "ts", maxBitrate: 128_000)

        let fullURL = StreamURLBuilder.progressiveURL(for: track.id, request: request, session: session)
        let (full, fullResponse) = try await transport.send(URLRequest(url: fullURL))
        XCTAssertEqual(fullResponse.statusCode, 200)
        XCTAssertEqual(fullResponse.value(forHTTPHeaderField: "Content-Type"), "audio/mpeg")
        // ID3 tag or a bare MPEG frame sync.
        let head = Array(full.prefix(3))
        XCTAssertTrue(head == Array("ID3".utf8) || (head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0), "not an MP3 stream")

        let seekTo = track.duration / 2
        let seekURL = StreamURLBuilder.progressiveURL(for: track.id, request: request, startTime: seekTo, session: session)
        let (seeked, seekResponse) = try await transport.send(URLRequest(url: seekURL))
        XCTAssertEqual(seekResponse.statusCode, 200)
        let ratio = Double(seeked.count) / Double(max(full.count, 1))
        XCTAssertEqual(ratio, 0.5, accuracy: 0.15, "seeking to the middle should deliver about half the bytes")
    }
}
