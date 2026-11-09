import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Regression tests for what running against a real Jellyfin 10.10 server
/// turned up (`JellyfinLiveTests`, docs/JELLYFIN-API-NOTES.md). They pin the
/// request shapes and response handling so the fixes survive without a server.
final class ServerBehaviourTests: XCTestCase {
    private func api(_ transport: ScriptedTransport) -> MusicLibraryAPI {
        MusicLibraryAPI(session: scriptedSession, transport: transport)
    }

    // MARK: Fields

    func testListsAskForTheFieldsTheUIShows() async throws {
        let transport = ScriptedTransport()
        transport.on("Items/Latest", json: "[\(item("a", "\"ChildCount\":0,\"Genres\":[\"Jazz\"]"))]")
        transport.on("Artists/AlbumArtists", json: itemsJSON([item("x", "\"Genres\":[\"Jazz\"]")]))
        transport.on("Items", json: itemsJSON([item("a", "\"ChildCount\":7")]))
        let library = api(transport)

        let albums = try await library.albums()
        XCTAssertEqual(albums.first?.trackCount, 7)
        let artists = try await library.artists()
        XCTAssertEqual(artists.first?.genres, ["Jazz"])
        _ = try await library.favoriteArtists()
        _ = try await library.playlists()
        let latest = try await library.recentlyAddedAlbums()
        XCTAssertEqual(latest.first?.genres, ["Jazz"])
        // `/Items/Latest` says 0 for every album: unknown, not empty.
        XCTAssertNil(latest.first?.trackCount)

        for index in 0..<5 {
            let fields = transport.query(index)["fields"] ?? ""
            XCTAssertTrue(fields.contains("ChildCount"), "request \(index): \(fields)")
            XCTAssertTrue(fields.contains("Genres"), "request \(index): \(fields)")
            XCTAssertEqual(transport.query(index)["userId"], "user-1")
        }
    }

    // MARK: Appears on

    func testAppearsOnAsksForContributionsOnly() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([item("sampler", "\"Name\":\"Sampler\"")]))
        let albums = try await api(transport).appearsOnAlbums(artistID: "artist-1")
        XCTAssertEqual(albums.map(\.id), ["sampler"])
        let query = transport.query()
        XCTAssertEqual(query["contributingArtistIds"], "artist-1")
        // Real server: with excludeArtistIds=<same artist> the answer is always empty.
        XCTAssertNil(query["excludeArtistIds"])
        XCTAssertEqual(query["includeItemTypes"], "MusicAlbum")
        XCTAssertEqual(query["recursive"], "true")
    }

    // MARK: Lookups by ID

    func testItemLookupsIgnoreAnswersThatAreNotTheRequestedItem() async throws {
        // What 10.10 answers for `ids=not-a-guid`: the user's root folders.
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([
            item("7e64e319657a9516ec78490da03edccb", "\"Name\":\"Music\",\"Type\":\"CollectionFolder\""),
            item("1071671e7bffa0532e930debee501d2e", "\"Name\":\"Playlists\",\"Type\":\"ManualPlaylistsFolder\""),
        ]))
        let library = api(transport)
        let album = try await library.album(id: "not-a-guid")
        XCTAssertNil(album)
        let artist = try await library.artist(id: "not-a-guid")
        XCTAssertNil(artist)
        let empty = try await library.artist(id: "")
        XCTAssertNil(empty)
        XCTAssertEqual(transport.requests.count, 2, "an empty ID is not worth a request")
    }

    func testItemLookupsMatchIDAndType() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([
            item("d74e5264cf6a3ab522a0ffea1c91fdc3", "\"Name\":\"Voltage\",\"Type\":\"MusicAlbum\",\"ChildCount\":5"),
        ]))
        let library = api(transport)
        // Dashed/uppercase GUIDs are the same item.
        let album = try await library.album(id: "D74E5264-CF6A-3AB5-22A0-FFEA1C91FDC3")
        XCTAssertEqual(album?.title, "Voltage")
        XCTAssertEqual(album?.trackCount, 5)
        // An album is not an artist.
        let artist = try await library.artist(id: "d74e5264cf6a3ab522a0ffea1c91fdc3")
        XCTAssertNil(artist)
    }

    func testAlbumTracksAreQueriedByAlbumNotByFolderInDiscOrder() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([
            item("t1", "\"ParentIndexNumber\":1,\"IndexNumber\":1"),
            item("t2", "\"ParentIndexNumber\":2,\"IndexNumber\":1"),
        ]))
        let tracks = try await api(transport).tracks(inAlbum: "album-1")
        XCTAssertEqual(tracks.map(\.discNumber), [1, 2])
        let query = transport.query()
        XCTAssertEqual(query["albumIds"], "album-1")
        XCTAssertNil(query["parentId"], "an unknown parentId is a 400, and disc folders are not children of the album")
        XCTAssertEqual(query["recursive"], "true")
        XCTAssertEqual(query["sortBy"], "ParentIndexNumber,IndexNumber,SortName")
    }

    // MARK: URL length

    func testTracksByIDsAreFetchedInBatchesAndReassembledInOrder() async throws {
        let ids = (0..<250).map { "id-\($0)" }
        let transport = BatchEchoTransport()
        let library = MusicLibraryAPI(session: scriptedSession, transport: transport)
        // Reversed, with a duplicate and an unknown ID mixed in.
        let requested = Array(ids.reversed()) + ["id-7", "missing"]
        let tracks = try await library.tracks(byIDs: requested)
        XCTAssertEqual(tracks.map(\.id), Array(ids.reversed()) + ["id-7"])
        XCTAssertEqual(transport.batchSizes, [100, 100, 51], "250 distinct IDs + 1 unknown, 100 per request")
        XCTAssertTrue(transport.longestQuery < 4_000, "\(transport.longestQuery) bytes of query")

        let none = try await library.tracks(byIDs: [])
        XCTAssertEqual(none, [])
        XCTAssertEqual(transport.batchSizes.count, 3, "no request for no IDs")
    }

    func testCreatePlaylistSendsABodyNotAQuery() async throws {
        let transport = ScriptedTransport()
        transport.on("Playlists", json: "{\"Id\":\"new-playlist\"}")
        let ids = (0..<500).map { "id-\($0)" }
        let id = try await api(transport).createPlaylist(name: "Road Trip: A+B & C", itemIDs: ids)
        XCTAssertEqual(id, "new-playlist")
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = transport.jsonBody()
        XCTAssertEqual(body["Name"] as? String, "Road Trip: A+B & C")
        XCTAssertEqual(body["Ids"] as? [String], ids)
        XCTAssertEqual(body["UserId"] as? String, "user-1")
        XCTAssertEqual(body["MediaType"] as? String, "Audio")
    }

    func testPlaylistAddAndRemoveAreBatched() async throws {
        let transport = ScriptedTransport()
        transport.on("Playlists", status: 204)
        let library = api(transport)
        let ids = (0..<230).map { "id-\($0)" }
        try await library.addToPlaylist(playlistID: "p", itemIDs: ids)
        try await library.removeFromPlaylist(playlistID: "p", entryIDs: ids)
        try await library.addToPlaylist(playlistID: "p", itemIDs: [])
        try await library.removeFromPlaylist(playlistID: "p", entryIDs: [])
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "POST", "POST", "DELETE", "DELETE", "DELETE"])
        let added = (0..<3).flatMap { transport.query($0)["ids"]!.split(separator: ",").map(String.init) }
        XCTAssertEqual(added, ids)
        let removed = (3..<6).flatMap { transport.query($0)["entryIds"]!.split(separator: ",").map(String.init) }
        XCTAssertEqual(removed, ids)
        XCTAssertTrue(transport.requests.allSatisfy { ($0.url?.query?.count ?? 0) < 4_000 })
    }

    // MARK: Playlist reordering

    /// A playlist "p" whose entries are listed as `order` after the move call.
    private func playlistTransport(orderAfterMove order: [String], moveStatus: Int = 204) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.on("/Move/", method: "POST", status: moveStatus)
        transport.on("Playlists/p/Items", method: "GET", json: itemsJSON(order.map {
            item("item-\($0)", "\"PlaylistItemId\":\"entry-\($0)\"")
        }))
        transport.on("Playlists/p", method: "POST", status: 204)
        return transport
    }

    func testMoveIsLeftAloneWhenTheServerGotItRight() async throws {
        let transport = playlistTransport(orderAfterMove: ["c", "a", "b"])
        try await api(transport).movePlaylistItem(playlistID: "p", entryID: "entry-c", toIndex: 0)
        XCTAssertEqual(transport.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, [
            "POST /Playlists/p/Items/entry-c/Move/0",
            "GET /Playlists/p/Items",
        ])
        XCTAssertEqual(transport.query(1)["userId"], "user-1")
    }

    func testMoveIsRepairedWhenTheServerMisplacesTheEntry() async throws {
        // Jellyfin 10.10.7, asked to move the last of three entries to the
        // top, puts it second.
        let transport = playlistTransport(orderAfterMove: ["a", "c", "b"])
        try await api(transport).movePlaylistItem(playlistID: "p", entryID: "entry-c", toIndex: 0)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[2].httpMethod, "POST")
        XCTAssertEqual(transport.requests[2].url?.path, "/Playlists/p")
        XCTAssertEqual(transport.jsonBody(2)["Ids"] as? [String], ["item-c", "item-a", "item-b"])
    }

    func testMoveSurvivesTheServerCrashingOnAnIndexPastTheEnd() async throws {
        // 10.10 answers 500 (IndexOutOfRange) and moves nothing.
        let transport = playlistTransport(orderAfterMove: ["a", "b", "c"], moveStatus: 500)
        try await api(transport).movePlaylistItem(playlistID: "p", entryID: "entry-a", toIndex: 99)
        XCTAssertEqual(transport.jsonBody(2)["Ids"] as? [String], ["item-b", "item-c", "item-a"])
    }

    func testMoveOfAnEntryThatIsNotInThePlaylistIsNotFound() async throws {
        // 10.10 answers 500 (NullReference) for an unknown entry.
        let transport = playlistTransport(orderAfterMove: ["a", "b"], moveStatus: 500)
        await assertThrows(.notFound) {
            try await self.api(transport).movePlaylistItem(playlistID: "p", entryID: "entry-x", toIndex: 0)
        }
        XCTAssertEqual(transport.requests.count, 2, "nothing is rewritten")
    }

    func testMoveInAMissingPlaylistOrWithoutSessionStopsAtTheFirstAnswer() async throws {
        for (status, expected) in [(404, JellyfinError.notFound), (401, .unauthorized)] {
            let transport = playlistTransport(orderAfterMove: ["a", "b"], moveStatus: status)
            await assertThrows(expected) {
                try await self.api(transport).movePlaylistItem(playlistID: "p", entryID: "entry-a", toIndex: 1)
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    // MARK: Favorites

    func testFavoritesUseTheCurrentRoute() async throws {
        let transport = ScriptedTransport()
        transport.on("UserFavoriteItems", json: "{\"IsFavorite\":true}")
        let library = api(transport)
        try await library.setFavorite(itemID: "track-1", isFavorite: true)
        try await library.setFavorite(itemID: "track-1", isFavorite: false)
        XCTAssertEqual(transport.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, [
            "POST /UserFavoriteItems/track-1",
            "DELETE /UserFavoriteItems/track-1",
        ])
        XCTAssertEqual(transport.query(0)["userId"], "user-1")
    }

    func testFavoritesFallBackToTheLegacyRouteOnOldServers() async throws {
        let transport = ScriptedTransport()
        transport.on("UserFavoriteItems", status: 404)
        transport.on("Users/user-1/FavoriteItems", json: "{\"IsFavorite\":true}")
        try await api(transport).setFavorite(itemID: "track-1", isFavorite: true)
        XCTAssertEqual(transport.requests.last?.url?.path, "/Users/user-1/FavoriteItems/track-1")
        XCTAssertEqual(transport.requests.last?.httpMethod, "POST")

        // A missing item is a 404 on both routes.
        let missing = ScriptedTransport()
        missing.on("FavoriteItems", status: 404)
        await assertThrows(.notFound) {
            try await self.api(missing).setFavorite(itemID: "gone", isFavorite: true)
        }
        // Other failures are not retried on the legacy route.
        let expired = ScriptedTransport()
        expired.on("FavoriteItems", status: 401)
        await assertThrows(.unauthorized) {
            try await self.api(expired).setFavorite(itemID: "track-1", isFavorite: false)
        }
        XCTAssertEqual(expired.requests.count, 1)
    }

    // MARK: Search

    func testSearchTrimsTheTermAndSkipsEmptySearches() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([item("a", "\"Name\":\"Power On\",\"ChildCount\":3")]))
        let library = api(transport)
        let result = try await library.search(query: "  power on \n", limit: 7)
        XCTAssertEqual(result.tracks.map(\.title), ["Power On"])
        XCTAssertEqual(result.playlists.first?.trackCount, 3)
        XCTAssertEqual(transport.requests.count, 4)
        var kinds = Set<String>()
        for index in 0..<4 {
            XCTAssertEqual(transport.query(index)["searchTerm"], "power on")
            XCTAssertEqual(transport.query(index)["limit"], "7")
            XCTAssertEqual(transport.query(index)["recursive"], "true")
            kinds.insert(transport.query(index)["includeItemTypes"] ?? "")
        }
        XCTAssertEqual(kinds, ["Audio", "MusicAlbum", "MusicArtist", "Playlist"])

        let nothing = try await library.search(query: " \t ", limit: 7)
        XCTAssertTrue(nothing.tracks.isEmpty && nothing.albums.isEmpty && nothing.artists.isEmpty && nothing.playlists.isEmpty)
        XCTAssertEqual(transport.requests.count, 4, "a blank term is not sent")
    }

    // MARK: Instant mix / similar

    func testInstantMixIsDistinctAndWithinTheLimit() async throws {
        // 10.10 for a track seed with limit=3: seed, then a mix containing
        // the seed again, four items in total.
        let transport = ScriptedTransport()
        transport.on("InstantMix", json: itemsJSON([item("seed"), item("a"), item("seed"), item("b")]))
        let mix = InstantMixAPI(session: scriptedSession, transport: transport)
        let ids = try await mix.instantMix(seedID: "seed", limit: 3)
        XCTAssertEqual(ids, ["seed", "a", "b"])
        XCTAssertEqual(transport.requests[0].url?.path, "/Items/seed/InstantMix")
        XCTAssertEqual(transport.query()["limit"], "3")
        XCTAssertEqual(transport.query()["userId"], "user-1")
        XCTAssertEqual(transport.query()["enableUserData"], "false")
    }

    func testSimilarNeverContainsTheSeed() async throws {
        let transport = ScriptedTransport()
        transport.on("Similar", json: itemsJSON([
            item("b", "\"Type\":\"MusicArtist\",\"Name\":\"B\""),
            item("seed", "\"Type\":\"MusicArtist\""),
            item("album", "\"Type\":\"MusicAlbum\""),
            item("b", "\"Type\":\"MusicArtist\""),
        ]))
        let ids = try await InstantMixAPI(session: scriptedSession, transport: transport).similarItems(to: "seed", limit: 5)
        XCTAssertEqual(ids, ["b", "album"])
        let artists = try await api(transport).similarArtists(artistID: "seed", limit: 5)
        XCTAssertEqual(artists.map(\.name), ["B", ""], "artists only, seed excluded")
    }

    func testRandomTracksSpellOutTheYears() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([item("a"), item("b")]))
        let mix = InstantMixAPI(session: scriptedSession, transport: transport)
        let ids = try await mix.randomTracks(genre: "Drum & Bass", yearRange: 1990...1993, limit: 25)
        XCTAssertEqual(ids, ["a", "b"])
        let query = transport.query()
        XCTAssertEqual(query["years"], "1990,1991,1992,1993")
        XCTAssertEqual(query["genres"], "Drum & Bass")
        XCTAssertEqual(query["sortBy"], "Random")
        XCTAssertEqual(query["includeItemTypes"], "Audio")
        XCTAssertEqual(query["recursive"], "true")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertTrue(transport.requests[0].url!.query!.contains("genres=Drum%20%26%20Bass"))
    }
}
