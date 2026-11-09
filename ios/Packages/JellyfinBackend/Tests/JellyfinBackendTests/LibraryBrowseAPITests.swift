import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request through a closure and records what was asked.
private final class BrowseScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> (Int, String)

    init(respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.respond = respond
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, body) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private extension URLRequest {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

private let session = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096")!,
    deviceID: "device-1",
    accessToken: "token",
    userID: "user-1"
)

final class LibraryBrowseAPITests: XCTestCase {
    func testTracksPageSendsPagingSortAndFilterAndReturnsTotal() async throws {
        let transport = BrowseScriptedTransport { _ in
            (200, #"{"Items":[{"Id":"t1","Name":"Adagio","Type":"Audio","RunTimeTicks":3000000000}],"TotalRecordCount":34}"#)
        }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let page = try await api.tracksPage(
            sort: TrackSortOption.title.query(),
            filter: BrowseFilter(genreID: "g1", favoritesOnly: true),
            startIndex: 200,
            limit: 100
        )
        XCTAssertEqual(page.totalCount, 34)
        XCTAssertEqual(page.items.map(\.title), ["Adagio"])
        XCTAssertEqual(page.items.first?.duration, 300)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/Items")
        XCTAssertEqual(request.queryValue("includeItemTypes"), "Audio")
        XCTAssertEqual(request.queryValue("recursive"), "true")
        XCTAssertEqual(request.queryValue("sortBy"), "Name")
        XCTAssertEqual(request.queryValue("sortOrder"), "Ascending")
        XCTAssertEqual(request.queryValue("startIndex"), "200")
        XCTAssertEqual(request.queryValue("limit"), "100")
        XCTAssertEqual(request.queryValue("genreIds"), "g1")
        XCTAssertEqual(request.queryValue("filters"), "IsFavorite")
        XCTAssertEqual(request.queryValue("userId"), "user-1")
        XCTAssertTrue(request.queryValue("fields")?.contains("MediaSources") ?? false)
    }

    func testAlbumsPageRequestsChildCount() async throws {
        let transport = BrowseScriptedTransport { _ in
            (200, #"{"Items":[{"Id":"a1","Name":"Voltage","ChildCount":5,"ProductionYear":2016}],"TotalRecordCount":1}"#)
        }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let page = try await api.albumsPage(sort: AlbumSortOption.year.query(), filter: BrowseFilter(artistID: "ar1"), startIndex: 0, limit: 50)
        XCTAssertEqual(page.items.first?.trackCount, 5)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.queryValue("fields")?.contains("ChildCount") ?? false)
        XCTAssertEqual(request.queryValue("sortOrder"), "Descending,Ascending")
        XCTAssertEqual(request.queryValue("albumArtistIds"), "ar1")
    }

    func testArtistsPageUsesAlbumArtistsEndpoint() async throws {
        let transport = BrowseScriptedTransport { _ in (200, #"{"Items":[{"Id":"ar1","Name":"Neon Circuit"}],"TotalRecordCount":6}"#) }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let page = try await api.artistsPage(sort: ArtistSortOption.name.query(), filter: BrowseFilter(favoritesOnly: true), startIndex: 100, limit: 100)
        XCTAssertEqual(page.totalCount, 6)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/Artists/AlbumArtists")
        XCTAssertEqual(request.queryValue("isFavorite"), "true")
        XCTAssertEqual(request.queryValue("startIndex"), "100")
    }

    func testPlaylistTracksPageKeepsEntryIDs() async throws {
        let transport = BrowseScriptedTransport { _ in
            (200, #"{"Items":[{"Id":"t1","Name":"A","PlaylistItemId":"e1"},{"Id":"t1","Name":"A","PlaylistItemId":"e2"}],"TotalRecordCount":2}"#)
        }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let page = try await api.playlistTracksPage(playlistID: "p1", startIndex: 0, limit: 100)
        XCTAssertEqual(page.items.map(\.playlistEntryID), ["e1", "e2"])
        XCTAssertEqual(transport.requests.first?.url?.path, "/Playlists/p1/Items")
    }

    func testAlphabetOffsetForAlbumsCountsNamesBelowLetter() async throws {
        let transport = BrowseScriptedTransport { _ in (200, #"{"Items":[],"TotalRecordCount":4}"#) }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let offset = try await api.alphabetOffset(of: "L", kind: .albums, filter: .none)
        XCTAssertEqual(offset, 4)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.queryValue("nameLessThan"), "L")
        XCTAssertEqual(request.queryValue("limit"), "0")

        let start = try await api.alphabetOffset(of: "#", kind: .albums, filter: .none)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(transport.requests.count, 1, "# is the start of the list — no request")
    }

    func testAlphabetOffsetForTracksBinarySearchesByTitle() async throws {
        let titles = ["Adagio", "Blast Line", "Clock In", "Phosphor", "Polaris", "Sampler Intro", "Set One", "Tidal Sleep"]
        let transport = BrowseScriptedTransport { request in
            let start = Int(request.queryValue("startIndex") ?? "0") ?? 0
            if request.queryValue("limit") == "0" {
                return (200, #"{"Items":[],"TotalRecordCount":\#(titles.count)}"#)
            }
            return (200, #"{"Items":[{"Id":"t\#(start)","Name":"\#(titles[start])"}],"TotalRecordCount":1}"#)
        }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let offset = try await api.alphabetOffset(of: "S", kind: .tracks, filter: .none)
        XCTAssertEqual(offset, 5)
        XCTAssertLessThanOrEqual(transport.requests.count, 5, "one count request plus log2(8)+1 probes")
        let probe = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(probe.queryValue("sortBy"), "Name")
        XCTAssertEqual(probe.queryValue("limit"), "1")
        XCTAssertEqual(probe.queryValue("enableTotalRecordCount"), "false")
        XCTAssertNil(probe.queryValue("nameLessThan"), "sort names of audio items are track numbers")
    }

    func testAppearsOnDoesNotExcludeTheArtist() async throws {
        let transport = BrowseScriptedTransport { _ in (200, #"{"Items":[{"Id":"a1","Name":"Jellyamp Sampler"}],"TotalRecordCount":1}"#) }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let albums = try await api.appearsOn(artistID: "ar1")
        XCTAssertEqual(albums.map(\.title), ["Jellyamp Sampler"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.queryValue("contributingArtistIds"), "ar1")
        XCTAssertNil(request.queryValue("excludeArtistIds"))
    }

    func testErrorsMapToJellyfinError() async {
        let transport = BrowseScriptedTransport { _ in (401, "") }
        let api = LibraryBrowseAPI(session: session, transport: transport)
        do {
            _ = try await api.genresPage(startIndex: 0, limit: 10)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .unauthorized)
        }
    }
}

final class LibraryProviderBrowserTests: XCTestCase {
    /// The wrapped provider is the real API over a scripted transport, so the
    /// test does not need its own conformance to the (growing) protocol.
    private func browser(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) -> (LibraryProviderBrowser, BrowseScriptedTransport) {
        let transport = BrowseScriptedTransport(respond: respond)
        return (LibraryProviderBrowser(library: MusicLibraryAPI(session: session, transport: transport)), transport)
    }

    func testWholeCollectionsComeBackAsOnePage() async throws {
        let (browser, _) = browser { _ in (200, #"{"Items":[{"Id":"t1","Name":"A"},{"Id":"t2","Name":"B"}]}"#) }
        let first = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: BrowseFilter(favoritesOnly: true), startIndex: 0, limit: 100)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.totalCount, 2)
        let second = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: BrowseFilter(favoritesOnly: true), startIndex: 2, limit: 100)
        XCTAssertTrue(second.items.isEmpty)
    }

    func testPagedAlbumCallIsForwarded() async throws {
        let (browser, transport) = browser { _ in (200, #"{"Items":[{"Id":"a1","Name":"A"}]}"#) }
        let page = try await browser.albumsPage(sort: AlbumSortOption.year.query(), filter: .none, startIndex: 300, limit: 100)
        XCTAssertEqual(page.items.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.queryValue("startIndex"), "300")
        XCTAssertEqual(request.queryValue("sortOrder"), "Descending")
    }

    func testUnsupportedListsThrowUnavailable() async {
        let (browser, _) = browser { _ in (200, #"{"Items":[]}"#) }
        do {
            _ = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: 0, limit: 100)
            XCTFail("the complete song list is not available through the provider")
        } catch {
            XCTAssertEqual(error as? LibraryBrowseError, .unavailable)
        }
    }
}

/// Runs against a real Jellyfin when `JELLYFIN_LIVE_URL`, `JELLYFIN_API_KEY`
/// and `JELLYFIN_USER_ID` are set (the dev server from `scripts/dev-jellyfin`
/// with its synthetic 34-track library); skipped otherwise.
final class LibraryBrowseLiveTests: XCTestCase {
    private func liveAPI() throws -> LibraryBrowseAPI {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["JELLYFIN_LIVE_URL"], let url = URL(string: urlString),
              let key = environment["JELLYFIN_API_KEY"], let user = environment["JELLYFIN_USER_ID"] else {
            throw XCTSkip("no live Jellyfin configured")
        }
        return LibraryBrowseAPI(session: JellyfinSession(serverURL: url, deviceID: "live-test", accessToken: key, userID: user))
    }

    func testPagingThroughAllSongsYieldsEachSongOnce() async throws {
        let api = try liveAPI()
        var state = PagedListState<Track>(pageSize: 10)
        var request: PageRequest? = state.beginReload()
        var pages = 0
        while let current = request {
            let page = try await api.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: current.startIndex, limit: current.limit)
            state.receive(page, for: current)
            pages += 1
            request = state.beginNextPage()
        }
        XCTAssertEqual(state.items.count, 34)
        XCTAssertEqual(state.totalCount, 34)
        XCTAssertEqual(pages, 4)
        XCTAssertEqual(state.items.first?.title, "Adagio")
        XCTAssertEqual(Set(state.items.map(\.id)).count, 34)
    }

    func testAlphabetOffsets() async throws {
        let api = try liveAPI()
        let songs = try await api.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: 0, limit: 100).items
        let songOffset = try await api.alphabetOffset(of: "S", kind: .tracks, filter: .none)
        XCTAssertEqual(songs[songOffset].title, "Sampler Intro")
        let albumOffset = try await api.alphabetOffset(of: "L", kind: .albums, filter: .none)
        XCTAssertEqual(albumOffset, 4)
        let albums = try await api.albumsPage(sort: AlbumSortOption.name.query(), filter: .none, startIndex: albumOffset, limit: 2)
        XCTAssertEqual(albums.items.map(\.title), ["Live at the Cellar", "Low Tide"])
        // "The Granite Saints" sorts under G.
        let artistOffset = try await api.alphabetOffset(of: "G", kind: .artists, filter: .none)
        let artists = try await api.artistsPage(sort: ArtistSortOption.name.query(), filter: .none, startIndex: artistOffset, limit: 1)
        XCTAssertEqual(artists.items.first?.name, "The Granite Saints")
    }

    func testSortOrders() async throws {
        let api = try liveAPI()
        let byYear = try await api.albumsPage(sort: AlbumSortOption.year.query(), filter: .none, startIndex: 0, limit: 3)
        XCTAssertEqual(byYear.items.map(\.title), ["Jellyamp Sampler", "Afterimage", "Voltage"])
        XCTAssertEqual(byYear.totalCount, 10)
        XCTAssertEqual(byYear.items.first?.trackCount, 2)
        let byAlbum = try await api.tracksPage(sort: TrackSortOption.album.query(), filter: .none, startIndex: 0, limit: 3)
        XCTAssertEqual(byAlbum.items.map(\.title), ["Phosphor", "Persistence", "Scanline"])
    }

    func testCompilationAndAppearsOn() async throws {
        let api = try liveAPI()
        let artists = try await api.artistsPage(sort: ArtistSortOption.name.query(), filter: BrowseFilter(searchTerm: "neon"), startIndex: 0, limit: 5)
        let neon = try XCTUnwrap(artists.items.first { $0.name == "Neon Circuit" })
        let appearsOn = try await api.appearsOn(artistID: neon.id)
        XCTAssertEqual(appearsOn.map(\.title), ["Jellyamp Sampler"])
        XCTAssertEqual(appearsOn.first?.artistName, "Various Artists")
        let discography = try await api.discography(artistID: neon.id)
        XCTAssertEqual(discography.map(\.title), ["Afterimage", "Voltage"])
        XCTAssertEqual(discography.map(\.trackCount), [3, 5])
        let split = Discography(releases: discography)
        XCTAssertEqual(split.albums.map(\.title), ["Voltage"])
        XCTAssertEqual(split.singlesAndEPs.map(\.title), ["Afterimage"])
    }

    func testGenreContentsAndSearch() async throws {
        let api = try liveAPI()
        let genres = try await api.genresPage(startIndex: 0, limit: 50)
        XCTAssertEqual(genres.totalCount, 5)
        let ambient = try XCTUnwrap(genres.items.first { $0.name == "Ambient" })
        let filter = BrowseFilter(genreID: ambient.id)
        let albums = try await api.albumsPage(sort: AlbumSortOption.name.query(), filter: filter, startIndex: 0, limit: 50)
        XCTAssertEqual(albums.items.map(\.title), ["Low Tide", "Night Maps"])
        let tracks = try await api.tracksPage(sort: TrackSortOption.album.query(), filter: filter, startIndex: 5, limit: 3)
        XCTAssertEqual(tracks.totalCount, 7)
        XCTAssertEqual(tracks.items.count, 2)
        let found = try await api.tracksPage(sort: TrackSortOption.title.query(), filter: BrowseFilter(searchTerm: "slow"), startIndex: 1, limit: 1)
        XCTAssertEqual(found.totalCount, 2)
        // With a search term the server orders by relevance and ignores sortBy.
        XCTAssertEqual(found.items.count, 1)
        XCTAssertTrue(["Slow Water", "Slow Train"].contains(found.items.first?.title ?? ""))
    }

    /// Replays the app's reorder flow (send the natural Move, compare with
    /// the server, send `legacyMoveOperations` if the order differs) for
    /// every from/to pair of a five-track playlist. Needs a user login
    /// (`JELLYFIN_USER` / `JELLYFIN_PASSWORD`): the Move endpoint rejects API
    /// keys. Creates one playlist and deletes it again.
    func testPlaylistReorderConvergesOnRealServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["JELLYFIN_LIVE_URL"], let url = URL(string: urlString),
              let user = environment["JELLYFIN_USER"], let password = environment["JELLYFIN_PASSWORD"] else {
            throw XCTSkip("no live Jellyfin login configured")
        }
        let session = try await JellyfinAuthenticator().authenticateByName(
            session: JellyfinSession(serverURL: url, deviceID: "live-test-reorder"), username: user, password: password
        )
        let library = MusicLibraryAPI(session: session)
        let browser = LibraryBrowseAPI(session: session)
        let songs = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: 0, limit: 5).items
        XCTAssertEqual(songs.count, 5)
        let playlistID = try await library.createPlaylist(name: "zz-reorder-live-test", itemIDs: songs.map(\.id))

        func serverOrder() async throws -> [String] {
            try await browser.playlistTracksPage(playlistID: playlistID, startIndex: 0, limit: 100).items.compactMap(\.playlistEntryID)
        }

        var failures: [String] = []
        var corrected = 0
        do {
            let count = try await serverOrder().count
            XCTAssertEqual(count, 5)
            for from in 0..<count {
                for to in 0..<count where to != from {
                    let current = try await serverOrder()
                    var desired = current
                    let moved = desired.remove(at: from)
                    desired.insert(moved, at: to)

                    try await library.movePlaylistItem(playlistID: playlistID, entryID: moved, toIndex: to)
                    var result = try await serverOrder()
                    if result != desired {
                        corrected += 1
                        let operations = try XCTUnwrap(PlaylistEditing.legacyMoveOperations(current: result, desired: desired))
                        for operation in operations {
                            try await library.movePlaylistItem(playlistID: playlistID, entryID: operation.entryID, toIndex: operation.index)
                        }
                        result = try await serverOrder()
                    }
                    if result != desired { failures.append("\(from)→\(to)") }
                }
            }
        } catch {
            try? await library.deletePlaylist(playlistID: playlistID)
            throw error
        }
        try await library.deletePlaylist(playlistID: playlistID)
        XCTAssertEqual(failures, [], "moves that did not converge")
        print("reorder live test: \(corrected) of 20 moves needed the legacy correction")
    }
}
