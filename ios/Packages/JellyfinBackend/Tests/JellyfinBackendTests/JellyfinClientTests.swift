import XCTest
@testable import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Canned-response transport for the regression tests in this file: answers
/// by path substring (first match wins) with inline JSON and records what was
/// asked. Complements `StubTransport`, which serves fixture files.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        var method: String?
        var pathContains: String
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func on(_ pathContains: String, method: String? = nil, status: Int = 200, json: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, pathContains: pathContains, status: status, body: Data(json.utf8)))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let route: Route? = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            return routes.first {
                request.url!.path.contains($0.pathContains) && ($0.method == nil || $0.method == request.httpMethod)
            }
        }()
        guard let route else { throw JellyfinError.invalidResponse }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (route.body, response)
    }

    /// Decoded query of the n-th request.
    func query(_ index: Int = 0) -> [String: String] {
        let components = URLComponents(url: requests[index].url!, resolvingAgainstBaseURL: false)!
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    func jsonBody(_ index: Int = 0) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

let scriptedSession = JellyfinSession(
    serverURL: URL(string: "http://jellyfin.local:8096")!,
    deviceID: "device-1",
    accessToken: "token-abc-123",
    userID: "user-1"
)

func item(_ id: String, _ extra: String = "") -> String {
    "{\"Id\":\"\(id)\"\(extra.isEmpty ? "" : "," + extra)}"
}

func itemsJSON(_ items: [String]) -> String {
    "{\"Items\":[\(items.joined(separator: ","))],\"TotalRecordCount\":\(items.count)}"
}

func assertThrows(
    _ expected: JellyfinError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as JellyfinError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

final class JellyfinClientTests: XCTestCase {
    func testStatusCodesMapToTypedErrors() async {
        for (status, expected) in [
            (401, JellyfinError.unauthorized),
            (404, .notFound),
            (403, .serverError(status: 403)),
            (414, .serverError(status: 414)),
            (500, .serverError(status: 500)),
        ] {
            let transport = ScriptedTransport()
            transport.on("/", status: status)
            let library = MusicLibraryAPI(session: scriptedSession, transport: transport)
            let mix = InstantMixAPI(session: scriptedSession, transport: transport)
            // Reads, writes and the sibling APIs all report the same way.
            await assertThrows(expected) { _ = try await library.albums() }
            await assertThrows(expected) { try await library.addToPlaylist(playlistID: "p", itemIDs: ["a"]) }
            await assertThrows(expected) { try await library.deletePlaylist(playlistID: "p") }
            await assertThrows(expected) { _ = try await mix.instantMix(seedID: "s", limit: 5) }
            XCTAssertEqual(expected.httpStatus, status)
        }
        XCTAssertNil(JellyfinError.invalidResponse.httpStatus)
        XCTAssertNil(JellyfinError.notAuthenticated.httpStatus)
        XCTAssertNil(JellyfinError(httpStatus: 204))
    }

    func testUnauthorizedLyricsAreNotMistakenForMissingLyrics() async throws {
        let transport = ScriptedTransport()
        transport.on("Lyrics", status: 401)
        let api = LyricsAPI(session: scriptedSession, transport: transport)
        await assertThrows(.unauthorized) { _ = try await api.lyrics(forTrack: "t") }
    }

    func testOneMalformedItemDoesNotFailThePage() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: """
        {"Items":[
          {"Id":"a","Name":"Good","RunTimeTicks":10000000},
          {"Id":"b","Name":"Year as text","ProductionYear":"1999"},
          {"Name":"No id"},
          null,
          {"Id":"c","Name":null,"RunTimeTicks":null,"MediaSources":null,"UserData":null,"Genres":null,"ImageTags":null}
        ],"TotalRecordCount":5}
        """)
        let api = MusicLibraryAPI(session: scriptedSession, transport: transport)
        let tracks = try await api.tracks(inAlbum: "album")
        XCTAssertEqual(tracks.map(\.id), ["a", "c"])
        XCTAssertEqual(tracks[1].title, "")
        XCTAssertEqual(tracks[1].duration, 0)
        XCTAssertEqual(tracks[1].genres, [])
    }

    func testEnvelopeWithoutItemsIsAnEmptyPage() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: "{\"TotalRecordCount\":0}")
        let api = MusicLibraryAPI(session: scriptedSession, transport: transport)
        let albums = try await api.albums()
        XCTAssertEqual(albums, [])
    }

    func testGarbageBodyIsInvalidResponse() async {
        let transport = ScriptedTransport()
        transport.on("Items", json: "<html>captive portal</html>")
        let api = MusicLibraryAPI(session: scriptedSession, transport: transport)
        await assertThrows(.invalidResponse) { _ = try await api.albums() }
    }

    func testPlusSignsInQueryValuesArePercentEncoded() async throws {
        // Jellyfin decodes a literal "+" in the query as a space.
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([]))
        let api = MusicLibraryAPI(session: scriptedSession, transport: transport)
        _ = try await api.search(query: "AC+DC & Friends = 100%", limit: 5)
        XCTAssertEqual(transport.requests.count, 4)
        for request in transport.requests {
            let raw = request.url!.query!
            XCTAssertTrue(raw.contains("searchTerm=AC%2BDC%20%26%20Friends%20%3D%20100%25"), raw)
            XCTAssertFalse(raw.contains("+"))
        }
        XCTAssertEqual(transport.query(0)["searchTerm"], "AC+DC & Friends = 100%")
    }

    func testRequestsCarryTimeoutAuthAndUser() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([]))
        let api = MusicLibraryAPI(session: scriptedSession, transport: transport)
        _ = try await api.albums()
        let request = transport.requests[0]
        XCTAssertEqual(request.timeoutInterval, JellyfinClient.requestTimeout)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("Token=\"token-abc-123\""))
        XCTAssertEqual(transport.query()["userId"], "user-1")
        XCTAssertEqual(transport.query()["enableTotalRecordCount"], "false")
    }

    func testSignedOutSessionSendsNoEmptyUserID() async throws {
        let transport = ScriptedTransport()
        transport.on("Items", json: itemsJSON([]))
        let anonymous = JellyfinSession(serverURL: URL(string: "http://jellyfin.local:8096")!, deviceID: "d")
        _ = try await MusicLibraryAPI(session: anonymous, transport: transport).albums()
        XCTAssertNil(transport.query()["userId"])
    }

    func testBatchesAndIDComparison() {
        XCTAssertEqual(JellyfinClient.batches(of: [], size: 2), [])
        XCTAssertEqual(JellyfinClient.batches(of: ["a", "b", "c"], size: 2), [["a", "b"], ["c"]])
        XCTAssertTrue(JellyfinClient.sameID("D74E5264-CF6A-3AB5-22A0-FFEA1C91FDC3", "d74e5264cf6a3ab522a0ffea1c91fdc3"))
        XCTAssertFalse(JellyfinClient.sameID("a", "b"))
    }
}
