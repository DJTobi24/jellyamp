import XCTest
import JellyampCore
import JellyfinBackend
@testable import JellyfinDemo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's real Jellyfin clients against the demo backend: every call a
/// screen makes must work, because in demo mode nothing else stands between
/// the UI and this code.
final class DemoLibraryAPITests: XCTestCase {
    private var backend: DemoBackend!
    private var session: JellyfinSession!
    private var library: MusicLibraryAPI!
    private var browser: LibraryBrowseAPI!
    private var lookup: LibraryLookupAPI!

    override func setUp() {
        backend = DemoBackend()
        session = JellyfinSession(
            serverURL: URL(string: "http://demo.invalid")!,
            deviceID: "tests",
            accessToken: DemoCatalog.accessToken,
            userID: DemoCatalog.userID
        )
        let transport = DemoTransport(backend: backend)
        library = MusicLibraryAPI(session: session, transport: transport)
        browser = LibraryBrowseAPI(session: session, transport: transport)
        lookup = LibraryLookupAPI(session: session, transport: transport)
    }

    private var nightFerry: DemoCatalog.Track { DemoCatalog.track(album: 2, number: 2) }

    // MARK: - Catalog shape

    func testCatalogHasTheAdvertisedSize() {
        XCTAssertEqual(DemoCatalog.artists.count, 6)
        XCTAssertEqual(DemoCatalog.albums.count, 12)
        XCTAssertEqual(DemoCatalog.tracks.count, 60)
        XCTAssertEqual(DemoCatalog.playlists.count, 3)
        XCTAssertEqual(Set(DemoCatalog.tracks.map(\.id)).count, 60)
        for id in DemoCatalog.tracks.map(\.id) + DemoCatalog.albums.map(\.id) + DemoCatalog.artists.map(\.id) {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy(\.isHexDigit), id)
        }
        for track in DemoCatalog.tracks {
            XCTAssertGreaterThan(track.duration, 110)
            XCTAssertLessThan(track.duration, 270)
        }
    }

    // MARK: - MusicLibraryProviding

    func testAlbumsAreSortedAndPaged() async throws {
        let all = try await library.albums()
        XCTAssertEqual(all.count, 12)
        XCTAssertEqual(all.map(\.title), [
            "Afterglow Motel", "Blue Hour Sessions", "Chrome Sunsets", "Études for Rain", "Letters to the Orchard", "Loud Rooms",
            "Night Ferry", "Nocturnes in Glass", "Second Set", "Slow Weather", "Small Hours", "Tidal Rooms",
        ])
        XCTAssertTrue(all.allSatisfy { $0.trackCount == 5 && $0.imageTag != nil && !$0.genres.isEmpty && $0.artistID != nil })

        let page = try await library.albums(sortBy: "ProductionYear", sortOrder: "Descending", startIndex: 2, limit: 3)
        XCTAssertEqual(page.map(\.productionYear), [2021, 2020, 2019])
    }

    func testAlbumAndItsTracks() async throws {
        let albumID = DemoCatalog.albums[2].id
        let album = try await library.album(id: albumID)
        XCTAssertEqual(album?.title, "Night Ferry")
        XCTAssertEqual(album?.artistName, "Neon Estuary")
        XCTAssertEqual(album?.productionYear, 2023)
        XCTAssertEqual(album?.isFavorite, true)

        let tracks = try await library.tracks(inAlbum: albumID)
        XCTAssertEqual(tracks.map(\.indexNumber), [1, 2, 3, 4, 5])
        XCTAssertEqual(tracks[1].title, "Night Ferry")
        for track in tracks {
            XCTAssertEqual(track.albumID, albumID)
            XCTAssertEqual(track.container, "aac")
            XCTAssertEqual(track.codec, "aac")
            XCTAssertEqual(track.sampleRate, 44_100)
            XCTAssertNotNil(track.bitrate)
            XCTAssertNotNil(track.imageTag)
            XCTAssertNotNil(track.normalizationGainDB)
            XCTAssertEqual(track.genres, ["Electronic"])
            XCTAssertGreaterThan(track.duration, 100)
        }
        // The player must take the direct-play path: demo audio cannot be transcoded.
        XCTAssertEqual(PlaybackProfile().request(for: tracks[0], network: .wifi), .directPlay)
        XCTAssertEqual(PlaybackProfile().request(for: tracks[0], network: .cellular), .directPlay)

        let missingAlbum = try await library.album(id: "b0000000000000000000000000000099")
        XCTAssertNil(missingAlbum)
        // A track ID is not an album.
        let wrongKind = try await library.album(id: nightFerry.id)
        XCTAssertNil(wrongKind)
    }

    func testArtists() async throws {
        let artists = try await library.artists()
        XCTAssertEqual(artists.count, 6)
        // "The Paper Lanterns" sorts under P.
        XCTAssertEqual(artists.map(\.name), ["Kite & Compass Trio", "Lumen Drift", "Mira Solène", "Neon Estuary", "The Paper Lanterns", "Velvet Static"])
        XCTAssertTrue(artists.allSatisfy { !$0.genres.isEmpty && $0.imageTag != nil })

        let artistID = DemoCatalog.artists[1].id
        let artist = try await library.artist(id: artistID)
        XCTAssertEqual(artist?.name, "Neon Estuary")
        XCTAssertFalse(artist?.overview?.isEmpty ?? true)

        let albums = try await library.albums(byArtist: artistID)
        XCTAssertEqual(albums.map(\.title), ["Night Ferry", "Chrome Sunsets"])

        let tracks = try await library.tracks(byArtist: artistID)
        // Ten of their own plus the guest spot on "Vacancy Sign".
        XCTAssertEqual(tracks.count, 11)

        let top = try await library.topTracks(byArtist: artistID, limit: 3)
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(top.first?.title, "Night Ferry")

        let appearsOn = try await library.appearsOnAlbums(artistID: artistID)
        XCTAssertEqual(appearsOn.map(\.title), ["Afterglow Motel"])

        let similar = try await library.similarArtists(artistID: artistID, limit: 3)
        XCTAssertEqual(similar.count, 3)
        XCTAssertFalse(similar.contains { $0.id == artistID })
        XCTAssertEqual(similar.first?.name, "Velvet Static")
    }

    func testFavorites() async throws {
        let tracks = try await library.favoriteTracks(limit: 500)
        XCTAssertEqual(Set(tracks.map(\.id)), Set(DemoCatalog.favoriteTrackIDs))
        XCTAssertTrue(tracks.allSatisfy(\.isFavorite))
        let albums = try await library.favoriteAlbums(limit: 500)
        XCTAssertEqual(Set(albums.map(\.id)), Set(DemoCatalog.favoriteAlbumIDs))
        let artists = try await library.favoriteArtists(limit: 500)
        XCTAssertEqual(Set(artists.map(\.id)), Set(DemoCatalog.favoriteArtistIDs))

        let trackID = DemoCatalog.track(album: 7, number: 3).id
        try await library.setFavorite(itemID: trackID, isFavorite: true)
        var liked = try await library.favoriteTracks(limit: 500)
        XCTAssertTrue(liked.contains { $0.id == trackID })
        try await library.setFavorite(itemID: trackID, isFavorite: false)
        liked = try await library.favoriteTracks(limit: 500)
        XCTAssertFalse(liked.contains { $0.id == trackID })

        do {
            try await library.setFavorite(itemID: "c0000000000000000000000000009999", isFavorite: true)
            XCTFail("an unknown item cannot be a favorite")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .notFound)
        }
    }

    func testGenres() async throws {
        let genres = try await library.genres()
        XCTAssertEqual(genres.map(\.name), ["Ambient", "Classical", "Electronic", "Folk", "Jazz", "Rock"])
        let jazz = try XCTUnwrap(genres.first { $0.name == "Jazz" })
        let tracks = try await library.tracks(inGenre: jazz.id)
        XCTAssertEqual(tracks.count, 10)
        XCTAssertTrue(tracks.allSatisfy { $0.artistName == "Kite & Compass Trio" })
    }

    func testLyrics() async throws {
        let synced = try await library.lyrics(forTrack: nightFerry.id)
        XCTAssertEqual(synced?.isSynced, true)
        XCTAssertEqual(synced?.lines.first?.text, "The last boat leaves at half past ten")
        XCTAssertEqual(synced?.lines.first?.start, 0.5)

        let plain = try await library.lyrics(forTrack: DemoCatalog.track(album: 9, number: 1).id)
        XCTAssertEqual(plain?.isSynced, false)
        XCTAssertEqual(plain?.lines.count, 4)

        let none = try await library.lyrics(forTrack: DemoCatalog.track(album: 7, number: 5).id)
        XCTAssertNil(none)
    }

    func testHomeShelves() async throws {
        let recentAlbums = try await library.recentlyAddedAlbums(limit: 5)
        XCTAssertEqual(recentAlbums.map(\.title), ["Nocturnes in Glass", "Night Ferry", "Afterglow Motel", "Tidal Rooms", "Études for Rain"])
        XCTAssertTrue(recentAlbums.allSatisfy { !$0.genres.isEmpty })

        let recentTracks = try await library.recentlyPlayedTracks(limit: 30)
        XCTAssertEqual(recentTracks.map(\.id), DemoCatalog.recentlyPlayed.map(\.trackID))

        let years = try await lookup.productionYears()
        XCTAssertEqual(years, DemoCatalog.albums.map(\.year).sorted())
    }

    func testSearch() async throws {
        let results = try await library.search(query: " night ", limit: 20)
        XCTAssertEqual(results.tracks.map(\.title).sorted(), ["Goodnight, Lighthouse", "Midnight Mileage", "Night Ferry"])
        XCTAssertEqual(results.albums.map(\.title), ["Night Ferry"])
        XCTAssertEqual(results.playlists.map(\.name), ["Keys After Midnight"])
        XCTAssertTrue(results.artists.isEmpty)

        // Case and diacritics do not matter.
        let folded = try await library.search(query: "etude", limit: 20)
        XCTAssertEqual(folded.tracks.count, 5)
        XCTAssertEqual(folded.albums.map(\.title), ["Études for Rain"])

        let artists = try await library.search(query: "velvet", limit: 20)
        XCTAssertEqual(artists.artists.map(\.name), ["Velvet Static"])
        XCTAssertEqual(artists.tracks.map(\.title), ["Velvet Rope Waltz"])

        let nothing = try await library.search(query: "zzzz", limit: 20)
        XCTAssertTrue(nothing.tracks.isEmpty && nothing.albums.isEmpty && nothing.artists.isEmpty && nothing.playlists.isEmpty)
    }

    func testTracksByIDsKeepOrderAndDropUnknown() async throws {
        let ids = [DemoCatalog.tracks[40].id, "c0000000000000000000000000009999", DemoCatalog.tracks[3].id, DemoCatalog.tracks[40].id]
        let tracks = try await library.tracks(byIDs: ids)
        XCTAssertEqual(tracks.map(\.id), [ids[0], ids[2], ids[0]])
    }

    func testPlaylistLifecycle() async throws {
        let initial = try await library.playlists()
        XCTAssertEqual(initial.map(\.name), ["Keys After Midnight", "Late Drive", "Sunday Morning, Slowly"])
        XCTAssertEqual(initial.first?.trackCount, 7)
        XCTAssertNotNil(initial.first?.imageTag)

        let seed = [DemoCatalog.tracks[0].id, DemoCatalog.tracks[1].id]
        let id = try await library.createPlaylist(name: "A+B Test", itemIDs: seed)
        var tracks = try await library.tracks(inPlaylist: id)
        XCTAssertEqual(tracks.map(\.id), seed)
        XCTAssertTrue(tracks.allSatisfy { $0.playlistEntryID != nil })

        // Adding a track that is already in keeps a single entry (10.10).
        try await library.addToPlaylist(playlistID: id, itemIDs: [DemoCatalog.tracks[2].id, DemoCatalog.tracks[0].id])
        tracks = try await library.tracks(inPlaylist: id)
        XCTAssertEqual(tracks.map(\.id), [DemoCatalog.tracks[0].id, DemoCatalog.tracks[1].id, DemoCatalog.tracks[2].id])

        let last = try XCTUnwrap(tracks.last?.playlistEntryID)
        try await library.movePlaylistItem(playlistID: id, entryID: last, toIndex: 0)
        tracks = try await library.tracks(inPlaylist: id)
        XCTAssertEqual(tracks.map(\.id), [DemoCatalog.tracks[2].id, DemoCatalog.tracks[0].id, DemoCatalog.tracks[1].id])

        let first = try XCTUnwrap(tracks.first?.playlistEntryID)
        try await library.movePlaylistItem(playlistID: id, entryID: first, toIndex: 2)
        tracks = try await library.tracks(inPlaylist: id)
        XCTAssertEqual(tracks.map(\.id), [DemoCatalog.tracks[0].id, DemoCatalog.tracks[1].id, DemoCatalog.tracks[2].id])

        try await library.removeFromPlaylist(playlistID: id, entryIDs: [try XCTUnwrap(tracks[1].playlistEntryID)])
        tracks = try await library.tracks(inPlaylist: id)
        XCTAssertEqual(tracks.count, 2)

        try await library.renamePlaylist(playlistID: id, name: "Renamed")
        let renamed = try await browser.playlist(id: id)
        XCTAssertEqual(renamed?.name, "Renamed")
        XCTAssertEqual(renamed?.trackCount, 2)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
        try await library.setPlaylistImage(playlistID: id, jpeg: jpeg)
        let image = backend.respond(to: DemoHTTPRequest(method: "GET", path: "Items/\(id)/Images/Primary"))
        XCTAssertEqual(image.status, 200)
        XCTAssertEqual(image.body, jpeg)
        XCTAssertEqual(image.headers["Content-Type"], "image/jpeg")

        let listed = try await library.playlists()
        XCTAssertEqual(listed.count, 4)
        try await library.deletePlaylist(playlistID: id)
        let afterDelete = try await library.playlists()
        XCTAssertEqual(afterDelete.count, 3)
        let gone = try await browser.playlist(id: id)
        XCTAssertNil(gone)
    }

    func testLibraryItemsCannotBeDeleted() async {
        do {
            try await library.deletePlaylist(playlistID: DemoCatalog.albums[0].id)
            XCTFail("the demo library is read-only")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .serverError(status: 403))
        }
    }

    // MARK: - LibraryBrowsing

    func testBrowsePages() async throws {
        let firstPage = try await browser.albumsPage(sort: AlbumSortOption.name.query(), filter: .none, startIndex: 0, limit: 5)
        XCTAssertEqual(firstPage.items.count, 5)
        XCTAssertEqual(firstPage.totalCount, 12)
        let secondPage = try await browser.albumsPage(sort: AlbumSortOption.name.query(), filter: .none, startIndex: 10, limit: 5)
        XCTAssertEqual(secondPage.items.count, 2)

        let newest = try await browser.albumsPage(sort: AlbumSortOption.recentlyAdded.query(), filter: .none, startIndex: 0, limit: 3)
        XCTAssertEqual(newest.items.map(\.title), ["Nocturnes in Glass", "Night Ferry", "Afterglow Motel"])

        let byYear = try await browser.albumsPage(sort: AlbumSortOption.year.query(), filter: .none, startIndex: 0, limit: 2)
        XCTAssertEqual(byYear.items.map(\.productionYear), [2024, 2023])

        let jazzID = try XCTUnwrap(DemoCatalog.genreID("Jazz"))
        let jazzAlbums = try await browser.albumsPage(sort: AlbumSortOption.name.query(), filter: BrowseFilter(genreID: jazzID), startIndex: 0, limit: 50)
        XCTAssertEqual(jazzAlbums.items.map(\.title), ["Blue Hour Sessions", "Second Set"])

        let favoriteAlbums = try await browser.albumsPage(sort: AlbumSortOption.name.query(), filter: BrowseFilter(favoritesOnly: true), startIndex: 0, limit: 50)
        XCTAssertEqual(favoriteAlbums.totalCount, DemoCatalog.favoriteAlbumIDs.count)

        let artists = try await browser.artistsPage(sort: ArtistSortOption.name.query(), filter: .none, startIndex: 0, limit: 4)
        XCTAssertEqual(artists.items.count, 4)
        XCTAssertEqual(artists.totalCount, 6)

        let songs = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: 0, limit: 25)
        XCTAssertEqual(songs.items.count, 25)
        XCTAssertEqual(songs.totalCount, 60)
        XCTAssertEqual(songs.items.first?.title, "A Field Guide to Fog")

        let mostPlayed = try await browser.tracksPage(sort: TrackSortOption.mostPlayed.query(), filter: .none, startIndex: 0, limit: 1)
        XCTAssertEqual(mostPlayed.items.first?.title, "Low Tide Lanterns")

        let found = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: BrowseFilter(searchTerm: "lighthouse"), startIndex: 0, limit: 25)
        XCTAssertEqual(found.items.map(\.title), ["Goodnight, Lighthouse"])

        let playlists = try await browser.playlistsPage(sort: PlaylistSortOption.name.query(), filter: .none, startIndex: 0, limit: 50)
        XCTAssertEqual(playlists.totalCount, 3)

        let genres = try await browser.genresPage(startIndex: 0, limit: 4)
        XCTAssertEqual(genres.items.count, 4)
        XCTAssertEqual(genres.totalCount, 6)

        let playlistTracks = try await browser.playlistTracksPage(playlistID: DemoCatalog.playlists[1].id, startIndex: 2, limit: 3)
        XCTAssertEqual(playlistTracks.items.map(\.id), Array(DemoCatalog.playlists[1].trackIDs[2..<5]))
        XCTAssertEqual(playlistTracks.totalCount, 9)

        let discography = try await browser.discography(artistID: DemoCatalog.artists[5].id)
        XCTAssertEqual(discography.map(\.title), ["Nocturnes in Glass", "Études for Rain"])
        let appearsOn = try await browser.appearsOn(artistID: DemoCatalog.artists[5].id)
        XCTAssertEqual(appearsOn.map(\.title), ["Night Ferry"])
    }

    func testRandomSortGivesDifferentOrders() async throws {
        let first = try await browser.albumsPage(sort: AlbumSortOption.random.query(), filter: .none, startIndex: 0, limit: 12)
        let second = try await browser.albumsPage(sort: AlbumSortOption.random.query(), filter: .none, startIndex: 0, limit: 12)
        XCTAssertEqual(Set(first.items.map(\.id)).count, 12)
        XCTAssertNotEqual(first.items.map(\.id), second.items.map(\.id))
    }

    func testAlphabetOffsets() async throws {
        // Albums starting before "N": Afterglow, Blue Hour, Chrome, Études, Letters, Loud.
        let albums = try await browser.alphabetOffset(of: "N", kind: .albums, filter: .none)
        XCTAssertEqual(albums, 6)
        let artists = try await browser.alphabetOffset(of: "N", kind: .artists, filter: .none)
        XCTAssertEqual(artists, 3)
        // Position in the title-sorted list, where "Étude …" files under E.
        let expected = DemoCatalog.tracks.filter { DemoBackend.fold($0.title) < "n" }.count
        let tracks = try await browser.alphabetOffset(of: "N", kind: .tracks, filter: .none)
        XCTAssertEqual(tracks, expected)
    }

    // MARK: - Lookup, mixes, reporting

    func testLookupResolvesMixedIDs() async throws {
        let albums = try await lookup.albums(byIDs: [DemoCatalog.albums[4].id, DemoCatalog.albums[1].id])
        XCTAssertEqual(albums.map(\.title), ["Letters to the Orchard", "Slow Weather"])
        let artists = try await lookup.artists(byIDs: [DemoCatalog.artists[2].id])
        XCTAssertEqual(artists.map(\.name), ["The Paper Lanterns"])
        let tracks = try await lookup.tracks(byIDs: DemoCatalog.mixes[0].trackIDs)
        XCTAssertEqual(tracks.map(\.id), DemoCatalog.mixes[0].trackIDs)

        let rock = try await lookup.randomTracks(genre: "Rock", limit: 6)
        XCTAssertEqual(rock.count, 6)
        XCTAssertTrue(rock.allSatisfy { $0.genres == ["Rock"] })
        let sixties = try await lookup.randomTracks(years: 1960...1969, limit: 50)
        XCTAssertEqual(sixties.count, 5)
        XCTAssertTrue(sixties.allSatisfy { $0.productionYear == 1962 })
    }

    func testInstantMixAndSimilar() async throws {
        let api = InstantMixAPI(session: session, transport: DemoTransport(backend: backend))
        let mix = try await api.instantMix(seedID: nightFerry.id, limit: 20)
        XCTAssertEqual(mix.count, 20)
        XCTAssertEqual(mix.first, nightFerry.id)
        XCTAssertEqual(Set(mix).count, 20)
        // The neighbours of an electronic track are mostly electronic and rock.
        let genres = mix.prefix(8).compactMap { id in DemoCatalog.tracks.first { $0.id == id }?.album.genre }
        XCTAssertGreaterThanOrEqual(genres.filter { ["Electronic", "Rock", "Jazz"].contains($0) }.count, 5, "\(genres)")

        let albumMix = try await api.instantMix(seedID: DemoCatalog.albums[0].id, limit: 10)
        XCTAssertEqual(albumMix.count, 10)
        let similarAlbums = try await api.similarItems(to: DemoCatalog.albums[0].id, limit: 5)
        XCTAssertEqual(similarAlbums.count, 5)
        XCTAssertEqual(similarAlbums.first, DemoCatalog.albums[1].id)
        let random = try await api.randomTracks(genre: "Folk", yearRange: nil, limit: 4)
        XCTAssertEqual(random.count, 4)
    }

    func testPlaybackReportsMoveATrackToTheTopOfRecentlyPlayed() async throws {
        let reporting = PlaybackReportingAPI(session: session, transport: DemoTransport(backend: backend))
        let track = DemoCatalog.track(album: 7, number: 4)
        try await reporting.send(.started(trackID: track.id, positionTicks: 0), playSessionID: "s")
        try await reporting.send(.progress(trackID: track.id, positionTicks: 10, isPaused: false), playSessionID: "s")
        try await reporting.send(.stopped(trackID: track.id, positionTicks: 20), playSessionID: "s")
        let recent = try await library.recentlyPlayedTracks(limit: 3)
        XCTAssertEqual(recent.first?.id, track.id)
    }

    // MARK: - Auth

    func testSignInFlowAgainstTheDemoServer() async throws {
        let transport = DemoTransport(backend: backend)
        let info = try await JellyfinServerDiscovery(transport: transport).probe(url: session.serverURL)
        XCTAssertEqual(info.name, DemoCatalog.serverName)
        XCTAssertEqual(info.version, DemoCatalog.serverVersion)

        let authenticator = JellyfinAuthenticator(transport: transport)
        let anonymous = JellyfinSession(serverURL: session.serverURL, deviceID: "tests")
        let quickConnect = await authenticator.isQuickConnectEnabled(session: anonymous)
        XCTAssertFalse(quickConnect)
        let result = try await authenticator.signIn(session: anonymous, username: "demo", password: "anything")
        XCTAssertEqual(result.userName, DemoCatalog.userName)
        XCTAssertEqual(result.session.userID, DemoCatalog.userID)
        XCTAssertEqual(result.session.accessToken, DemoCatalog.accessToken)

        let validity = await authenticator.validate(session: result.session)
        XCTAssertEqual(validity, .valid(userName: DemoCatalog.userName))
        await authenticator.logout(session: result.session)
    }

    func testRequestsWithoutTheTokenAreRejected() async throws {
        var stranger = session!
        stranger.accessToken = "someone-else"
        let api = MusicLibraryAPI(session: stranger, transport: DemoTransport(backend: backend))
        do {
            _ = try await api.albums()
            XCTFail("a wrong token must not see the library")
        } catch {
            XCTAssertEqual(error as? JellyfinError, .unauthorized)
        }
        let validity = await JellyfinAuthenticator(transport: DemoTransport(backend: backend)).validate(session: stranger)
        XCTAssertEqual(validity, .rejected)
    }

    // MARK: - Stream and image URLs

    func testStreamDownloadAndImageURLsAreServed() throws {
        let track = nightFerry
        for url in [
            StreamURLBuilder.url(for: track.id, request: .directPlay, session: session),
            StreamURLBuilder.downloadURL(for: track.id, session: session),
            StreamURLBuilder.progressiveURL(for: track.id, request: .directPlay, session: session),
        ] {
            let request = try XCTUnwrap(DemoTransport.demoRequest(from: URLRequest(url: url)))
            let response = backend.respond(to: request)
            XCTAssertEqual(response.status, 200, url.absoluteString)
            XCTAssertEqual(response.headers["Content-Type"], "audio/aac")
            XCTAssertEqual(response.headers["Accept-Ranges"], "bytes")
            XCTAssertEqual(response.body.count, DemoAudio.byteCount(of: track))
        }

        let imageURL = ImageURLBuilder.url(itemID: track.album.id, tag: nil, maxWidth: 96, session: session)
        let image = backend.respond(to: try XCTUnwrap(DemoTransport.demoRequest(from: URLRequest(url: imageURL))))
        XCTAssertEqual(image.status, 200)
        XCTAssertEqual(image.headers["Content-Type"], "image/png")
        XCTAssertTrue(image.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // Stream URLs carry the token in `api_key`; without it they are refused.
        let anonymous = backend.respond(to: DemoHTTPRequest(method: "GET", path: "Items/\(track.id)/File"))
        XCTAssertEqual(anonymous.status, 401)
    }
}
