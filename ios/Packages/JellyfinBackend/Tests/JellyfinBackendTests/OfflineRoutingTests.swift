import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A browser that answers every list with one album named after itself, or
/// throws the error the test sets.
private final class FakeBrowser: LibraryBrowsing, @unchecked Sendable {
    let name: String
    var error: Error?
    private(set) var calls = 0

    init(name: String, error: Error? = nil) {
        self.name = name
        self.error = error
    }

    private func respond<T>(_ value: T) throws -> T {
        calls += 1
        if let error { throw error }
        return value
    }

    func albumsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Album> {
        try respond(Page(items: [Album(id: name, title: name, artistName: "")]))
    }
    func artistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Artist> {
        try respond(Page(items: []))
    }
    func tracksPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Track> {
        try respond(Page(items: []))
    }
    func playlistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Playlist> {
        try respond(Page(items: []))
    }
    func genresPage(startIndex: Int, limit: Int) async throws -> Page<Genre> { try respond(Page(items: [])) }
    func playlistTracksPage(playlistID: String, startIndex: Int, limit: Int) async throws -> Page<Track> {
        try respond(Page(items: []))
    }
    func alphabetOffset(of letter: String, kind: BrowseKind, filter: BrowseFilter) async throws -> Int { try respond(7) }
    func discography(artistID: String) async throws -> [Album] { try respond([]) }
    func appearsOn(artistID: String) async throws -> [Album] { try respond([]) }
    func playlist(id: String) async throws -> Playlist? { try respond(nil) }
}

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var error: Error?
    var status = 200
    private(set) var calls = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if let error { throw error }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}

final class OfflineAwareBrowserTests: XCTestCase {
    private let sort = AlbumSortOption.name.query()

    private func albumIDs(_ browser: OfflineAwareBrowser) async throws -> [String] {
        try await browser.albumsPage(sort: sort, filter: .none, startIndex: 0, limit: 10).items.map(\.id)
    }

    func testOnlineAnswersComeFromTheServer() async throws {
        let online = FakeBrowser(name: "online")
        let offline = FakeBrowser(name: "offline")
        let state = OfflineStateTracker()
        let browser = OfflineAwareBrowser(online: online, offline: offline, state: state)
        let ids = try await albumIDs(browser)
        XCTAssertEqual(ids, ["online"])
        XCTAssertEqual(offline.calls, 0)
        XCTAssertFalse(state.isOffline)
    }

    func testOfflineModeNeverTouchesTheServer() async throws {
        let online = FakeBrowser(name: "online")
        let offline = FakeBrowser(name: "offline")
        let state = OfflineStateTracker()
        state.setUserEnabled(true)
        let browser = OfflineAwareBrowser(online: online, offline: offline, state: state)
        let ids = try await albumIDs(browser)
        XCTAssertEqual(ids, ["offline"])
        XCTAssertEqual(online.calls, 0)
    }

    func testConnectivityFailureFallsBackAndMarksTheServerUnreachable() async throws {
        let online = FakeBrowser(name: "online", error: URLError(.cannotConnectToHost))
        let offline = FakeBrowser(name: "offline")
        let clock = Clock()
        let state = OfflineStateTracker(retryInterval: 20, now: { clock.now })
        let browser = OfflineAwareBrowser(online: online, offline: offline, state: state)

        let first = try await albumIDs(browser)
        XCTAssertEqual(first, ["offline"])
        XCTAssertEqual(state.snapshot.reason, .serverUnreachable)

        // Within the retry interval the dead server is not asked again.
        let second = try await albumIDs(browser)
        XCTAssertEqual(second, ["offline"])
        XCTAssertEqual(online.calls, 1)

        // After it, one probe goes out; the server is back.
        clock.now += 30
        online.error = nil
        let third = try await albumIDs(browser)
        XCTAssertEqual(third, ["online"])
        XCTAssertFalse(state.isOffline)
    }

    func testServerErrorsPassThroughWithoutGoingOffline() async {
        let online = FakeBrowser(name: "online", error: JellyfinError.serverError(status: 500))
        let offline = FakeBrowser(name: "offline")
        let state = OfflineStateTracker()
        let browser = OfflineAwareBrowser(online: online, offline: offline, state: state)
        do {
            _ = try await albumIDs(browser)
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .serverError(status: 500))
        }
        XCTAssertEqual(offline.calls, 0)
        XCTAssertFalse(state.isOffline)
    }

    func testListsDownloadsCannotProduceSurfaceAsUnavailable() async {
        let online = FakeBrowser(name: "online")
        let offline = FakeBrowser(name: "offline", error: LibraryBrowseError.unavailable)
        let state = OfflineStateTracker()
        state.setNetworkPath(isSatisfied: false, isExpensive: false)
        let browser = OfflineAwareBrowser(online: online, offline: offline, state: state)
        do {
            _ = try await browser.alphabetOffset(of: "M", kind: .albums, filter: .none)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? LibraryBrowseError, .unavailable)
        }
        XCTAssertEqual(online.calls, 0)
    }
}

final class OfflineGatedTransportTests: XCTestCase {
    private let request = URLRequest(url: URL(string: "http://jellyfin.local:8096/Items")!)

    func testRefusesAtOnceWhileOffline() async {
        let base = FakeTransport()
        let state = OfflineStateTracker()
        state.setUserEnabled(true)
        let transport = OfflineGatedTransport(base: base, state: state)
        do {
            _ = try await transport.send(request)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            // The library decorator must read it as "offline", not as a bug.
            XCTAssertTrue(OfflineLibrary.isConnectivityError(error))
        }
        XCTAssertEqual(base.calls, 0)
    }

    func testFailureMarksUnreachableAndLaterProbeRecovers() async throws {
        let base = FakeTransport()
        base.error = URLError(.timedOut)
        let clock = Clock()
        let state = OfflineStateTracker(retryInterval: 20, now: { clock.now })
        let transport = OfflineGatedTransport(base: base, state: state)

        do {
            _ = try await transport.send(request)
            XCTFail("expected the timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(state.snapshot.reason, .serverUnreachable)

        // Gated until the retry interval has passed.
        do {
            _ = try await transport.send(request)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(base.calls, 1)

        clock.now += 30
        base.error = nil
        let (_, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(state.isOffline)
    }

    func testAnHTTPErrorStatusStillMeansReachable() async throws {
        let base = FakeTransport()
        base.status = 500
        let state = OfflineStateTracker()
        state.recordConnectivityFailure()
        // Let the gate hand out its probe.
        let clockedState = OfflineStateTracker(retryInterval: 0)
        clockedState.recordConnectivityFailure()
        let transport = OfflineGatedTransport(base: base, state: clockedState)
        let (_, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertFalse(clockedState.isOffline)
        XCTAssertTrue(state.isOffline)
    }

    func testQuietTransportDoesNotDeclareTheServerUnreachable() async {
        let base = FakeTransport()
        base.error = URLError(.networkConnectionLost)
        let state = OfflineStateTracker()
        let transport = OfflineGatedTransport(base: base, state: state, marksUnreachable: false)
        _ = try? await transport.send(request)
        XCTAssertFalse(state.isOffline, "a failed playback report must not flip the app to offline")
        XCTAssertEqual(base.calls, 1)
        // …but it still keeps quiet while the app is offline for other reasons.
        state.setUserEnabled(true)
        _ = try? await transport.send(request)
        XCTAssertEqual(base.calls, 1)
    }

    func testCancellationIsNotAConnectivityVerdict() async {
        let base = FakeTransport()
        base.error = URLError(.cancelled)
        let state = OfflineStateTracker()
        let transport = OfflineGatedTransport(base: base, state: state)
        _ = try? await transport.send(request)
        XCTAssertFalse(state.isOffline)
    }
}

final class ProgressiveURLUnificationTests: XCTestCase {
    private let session = JellyfinSession(
        serverURL: URL(string: "http://jellyfin.local:8096")!,
        deviceID: "device-1",
        accessToken: "token",
        userID: "user-1"
    )

    /// The engine's URL is the live-tested builder's URL, not a second
    /// implementation that can drift.
    func testEngineURLIsTheProgressiveTranscodeURL() {
        let engine = StreamURLBuilder.progressiveURL(
            for: "t1",
            request: .transcode(codec: "aac", container: "ts", maxBitrate: 192_000),
            startTime: 42,
            playSessionID: "ps",
            session: session
        )
        let builder = StreamURLBuilder.progressiveTranscodeURL(
            for: "t1", codec: "mp3", container: "mp3", maxBitrate: 192_000, startTime: 42, playSessionID: "ps", session: session)
        XCTAssertEqual(engine, builder)
    }
}
