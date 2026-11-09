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
}
