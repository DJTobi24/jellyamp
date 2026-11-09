import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers each request from a closure, so tests can serve different bodies
/// per chunk and inspect the queries.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (status: Int, body: String)

    init(handler: @escaping @Sendable (URLRequest) -> (status: Int, body: String)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let answer = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        return (Data(answer.body.utf8), response)
    }
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

private let lookupSession = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096")!,
    deviceID: "device-1",
    accessToken: "token-abc-123",
    userID: "user-1"
)

final class LibraryLookupAPITests: XCTestCase {
    func testAlbumsByIDsKeepRequestedOrderAndDropUnknown() async throws {
        // Jellyfin answers in library order, not in `ids` order.
        let transport = ScriptedTransport { _ in
            (200, """
            {"Items":[
              {"Id":"b","Name":"Bravo","Type":"MusicAlbum","AlbumArtists":[{"Name":"Band","Id":"artist1"}],"ChildCount":4,
               "ImageTags":{"Primary":"tag-b"}},
              {"Id":"a","Name":"Alpha","Type":"MusicAlbum","ProductionYear":1994}
            ],"TotalRecordCount":2}
            """)
        }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let albums = try await api.albums(byIDs: ["a", "missing", "b", "a"])

        XCTAssertEqual(albums.map(\.id), ["a", "b"])
        XCTAssertEqual(albums[1].artistID, "artist1")
        XCTAssertEqual(albums[1].trackCount, 4)
        XCTAssertEqual(albums[1].imageTag, "tag-b")
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertTrue(request.url!.path.hasSuffix("/Items"))
        XCTAssertEqual(queryValue("ids", in: request), "a,missing,b", "duplicate IDs are requested once")
        XCTAssertEqual(queryValue("userId", in: request), "user-1")
        XCTAssertTrue(queryValue("fields", in: request)?.contains("Genres") ?? false)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") ?? false)
    }

    func testArtistsByIDsMapArtistFields() async throws {
        let transport = ScriptedTransport { _ in
            (200, """
            {"Items":[{"Id":"ar1","Name":"Aurora Drift","Type":"MusicArtist","Genres":["Ambient"],
                       "UserData":{"IsFavorite":true},"ImageTags":{}}]}
            """)
        }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let artists = try await api.artists(byIDs: ["ar1"])
        XCTAssertEqual(artists, [Artist(id: "ar1", name: "Aurora Drift", genres: ["Ambient"], isFavorite: true)])
    }

    func testEmptyIDListMakesNoRequest() async throws {
        let transport = ScriptedTransport { _ in (500, "") }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let albums = try await api.albums(byIDs: [])
        let tracks = try await api.tracks(byIDs: ["", ""])
        XCTAssertTrue(albums.isEmpty)
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLongIDListsAreChunkedAndOrderSurvives() async throws {
        let ids = (0..<(LibraryLookupAPI.chunkSize * 2 + 5)).map { "t\($0)" }
        // Echo the requested chunk back reversed to prove reordering.
        let transport = ScriptedTransport { request in
            let chunk = (queryValue("ids", in: request) ?? "").split(separator: ",").reversed()
            let items = chunk.map { "{\"Id\":\"\($0)\",\"Name\":\"Song \($0)\",\"Type\":\"Audio\",\"RunTimeTicks\":10000000}" }
            return (200, "{\"Items\":[\(items.joined(separator: ","))]}")
        }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let tracks = try await api.tracks(byIDs: ids)

        XCTAssertEqual(tracks.map(\.id), ids)
        XCTAssertEqual(tracks.first?.duration ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(transport.requests.count, 3)
        let sizes = transport.requests.map { (queryValue("ids", in: $0) ?? "").split(separator: ",").count }
        XCTAssertEqual(sizes, [LibraryLookupAPI.chunkSize, LibraryLookupAPI.chunkSize, 5])
    }

    func testProductionYearsAreSortedAndDistinct() async throws {
        let transport = ScriptedTransport { _ in
            (200, #"{"Genres":["Jazz"],"Tags":[],"OfficialRatings":[],"Years":[2003,1959,2003,1994]}"#)
        }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let years = try await api.productionYears()
        XCTAssertEqual(years, [1959, 1994, 2003])
        let request = transport.requests[0]
        XCTAssertTrue(request.url!.path.hasSuffix("/Items/Filters"))
        XCTAssertEqual(queryValue("includeItemTypes", in: request), "Audio")
        XCTAssertEqual(queryValue("userId", in: request), "user-1")
    }

    func testProductionYearsTolerateMissingKey() async throws {
        let transport = ScriptedTransport { _ in (200, #"{"Genres":[]}"#) }
        let years = try await LibraryLookupAPI(session: lookupSession, transport: transport).productionYears()
        XCTAssertTrue(years.isEmpty)
    }

    func testRandomTracksBuildGenreAndYearQuery() async throws {
        let transport = ScriptedTransport { _ in
            (200, #"{"Items":[{"Id":"t1","Name":"Rain on Ninth","Type":"Audio","ProductionYear":1959,"Genres":["Jazz"]}]}"#)
        }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        let tracks = try await api.randomTracks(genre: "Jazz", years: 1950...1952, limit: 25)

        XCTAssertEqual(tracks.map(\.title), ["Rain on Ninth"])
        XCTAssertEqual(tracks.first?.productionYear, 1959)
        let request = transport.requests[0]
        XCTAssertEqual(queryValue("sortBy", in: request), "Random")
        XCTAssertEqual(queryValue("genres", in: request), "Jazz")
        XCTAssertEqual(queryValue("years", in: request), "1950,1951,1952")
        XCTAssertEqual(queryValue("limit", in: request), "25")
        XCTAssertEqual(queryValue("includeItemTypes", in: request), "Audio")
        XCTAssertTrue(queryValue("fields", in: request)?.contains("MediaSources") ?? false)
    }

    func testRandomTracksWithoutFiltersOmitThem() async throws {
        let transport = ScriptedTransport { _ in (200, #"{"Items":[]}"#) }
        _ = try await LibraryLookupAPI(session: lookupSession, transport: transport).randomTracks(limit: 10)
        XCTAssertNil(queryValue("genres", in: transport.requests[0]))
        XCTAssertNil(queryValue("years", in: transport.requests[0]))
    }

    func testErrorsMapToJellyfinError() async {
        let transport = ScriptedTransport { _ in (401, "") }
        let api = LibraryLookupAPI(session: lookupSession, transport: transport)
        do {
            _ = try await api.albums(byIDs: ["a"])
            XCTFail("expected unauthorized")
        } catch let error as JellyfinError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// Runs against a real Jellyfin server when `JELLYAMP_LIVE_JELLYFIN_URL`,
/// `JELLYAMP_LIVE_JELLYFIN_TOKEN` and `JELLYAMP_LIVE_JELLYFIN_USER_ID` are
/// set (see scripts/dev-jellyfin); skipped otherwise, so CI stays hermetic.
final class LibraryLookupAPILiveTests: XCTestCase {
    private func liveSession() throws -> JellyfinSession {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["JELLYAMP_LIVE_JELLYFIN_URL"], let url = URL(string: urlString),
              let token = environment["JELLYAMP_LIVE_JELLYFIN_TOKEN"],
              let userID = environment["JELLYAMP_LIVE_JELLYFIN_USER_ID"] else {
            throw XCTSkip("live Jellyfin server not configured")
        }
        return JellyfinSession(serverURL: url, deviceID: "jellyamp-tests", accessToken: token, userID: userID)
    }

    func testBatchedLookupsAgainstRealServer() async throws {
        let session = try liveSession()
        let library = MusicLibraryAPI(session: session)
        let lookup = LibraryLookupAPI(session: session)

        let someAlbums = try await library.albums(sortBy: "SortName", sortOrder: "Descending", startIndex: 0, limit: 4)
        try XCTSkipIf(someAlbums.isEmpty, "library is empty")
        let albumIDs = Array(someAlbums.map(\.id).reversed())
        let resolvedAlbums = try await lookup.albums(byIDs: albumIDs + ["00000000000000000000000000000000"])
        XCTAssertEqual(resolvedAlbums.map(\.id), albumIDs)
        XCTAssertEqual(Set(resolvedAlbums.map(\.title)), Set(someAlbums.map(\.title)))
        XCTAssertFalse(resolvedAlbums[0].artistName.isEmpty)

        let someArtists = try await library.artists(sortBy: "SortName", startIndex: 0, limit: 3)
        let artistIDs = Array(someArtists.map(\.id).reversed())
        let resolvedArtists = try await lookup.artists(byIDs: artistIDs)
        XCTAssertEqual(resolvedArtists.map(\.id), artistIDs)
        XCTAssertEqual(Set(resolvedArtists.map(\.name)), Set(someArtists.map(\.name)))

        let years = try await lookup.productionYears()
        XCTAssertFalse(years.isEmpty)
        XCTAssertEqual(years, years.sorted())

        let decade = Decade(containing: years[0])
        let fromDecade = try await lookup.randomTracks(years: decade.yearRange, limit: 50)
        XCTAssertFalse(fromDecade.isEmpty)
        XCTAssertTrue(fromDecade.allSatisfy { $0.productionYear.map(decade.yearRange.contains) ?? false })
        XCTAssertNotNil(fromDecade[0].container, "media sources must come back for playback decisions")

        let genres = try await library.genres()
        if let genre = genres.first {
            let fromGenre = try await lookup.randomTracks(genre: genre.name, limit: 50)
            XCTAssertFalse(fromGenre.isEmpty)
            XCTAssertTrue(fromGenre.allSatisfy { $0.genres.contains(genre.name) })
        }

        let anything = try await lookup.randomTracks(limit: 5)
        let trackIDs = anything.map(\.id)
        let resolvedTracks = try await lookup.tracks(byIDs: trackIDs)
        XCTAssertEqual(resolvedTracks.map(\.id), trackIDs)
    }
}
