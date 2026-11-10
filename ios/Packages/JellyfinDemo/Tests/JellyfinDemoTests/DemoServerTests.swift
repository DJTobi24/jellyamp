import XCTest
import JellyampCore
import JellyfinBackend
import SonicClient
@testable import JellyfinDemo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The loopback server end to end: real sockets, a real `URLSession` — the
/// way the app talks to it in demo mode.
final class DemoServerTests: XCTestCase {
    private var server: DemoHTTPServer!
    private var baseURL: URL!
    private var session: JellyfinSession!

    override func setUpWithError() throws {
        server = DemoHTTPServer(backend: DemoBackend())
        baseURL = try server.start()
        session = JellyfinSession(serverURL: baseURL, deviceID: "tests", accessToken: DemoCatalog.accessToken, userID: DemoCatalog.userID)
    }

    override func tearDown() {
        server.stop()
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await URLSessionTransport().send(request)
    }

    func testStartIsIdempotentAndStopReleasesThePort() throws {
        XCTAssertEqual(try server.start(), baseURL)
        XCTAssertEqual(baseURL.host, "127.0.0.1")
        XCTAssertNotNil(server.port)
        server.stop()
        XCTAssertNil(server.port)
        XCTAssertNil(server.baseURL)
        // Restartable (signing in to the demo again after signing out).
        let again = try server.start()
        XCTAssertNotNil(again.port)
    }

    func testOnboardingFlowOverHTTP() async throws {
        let info = try await JellyfinServerDiscovery().discover(address: "127.0.0.1:\(try XCTUnwrap(baseURL.port))")
        XCTAssertEqual(info.name, DemoCatalog.serverName)
        let anonymous = JellyfinSession(serverURL: info.url, deviceID: "tests")
        let result = try await JellyfinAuthenticator().signIn(session: anonymous, username: "demo", password: "demo")
        XCTAssertEqual(result.session.accessToken, DemoCatalog.accessToken)
    }

    func testLibraryCallsOverHTTP() async throws {
        // Default transports: URLSession against the socket.
        let library = MusicLibraryAPI(session: session)
        let albums = try await library.albums()
        XCTAssertEqual(albums.count, 12)
        let tracks = try await library.tracks(inAlbum: albums[0].id)
        XCTAssertEqual(tracks.count, 5)
        // Non-ASCII in both directions.
        let found = try await library.search(query: "Étude", limit: 10)
        XCTAssertEqual(found.tracks.count, 5)
        XCTAssertTrue(found.tracks.contains { $0.title == "Étude No. 4 “Petrichor”" })

        let playlistID = try await library.createPlaylist(name: "Über + Out", itemIDs: [tracks[0].id])
        let browser = LibraryBrowseAPI(session: session)
        let created = try await browser.playlist(id: playlistID)
        XCTAssertEqual(created?.name, "Über + Out")
        try await library.deletePlaylist(playlistID: playlistID)

        let lyrics = try await library.lyrics(forTrack: DemoCatalog.track(album: 2, number: 2).id)
        XCTAssertNotNil(lyrics)
    }

    func testManyParallelRequests() async throws {
        let library = MusicLibraryAPI(session: session)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for album in DemoCatalog.albums + DemoCatalog.albums {
                group.addTask { try await library.tracks(inAlbum: album.id).count }
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }
        XCTAssertEqual(counts, Array(repeating: 5, count: 24))
    }

    func testImagesOverHTTP() async throws {
        let url = ImageURLBuilder.url(itemID: DemoCatalog.albums[0].id, tag: "t", maxWidth: 200, session: session)
        let (data, response) = try await fetch(URLRequest(url: url))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let image = try PNGInspector(data)
        XCTAssertEqual(image.width, 200)

        let missing = ImageURLBuilder.url(itemID: "b0000000000000000000000000000999", tag: nil, maxWidth: 200, session: session)
        let (_, missingResponse) = try await fetch(URLRequest(url: missing))
        XCTAssertEqual(missingResponse.statusCode, 404)
    }

    func testAudioOverHTTPWithRanges() async throws {
        let track = DemoCatalog.track(album: 0, number: 1)
        let url = StreamURLBuilder.url(for: track.id, request: .directPlay, session: session)
        let total = DemoAudio.byteCount(of: track)

        let (whole, response) = try await fetch(URLRequest(url: url))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(whole.count, total)
        XCTAssertEqual(DemoAudio.adtsFrameCount(in: whole), track.loopCount * DemoAudio.framesPerLoop)

        // The player's size probe.
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (first, probeResponse) = try await fetch(probe)
        XCTAssertEqual(probeResponse.statusCode, 206)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(probeResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 0-0/\(total)")

        // The player's seek.
        var seek = URLRequest(url: url)
        seek.setValue("bytes=\(total / 2)-", forHTTPHeaderField: "Range")
        let (rest, seekResponse) = try await fetch(seek)
        XCTAssertEqual(seekResponse.statusCode, 206)
        XCTAssertEqual(rest, whole.subdata(in: (total / 2)..<total))

        var beyond = URLRequest(url: url)
        beyond.setValue("bytes=\(total + 10)-", forHTTPHeaderField: "Range")
        let (_, beyondResponse) = try await fetch(beyond)
        XCTAssertEqual(beyondResponse.statusCode, 416)

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (nothing, headResponse) = try await fetch(head)
        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Length"), String(total))
    }

    func testUnknownRoutesAndBadRequests() async throws {
        var request = session.request(path: "Nope/Nothing")
        let (_, response) = try await fetch(request)
        XCTAssertEqual(response.statusCode, 404)
        request = session.request(path: "Items", method: "PUT")
        let (_, wrongMethod) = try await fetch(request)
        XCTAssertEqual(wrongMethod.statusCode, 405)
    }

    // MARK: - Sonic API

    func testSonicClientAgainstTheDemoServer() async throws {
        let outcome = await SonicServerDiscovery().probe(baseURL: baseURL, apiKey: DemoCatalog.sonicAPIKey)
        guard case .available(let capabilities) = outcome else { return XCTFail("\(outcome)") }
        for capability in [SonicCapability.similar, .adventure, .mixes, .stations, .loudness] {
            XCTAssertTrue(capabilities.supports(capability), "\(capability)")
        }
        XCTAssertFalse(capabilities.supports(.sage))
        let wrongKey = await SonicServerDiscovery().probe(baseURL: baseURL, apiKey: "wrong")
        XCTAssertEqual(wrongKey, .unauthorized)

        let client = SonicAPIClient(baseURL: baseURL, apiKey: DemoCatalog.sonicAPIKey)
        let info = try await client.serverInfo()
        XCTAssertEqual(info.jellyfinServerID, DemoCatalog.serverID)

        let seed = DemoCatalog.track(album: 0, number: 1)
        let similar = try await client.similarTracks(to: seed.id, limit: 10)
        XCTAssertEqual(similar.count, 10)
        XCTAssertFalse(similar.contains { $0.itemID == seed.id })
        XCTAssertEqual(similar.map(\.distance), similar.map(\.distance).sorted())
        let elsewhere = try await client.similarTracks(to: seed.id, limit: 10, excludingSameAlbum: true)
        XCTAssertFalse(elsewhere.contains { item in DemoCatalog.tracks.first { $0.id == item.itemID }?.albumIndex == 0 })

        let artists = try await client.similarArtists(to: DemoCatalog.artists[0].id, limit: 3)
        XCTAssertEqual(artists.first?.itemID, DemoCatalog.artists[5].id, "classical is the nearest neighbour of ambient")
        let albums = try await client.similarAlbums(to: DemoCatalog.albums[0].id, limit: 3)
        XCTAssertEqual(albums.count, 3)

        let destination = DemoCatalog.track(album: 8, number: 2)
        let adventure = try await client.adventure(from: seed.id, to: destination.id, steps: 8)
        XCTAssertEqual(adventure.count, 10)
        XCTAssertEqual(adventure.first, seed.id)
        XCTAssertEqual(adventure.last, destination.id)
        XCTAssertEqual(Set(adventure).count, 10)

        let mixes = try await client.mixes(forUser: DemoCatalog.userID)
        XCTAssertEqual(mixes.count, DemoCatalog.mixes.count)
        XCTAssertEqual(mixes.first?.title, "Ambient Mix")
        XCTAssertTrue(mixes.allSatisfy { $0.itemIDs.count >= 10 })
        // Every mix resolves to tracks through Jellyfin.
        let resolved = try await LibraryLookupAPI(session: session).tracks(byIDs: mixes[1].itemIDs)
        XCTAssertEqual(resolved.count, mixes[1].itemIDs.count)

        let genre = try await client.station(type: .genre, seed: "jazz", count: 100)
        XCTAssertEqual(genre.count, 10)
        let decade = try await client.station(type: .decade, seed: "1990s", count: 100)
        XCTAssertEqual(decade.count, 5)
        let mood = try await client.station(type: .mood, seed: seed.id, count: 12)
        XCTAssertEqual(mood.count, 12)
        do {
            _ = try await client.station(type: .genre, seed: "Polka", count: 10)
            XCTFail("no polka in the demo")
        } catch {
            guard case SonicError.notFound = error else { return XCTFail("\(error)") }
        }

        let loudness = try await client.loudness(forTrack: seed.id)
        XCTAssertTrue((-21.0...(-13.0)).contains(loudness.integratedLufs))
        XCTAssertLessThan(loudness.truePeak, 0)
    }
}

/// Parsing of what arrives on the socket.
final class DemoHTTPWireTests: XCTestCase {
    private func parse(_ text: String) -> DemoHTTPWire.ParseResult {
        DemoHTTPWire.parse(Data(text.utf8))
    }

    func testParsesARequestWithQueryAndBody() {
        let raw = "POST /Playlists/abc/Items?ids=1%2C2&name=A+B%2BC&flag HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nX-Emby-Token: t\r\n\r\nhello"
        guard case .request(let request) = parse(raw) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "Playlists/abc/Items")
        XCTAssertEqual(request.parameter("IDS"), "1,2")
        XCTAssertEqual(request.parameter("name"), "A B+C")
        XCTAssertEqual(request.parameter("flag"), "")
        XCTAssertEqual(request.headers["x-emby-token"], "t")
        XCTAssertEqual(request.body, Data("hello".utf8))
        XCTAssertEqual(request.list("ids"), ["1", "2"])
    }

    func testWaitsForTheWholeRequest() {
        guard case .incomplete = parse("GET /Items HTTP/1.1\r\nHost: x\r\n") else { return XCTFail("headers are not finished") }
        guard case .incomplete = parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") else { return XCTFail("body is not finished") }
        guard case .request = parse("GET /Items HTTP/1.1\r\n\r\n") else { return XCTFail("complete request") }
    }

    func testRejectsMalformedRequests() {
        guard case .invalid = parse("NONSENSE\r\n\r\n") else { return XCTFail("no target") }
        guard case .invalid = parse("GET http://absolute/form HTTP/1.1\r\n\r\n") else { return XCTFail("absolute form") }
        guard case .invalid = parse("POST /x HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n") else { return XCTFail("huge body") }
        guard case .invalid = DemoHTTPWire.parse(Data(repeating: 65, count: DemoHTTPWire.headerLimit + 1)) else {
            return XCTFail("endless headers")
        }
    }

    func testRanges() {
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=0-0", length: 100), .some(.some(0...0)))
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=10-", length: 100), .some(.some(10...99)))
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=10-500", length: 100), .some(.some(10...99)))
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=-20", length: 100), .some(.some(80...99)))
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=100-", length: 100), .some(nil))
        XCTAssertEqual(DemoHTTPResponse.parseRange("items=1-2", length: 100), nil)
        XCTAssertEqual(DemoHTTPResponse.parseRange("bytes=1-2,5-6", length: 100), nil)

        let file = DemoHTTPResponse.file(Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), contentType: "audio/aac")
        let partial = file.applyingRange("bytes=2-4")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.body, Data([2, 3, 4]))
        XCTAssertEqual(partial.headers["Content-Range"], "bytes 2-4/10")
        XCTAssertEqual(file.applyingRange(nil).status, 200)
        // JSON is never sliced.
        XCTAssertEqual(DemoHTTPResponse.json(["a": 1]).applyingRange("bytes=0-0").status, 200)
    }

    func testResponseHead() {
        let head = String(decoding: DemoHTTPWire.head(for: .json(["a": 1])), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(head.contains("Connection: close\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
    }
}
