import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
            throw JellyfinError.invalidResponse
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stubbed.status, httpVersion: nil, headerFields: nil)!
        return (stubbed.body, response)
    }
}

private let testSession = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096")!,
    deviceID: "device-1",
    accessToken: "token-abc-123",
    userID: "user-1"
)

final class JellyfinSessionTests: XCTestCase {
    func testAuthorizationHeaderWithoutToken() {
        let session = JellyfinSession(serverURL: URL(string: "http://x")!, deviceID: "d1")
        XCTAssertEqual(
            session.authorizationHeader,
            "MediaBrowser Client=\"Jellyamp\", Device=\"iPhone\", DeviceId=\"d1\", Version=\"0.1.0\""
        )
        XCTAssertFalse(session.isAuthenticated)
    }

    func testAuthorizationHeaderWithToken() {
        XCTAssertTrue(testSession.authorizationHeader.hasSuffix("Token=\"token-abc-123\""))
        XCTAssertTrue(testSession.isAuthenticated)
    }

    func testAuthenticateByNameUpdatesSession() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "AuthenticateByName", fixture: "auth")
        let authenticator = JellyfinAuthenticator(transport: transport)
        let fresh = JellyfinSession(serverURL: URL(string: "http://jellyfin.local:8096")!, deviceID: "d1")
        let authenticated = try await authenticator.authenticateByName(session: fresh, username: "tobi", password: "pw")
        XCTAssertEqual(authenticated.accessToken, "token-abc-123")
        XCTAssertEqual(authenticated.userID, "user-1")
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
    }

    func testWrongPasswordThrowsUnauthorized() async {
        let transport = StubTransport()
        transport.stub(pathContains: "AuthenticateByName", status: 401)
        let authenticator = JellyfinAuthenticator(transport: transport)
        let fresh = JellyfinSession(serverURL: URL(string: "http://jellyfin.local:8096")!, deviceID: "d1")
        do {
            _ = try await authenticator.authenticateByName(session: fresh, username: "tobi", password: "bad")
            XCTFail("expected unauthorized")
        } catch let error as JellyfinError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

final class MusicLibraryAPITests: XCTestCase {
    func testTracksInAlbumMapDTOFields() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "Items", fixture: "album_tracks")
        let api = MusicLibraryAPI(session: testSession, transport: transport)
        let tracks = try await api.tracks(inAlbum: "album1")

        XCTAssertEqual(tracks.count, 2)
        let first = tracks[0]
        XCTAssertEqual(first.id, "track1")
        XCTAssertEqual(first.title, "Opening Song")
        XCTAssertEqual(first.artistName, "The Band")
        XCTAssertEqual(first.artistID, "artist1")
        XCTAssertEqual(first.albumID, "album1")
        XCTAssertEqual(first.duration, 240, accuracy: 1e-9)
        XCTAssertEqual(first.codec, "flac")
        XCTAssertEqual(first.bitrate, 1_411_000)
        XCTAssertEqual(first.sampleRate, 44_100)
        XCTAssertEqual(first.normalizationGainDB ?? 0, -7.2, accuracy: 1e-9)
        XCTAssertTrue(first.isFavorite)
        XCTAssertEqual(first.imageTag, "abc123")
    }

    func testRequestsIncludeFieldsAndUser() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "Items", fixture: "album_tracks")
        let api = MusicLibraryAPI(session: testSession, transport: transport)
        _ = try await api.tracks(inAlbum: "album1")

        let query = transport.requests.first!.url!.query!
        XCTAssertTrue(query.contains("fields=MediaSources"), "media sources must be requested explicitly")
        XCTAssertTrue(query.contains("userId=user-1"))
        XCTAssertTrue(transport.requests.first!.value(forHTTPHeaderField: "Authorization")!.contains("Token="))
    }

    func testAlbumsDecode() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "Items", fixture: "albums")
        let api = MusicLibraryAPI(session: testSession, transport: transport)
        let albums = try await api.albums(sortBy: "SortName", startIndex: 0, limit: 10)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].title, "Great Album")
        XCTAssertEqual(albums[0].artistID, "artist1")
        XCTAssertEqual(albums[0].trackCount, 11)
        XCTAssertEqual(albums[0].imageTag, "tag-album1")
    }
}

final class StreamURLBuilderTests: XCTestCase {
    private func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testDirectPlayURL() {
        let url = StreamURLBuilder.url(for: "track1", request: .directPlay, session: testSession)
        XCTAssertTrue(url.path.hasSuffix("/Audio/track1/universal"))
        let query = queryItems(of: url)
        XCTAssertEqual(query["static"], "true")
        XCTAssertEqual(query["userId"], "user-1")
        XCTAssertEqual(query["deviceId"], "device-1")
        XCTAssertEqual(query["api_key"], "token-abc-123")
        XCTAssertNotNil(query["playSessionId"])
    }

    func testTranscodeURL() {
        let url = StreamURLBuilder.url(
            for: "track1",
            request: .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000),
            session: testSession
        )
        let query = queryItems(of: url)
        XCTAssertNil(query["static"])
        XCTAssertEqual(query["audioCodec"], "aac")
        XCTAssertEqual(query["transcodingContainer"], "m4a")
        XCTAssertEqual(query["maxStreamingBitrate"], "320000")
    }

    func testSeekAddsStartTimeTicksOnce() {
        let base = StreamURLBuilder.url(
            for: "track1",
            request: .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000),
            session: testSession
        )
        let seeked = StreamURLBuilder.url(StreamURLBuilder.url(base, seekingTo: 10), seekingTo: 65.5)
        let query = queryItems(of: seeked)
        XCTAssertEqual(query["startTimeTicks"], "655000000")
        let occurrences = seeked.query!.components(separatedBy: "startTimeTicks").count - 1
        XCTAssertEqual(occurrences, 1)
    }
}

final class ImageURLBuilderTests: XCTestCase {
    func testTrackImageFallsBackToAlbum() {
        let track = Track(id: "track1", title: "T", artistName: "A", albumID: "album1", duration: 1, imageTag: "tag1")
        let url = ImageURLBuilder.trackImageURL(track: track, maxWidth: 600, session: testSession)
        XCTAssertTrue(url!.path.contains("/Items/album1/Images/Primary"))
        XCTAssertTrue(url!.query!.contains("tag=tag1"))
    }

    func testTrackWithoutAnyImageReturnsNil() {
        let track = Track(id: "track1", title: "T", artistName: "A", duration: 1)
        XCTAssertNil(ImageURLBuilder.trackImageURL(track: track, maxWidth: 600, session: testSession))
    }
}

final class PlaybackReportingAPITests: XCTestCase {
    func testReportRequestShape() throws {
        let api = PlaybackReportingAPI(session: testSession)
        let request = try api.makeRequest(
            for: .progress(trackID: "track1", positionTicks: 1_200_000_000, isPaused: true),
            playSessionID: "ps-1"
        )
        XCTAssertTrue(request.url!.path.hasSuffix("Sessions/Playing/Progress"))
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["ItemId"] as? String, "track1")
        XCTAssertEqual(body["IsPaused"] as? Bool, true)
        XCTAssertEqual(body["PlaySessionId"] as? String, "ps-1")
        XCTAssertEqual((body["PositionTicks"] as? NSNumber)?.int64Value, 1_200_000_000)
    }

    func testStartAndStopPaths() throws {
        let api = PlaybackReportingAPI(session: testSession)
        let start = try api.makeRequest(for: .started(trackID: "t", positionTicks: 0), playSessionID: "ps")
        let stop = try api.makeRequest(for: .stopped(trackID: "t", positionTicks: 5), playSessionID: "ps")
        XCTAssertTrue(start.url!.path.hasSuffix("Sessions/Playing"))
        XCTAssertTrue(stop.url!.path.hasSuffix("Sessions/Playing/Stopped"))
    }
}

final class LyricsAPITests: XCTestCase {
    func testSyncedLyricsDecodeToTimeline() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "Lyrics", fixture: "lyrics")
        let api = LyricsAPI(session: testSession, transport: transport)
        let timeline = try await api.lyrics(forTrack: "track1")
        XCTAssertEqual(timeline?.lines.count, 2)
        XCTAssertTrue(timeline!.isSynced)
        XCTAssertEqual(timeline!.lines[0].start ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(timeline!.activeLineIndex(at: 6), 1)
    }

    func testMissingLyricsReturnNil() async throws {
        let transport = StubTransport()
        transport.stub(pathContains: "Lyrics", status: 404)
        let api = LyricsAPI(session: testSession, transport: transport)
        let timeline = try await api.lyrics(forTrack: "track1")
        XCTAssertNil(timeline)
    }
}
