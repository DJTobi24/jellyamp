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
}
