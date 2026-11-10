import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Always answers with the same two albums out of "500".
private final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        count += 1
        lock.unlock()
        let body = #"{"Items":[{"Id":"a1","Name":"One","Type":"MusicAlbum"},{"Id":"a2","Name":"Two","Type":"MusicAlbum"}],"TotalRecordCount":500}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// `sortBy=Random` cannot be paged (a new order per request); the browse API
/// must hand the list machinery exactly one page.
final class RandomPagingTests: XCTestCase {
    private let session = JellyfinSession(
        serverURL: URL(string: "http://jellyfin.local:8096")!,
        deviceID: "device-1",
        accessToken: "token",
        userID: "user-1"
    )

    func testRandomListIsASinglePage() async throws {
        let transport = CountingTransport()
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let random = AlbumSortOption.random.query()

        let first = try await api.albumsPage(sort: random, filter: .none, startIndex: 0, limit: 2)
        XCTAssertEqual(first.items.map(\.id), ["a1", "a2"])
        // Not the server's 500: the sample is the whole list.
        XCTAssertEqual(first.totalCount, 2)

        let second = try await api.albumsPage(sort: random, filter: .none, startIndex: 2, limit: 2)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(transport.requestCount, 1, "no request for a second random page")
    }

    func testListStateStopsAfterTheRandomPage() async throws {
        let api = LibraryBrowseAPI(session: session, transport: CountingTransport())
        var state = PagedListState<Album>(pageSize: 2)
        let request = state.beginReload(fromOffset: 0, keepingItems: false)
        let page = try await api.albumsPage(sort: AlbumSortOption.random.query(), filter: .none, startIndex: request.startIndex, limit: request.limit)
        XCTAssertTrue(state.receive(page, for: request))
        XCTAssertNil(state.beginNextPage(), "a random list has no next page")
    }

    func testOtherSortsStillPage() async throws {
        let transport = CountingTransport()
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let byName = AlbumSortOption.name.query()
        let first = try await api.albumsPage(sort: byName, filter: .none, startIndex: 0, limit: 2)
        XCTAssertEqual(first.totalCount, 500)
        _ = try await api.albumsPage(sort: byName, filter: .none, startIndex: 2, limit: 2)
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testAllListKindsTreatRandomAlike() async throws {
        let transport = CountingTransport()
        let api = LibraryBrowseAPI(session: session, transport: transport)
        let artists = try await api.artistsPage(sort: ArtistSortOption.random.query(), filter: .none, startIndex: 50, limit: 50)
        let tracks = try await api.tracksPage(sort: TrackSortOption.random.query(), filter: .none, startIndex: 50, limit: 50)
        XCTAssertTrue(artists.items.isEmpty)
        XCTAssertTrue(tracks.items.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)
    }
}
