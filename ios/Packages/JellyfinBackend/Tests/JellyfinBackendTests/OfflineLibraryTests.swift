import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let session = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096/base")!,
    deviceID: "device-1",
    accessToken: "token-abc-123",
    userID: "user-1"
)

final class DownloadURLTests: XCTestCase {
    func testDownloadURLUsesTheDownloadEndpointWithTokenInQuery() {
        let url = StreamURLBuilder.downloadURL(for: "track9", session: session)
        XCTAssertEqual(url.absoluteString, "http://jellyfin.local:8096/base/Items/track9/Download?api_key=token-abc-123")
    }

    func testOfflineArtworkURLIsTagless() {
        let url = ImageURLBuilder.offlineArtworkURL(itemID: "album1", session: session)
        XCTAssertEqual(url.path, "/base/Items/album1/Images/Primary")
        XCTAssertEqual(url.query, "fillWidth=1000&quality=90")
    }
}

/// Online library whose reachability the test controls. Only the calls the
/// tests exercise do anything interesting.
private final class FakeOnlineLibrary: MusicLibraryProviding, @unchecked Sendable {
    var error: Error?
    var calls = 0
    let onlineTrack = Track(id: "online", title: "Online", artistName: "Server", duration: 1)

    private func respond<T>(_ value: T) throws -> T {
        calls += 1
        if let error { throw error }
        return value
    }

    func albums(sortBy: String, sortOrder: String, startIndex: Int, limit: Int) async throws -> [Album] {
        try respond([Album(id: "online-album", title: "Online", artistName: "Server")])
    }
    func album(id: String) async throws -> Album? { try respond(nil) }
    func tracks(inAlbum albumID: String) async throws -> [Track] { try respond([onlineTrack]) }
    func artists(sortBy: String, startIndex: Int, limit: Int) async throws -> [Artist] { try respond([]) }
    func artist(id: String) async throws -> Artist? { try respond(nil) }
    func albums(byArtist artistID: String) async throws -> [Album] { try respond([]) }
    func appearsOnAlbums(artistID: String) async throws -> [Album] { try respond([]) }
    func tracks(byArtist artistID: String) async throws -> [Track] { try respond([]) }
    func topTracks(byArtist artistID: String, limit: Int) async throws -> [Track] { try respond([]) }
    func similarArtists(artistID: String, limit: Int) async throws -> [Artist] { try respond([Artist(id: "sim", name: "Sim")]) }
    func favoriteTracks(limit: Int) async throws -> [Track] { try respond([]) }
    func favoriteAlbums(limit: Int) async throws -> [Album] { try respond([]) }
    func favoriteArtists(limit: Int) async throws -> [Artist] { try respond([]) }
    func tracks(inGenre genreID: String) async throws -> [Track] { try respond([onlineTrack]) }
    func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? { try respond(nil) }
    func genres() async throws -> [Genre] { try respond([Genre(id: "guid-rock", name: "Rock")]) }
    func createPlaylist(name: String, itemIDs: [String]) async throws -> String { try respond("new") }
    func addToPlaylist(playlistID: String, itemIDs: [String]) async throws { try respond(()) }
    func playlists() async throws -> [Playlist] { try respond([]) }
    func tracks(inPlaylist playlistID: String) async throws -> [Track] { try respond([]) }
    func removeFromPlaylist(playlistID: String, entryIDs: [String]) async throws { try respond(()) }
    func movePlaylistItem(playlistID: String, entryID: String, toIndex: Int) async throws { try respond(()) }
    func renamePlaylist(playlistID: String, name: String) async throws { try respond(()) }
    func deletePlaylist(playlistID: String) async throws { try respond(()) }
    func setPlaylistImage(playlistID: String, jpeg: Data) async throws { try respond(()) }
    func recentlyAddedAlbums(limit: Int) async throws -> [Album] { try respond([]) }
    func recentlyPlayedTracks(limit: Int) async throws -> [Track] { try respond([onlineTrack]) }
    func search(query: String, limit: Int) async throws -> (tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) {
        try respond(([onlineTrack], [], [], []))
    }
    func tracks(byIDs ids: [String]) async throws -> [Track] { try respond([onlineTrack]) }
    func setFavorite(itemID: String, isFavorite: Bool) async throws { try respond(()) }
}

private struct FixedCatalog: OfflineCatalogProviding {
    let catalog: OfflineCatalog
    func offlineCatalog() async -> OfflineCatalog { catalog }
}

final class OfflineLibraryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 0)
    }

    private let clock = Clock()
    private var online: FakeOnlineLibrary!
    private var tracker: OfflineStateTracker!
    private var library: OfflineLibrary!

    override func setUp() {
        let now = Date(timeIntervalSince1970: 0)
        var index = DownloadIndex()
        let local = Track(
            id: "local", title: "Local Song", artistName: "Disk", artistID: "disk", albumName: "On Device",
            albumID: "local-album", duration: 1, genres: ["Rock"]
        )
        index.setPin(.track(local, now: now), tracks: [local], now: now)
        index.markCompleted(id: "local", bytes: 1, now: now)
        let clock = self.clock
        online = FakeOnlineLibrary()
        tracker = OfflineStateTracker(retryInterval: 20, now: { clock.date })
        library = OfflineLibrary(
            online: online,
            catalog: FixedCatalog(catalog: OfflineCatalog(index: index, genreNamesByID: ["guid-rock": "Rock"])),
            state: tracker
        )
    }

    func testOnlinePassesThrough() async throws {
        let albums = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 10)
        XCTAssertEqual(albums.map(\.id), ["online-album"])
        XCTAssertFalse(tracker.isOffline)
    }

    func testOfflineModeServesDownloadsWithoutTouchingTheServer() async throws {
        tracker.setUserEnabled(true)
        let albums = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 10)
        XCTAssertEqual(albums.map(\.id), ["local-album"])
        let search = try await library.search(query: "local", limit: 5)
        XCTAssertEqual(search.tracks.map(\.id), ["local"])
        let albumSearch = try await library.search(query: "on device", limit: 5)
        XCTAssertEqual(albumSearch.albums.map(\.id), ["local-album"])
        let similar = try await library.similarArtists(artistID: "disk", limit: 5)
        XCTAssertTrue(similar.isEmpty)
        let recent = try await library.recentlyPlayedTracks(limit: 5)
        XCTAssertTrue(recent.isEmpty)
        let genreTracks = try await library.tracks(inGenre: "guid-rock")
        XCTAssertEqual(genreTracks.map(\.id), ["local"])
        XCTAssertEqual(online.calls, 0)
    }

    func testConnectivityFailureFallsBackAndMarksServerUnreachable() async throws {
        online.error = URLError(.cannotConnectToHost)
        let tracks = try await library.tracks(byIDs: ["local", "missing"])
        XCTAssertEqual(tracks.map(\.id), ["local"])
        XCTAssertEqual(tracker.snapshot.reason, .serverUnreachable)

        // While the circuit is open the server is left alone…
        _ = try await library.genres()
        XCTAssertEqual(online.calls, 1)

        // …until the retry interval passes; then one probe notices recovery.
        clock.date = Date(timeIntervalSince1970: 30)
        online.error = nil
        let genres = try await library.genres()
        XCTAssertEqual(genres.map(\.id), ["guid-rock"])
        XCTAssertFalse(tracker.isOffline)
    }

    func testServerErrorsAreNotMistakenForBeingOffline() async {
        online.error = JellyfinError.serverError(status: 500)
        do {
            _ = try await library.playlists()
            XCTFail("expected the server error to surface")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .serverError(status: 500))
        }
        XCTAssertFalse(tracker.isOffline)
    }

    func testMutationsFailWithTypedErrorWhileOffline() async {
        tracker.setUserEnabled(true)
        do {
            try await library.setFavorite(itemID: "local", isFavorite: true)
            XCTFail("expected an offline error")
        } catch {
            XCTAssertEqual(error as? OfflineLibraryError, .unavailableOffline(.changeFavorite))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        do {
            _ = try await library.createPlaylist(name: "x", itemIDs: [])
            XCTFail("expected an offline error")
        } catch {
            XCTAssertEqual(error as? OfflineLibraryError, .unavailableOffline(.editPlaylist))
        }
        XCTAssertEqual(online.calls, 0)
    }

    func testMutationThatLosesTheConnectionReportsOffline() async {
        online.error = URLError(.notConnectedToInternet)
        do {
            try await library.renamePlaylist(playlistID: "p", name: "n")
            XCTFail("expected an offline error")
        } catch {
            XCTAssertEqual(error as? OfflineLibraryError, .unavailableOffline(.editPlaylist))
        }
        XCTAssertEqual(tracker.snapshot.reason, .serverUnreachable)
    }

    func testOfflineGenreIDsNeverHitTheServer() async throws {
        let tracks = try await library.tracks(inGenre: OfflineCatalog.genreIDPrefix + "Rock")
        XCTAssertEqual(tracks.map(\.id), ["local"])
        XCTAssertEqual(online.calls, 0)
    }

    func testFetchedGenresAreReportedForOfflineUse() async throws {
        final class Box: @unchecked Sendable { var genres: [Genre] = [] }
        let box = Box()
        let reporting = OfflineLibrary(
            online: online,
            catalog: FixedCatalog(catalog: OfflineCatalog(index: DownloadIndex())),
            state: tracker,
            onGenresFetched: { box.genres = $0 }
        )
        _ = try await reporting.genres()
        XCTAssertEqual(box.genres.map(\.name), ["Rock"])
    }

    func testConnectivityErrorClassification() {
        XCTAssertTrue(OfflineLibrary.isConnectivityError(URLError(.timedOut)))
        XCTAssertTrue(OfflineLibrary.isConnectivityError(URLError(.cannotFindHost)))
        XCTAssertFalse(OfflineLibrary.isConnectivityError(URLError(.badURL)))
        XCTAssertFalse(OfflineLibrary.isConnectivityError(JellyfinError.unauthorized))
        XCTAssertFalse(OfflineLibrary.isConnectivityError(CancellationError()))
    }
}
