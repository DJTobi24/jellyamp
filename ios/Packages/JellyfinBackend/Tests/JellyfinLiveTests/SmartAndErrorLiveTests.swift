import XCTest
import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `InstantMixAPI`: what `JellyfinFallbackSonicProvider` runs on.
final class SmartLiveTests: LiveTestCase {
    private var mix: InstantMixAPI { InstantMixAPI(session: session) }
    private var trackIDs: Set<String> { Set(context.allTracks.map(\.id)) }

    private func titles(_ ids: [String]) -> [String] {
        ids.map { id in context.allTracks.first { $0.id == id }?.title ?? "?\(id)" }
    }

    func testInstantMixFromEveryKindOfSeed() async throws {
        let genres = try await library.genres()
        let electronic = try XCTUnwrap(genres.first { $0.name == "Electronic" })
        let seeds = [
            ("track", context.track("Power On").id),
            ("album", context.album("Voltage").id),
            ("artist", context.artist("Neon Circuit").id),
            ("genre", electronic.id),
        ]
        // Everything Electronic: the mix is metadata (genre) driven.
        let electronicTracks = Set(context.allTracks.filter { $0.genres == ["Electronic"] }.map(\.id))
        for (kind, seed) in seeds {
            let ids = try await mix.instantMix(seedID: seed, limit: 8)
            XCTAssertFalse(ids.isEmpty, kind)
            XCTAssertLessThanOrEqual(ids.count, 8, kind)
            // Regression: a track seed came back twice (once as the seed,
            // once as a result), and the server returned limit + 1 items.
            XCTAssertEqual(Set(ids).count, ids.count, "\(kind): duplicates in \(titles(ids))")
            XCTAssertTrue(Set(ids).isSubset(of: electronicTracks), "\(kind): \(titles(ids))")
        }
        // A track seed leads its own mix.
        let fromTrack = try await mix.instantMix(seedID: context.track("Power On").id, limit: 8)
        XCTAssertEqual(fromTrack.first, context.track("Power On").id)
        // More than there is: the whole genre, once.
        let everything = try await mix.instantMix(seedID: context.album("Voltage").id, limit: 100)
        XCTAssertEqual(Set(everything), electronicTracks)
        XCTAssertEqual(everything.count, electronicTracks.count)

        await assertThrowsJellyfinError(.notFound) {
            _ = try await self.mix.instantMix(seedID: Library.unknownID, limit: 5)
        }
    }

    func testSimilarItemsStayWithinTheSeedsKind() async throws {
        let voltage = context.album("Voltage")
        let albums = try await mix.similarItems(to: voltage.id, limit: 10)
        let albumIDs = Set(context.albums.values.map(\.id))
        XCTAssertFalse(albums.isEmpty)
        XCTAssertFalse(albums.contains(voltage.id))
        XCTAssertTrue(Set(albums).isSubset(of: albumIDs))
        // Same genre first: the other Electronic albums.
        XCTAssertEqual(Set(albums), [context.album("Afterimage").id, context.album("Jellyamp Sampler").id])

        let neon = context.artist("Neon Circuit")
        let artists = try await mix.similarItems(to: neon.id, limit: 10)
        XCTAssertFalse(artists.contains(neon.id))
        XCTAssertTrue(Set(artists).isSubset(of: Set(context.artists.values.map(\.id))))

        let track = context.track("Last Call")
        let tracks = try await mix.similarItems(to: track.id, limit: 3)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertFalse(tracks.contains(track.id))
        XCTAssertTrue(Set(tracks).isSubset(of: trackIDs))

        await assertThrowsJellyfinError(.notFound) {
            _ = try await self.mix.similarItems(to: Library.unknownID, limit: 5)
        }
    }

    func testRandomTracksByGenreAndYears() async throws {
        func ids(genre: String?, years: ClosedRange<Int>?) -> Set<String> {
            Set(Library.albums
                .filter { (genre == nil || $0.genre == genre) && (years == nil || years!.contains($0.year)) }
                .flatMap { context.tracksByAlbum[$0.title]!.map(\.id) })
        }
        let jazz = try await mix.randomTracks(genre: "Jazz", yearRange: nil, limit: 50)
        XCTAssertEqual(Set(jazz), ids(genre: "Jazz", years: nil))
        XCTAssertEqual(jazz.count, 6)

        let limited = try await mix.randomTracks(genre: "Jazz", yearRange: nil, limit: 4)
        XCTAssertEqual(limited.count, 4)
        XCTAssertTrue(Set(limited).isSubset(of: Set(jazz)))

        // A decade station: 1959…1968 has Kind of Late (1959) and Chamber Works (1962).
        let sixties = try await mix.randomTracks(genre: nil, yearRange: 1959...1968, limit: 50)
        XCTAssertEqual(Set(sixties), ids(genre: nil, years: 1959...1968))
        XCTAssertEqual(sixties.count, 7)
        let oneYear = try await mix.randomTracks(genre: nil, yearRange: 2016...2016, limit: 50)
        XCTAssertEqual(Set(oneYear), ids(genre: nil, years: 2016...2016))

        let both = try await mix.randomTracks(genre: "Jazz", yearRange: 2000...2020, limit: 50)
        XCTAssertEqual(Set(both), ids(genre: "Jazz", years: 2000...2020))
        XCTAssertEqual(both.count, 3)

        let unknownGenre = try await mix.randomTracks(genre: "Polka & Schlager+", yearRange: nil, limit: 50)
        XCTAssertEqual(unknownGenre, [])
        let emptyYears = try await mix.randomTracks(genre: nil, yearRange: 1900...1910, limit: 50)
        XCTAssertEqual(emptyYears, [])

        // No filter: the whole library, shuffled differently each time.
        var orders = Set<[String]>()
        for _ in 0..<4 {
            let all = try await mix.randomTracks(genre: nil, yearRange: nil, limit: 100)
            XCTAssertEqual(Set(all), trackIDs)
            XCTAssertEqual(all.count, Library.trackCount)
            orders.insert(all)
        }
        XCTAssertGreaterThan(orders.count, 1)
    }
}

/// Authentication and the typed errors.
final class ErrorLiveTests: LiveTestCase {
    func testWrongPasswordIsUnauthorized() async throws {
        let config = try XCTUnwrap(LiveConfig.current)
        let anonymous = JellyfinSession(serverURL: config.url, deviceID: "jellyamp-live-tests-\(UUID().uuidString)")
        await assertThrowsJellyfinError(.unauthorized) {
            _ = try await JellyfinAuthenticator().authenticateByName(
                session: anonymous, username: config.user, password: config.password + "-wrong")
        }
        await assertThrowsJellyfinError(.unauthorized) {
            _ = try await JellyfinAuthenticator().authenticateByName(
                session: anonymous, username: "nobody-\(UUID().uuidString)", password: "x")
        }
    }

    func testSignedInSessionLooksAsExpected() async throws {
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.userID?.count, 32)
        XCTAssertFalse(session.accessToken?.isEmpty ?? true)
        let me = try await raw("GET", "Users/Me")
        XCTAssertEqual(me.status, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: me.body) as? [String: Any])
        XCTAssertEqual(object["Id"] as? String, session.userID)
    }

    /// A revoked or expired token: every kind of call reports `.unauthorized`
    /// (HTTP 401), which is what session-expiry handling keys on.
    func testRevokedTokenIsUnauthorizedEverywhere() async throws {
        var revoked = session
        revoked.accessToken = "0123456789abcdef0123456789abcdef"
        let library = MusicLibraryAPI(session: revoked)
        let mix = InstantMixAPI(session: revoked)
        let album = context.album("Voltage")
        let track = context.track("Power On")

        await assertThrowsJellyfinError(.unauthorized, "albums") { _ = try await library.albums() }
        await assertThrowsJellyfinError(.unauthorized, "album") { _ = try await library.album(id: album.id) }
        await assertThrowsJellyfinError(.unauthorized, "artists") { _ = try await library.artists() }
        await assertThrowsJellyfinError(.unauthorized, "genres") { _ = try await library.genres() }
        await assertThrowsJellyfinError(.unauthorized, "latest") { _ = try await library.recentlyAddedAlbums() }
        await assertThrowsJellyfinError(.unauthorized, "search") { _ = try await library.search(query: "power") }
        await assertThrowsJellyfinError(.unauthorized, "byIDs") { _ = try await library.tracks(byIDs: [track.id]) }
        await assertThrowsJellyfinError(.unauthorized, "lyrics") { _ = try await library.lyrics(forTrack: track.id) }
        await assertThrowsJellyfinError(.unauthorized, "favorite") { try await library.setFavorite(itemID: track.id, isFavorite: true) }
        await assertThrowsJellyfinError(.unauthorized, "create") { _ = try await library.createPlaylist(name: "x", itemIDs: []) }
        await assertThrowsJellyfinError(.unauthorized, "playlist items") { _ = try await library.tracks(inPlaylist: album.id) }
        await assertThrowsJellyfinError(.unauthorized, "add") { try await library.addToPlaylist(playlistID: album.id, itemIDs: [track.id]) }
        await assertThrowsJellyfinError(.unauthorized, "delete") { try await library.deletePlaylist(playlistID: Library.unknownID) }
        await assertThrowsJellyfinError(.unauthorized, "mix") { _ = try await mix.instantMix(seedID: track.id, limit: 5) }
        await assertThrowsJellyfinError(.unauthorized, "similar") { _ = try await mix.similarItems(to: album.id, limit: 5) }
        await assertThrowsJellyfinError(.unauthorized, "random") { _ = try await mix.randomTracks(genre: nil, yearRange: nil, limit: 5) }
        XCTAssertEqual(JellyfinError.unauthorized.httpStatus, 401)

        // The real session is unaffected.
        let stillThere = try await self.library.album(id: album.id)
        XCTAssertNotNil(stillThere)
    }

    func testUnreachableServerIsATransportErrorNotAJellyfinError() async throws {
        // Port 9 (discard) is closed on the test hosts: connection refused.
        let nowhere = JellyfinSession(
            serverURL: URL(string: "http://127.0.0.1:9")!, deviceID: "d", accessToken: "t", userID: session.userID)
        do {
            _ = try await MusicLibraryAPI(session: nowhere).albums()
            XCTFail("expected a connection error")
        } catch is JellyfinError {
            XCTFail("a network failure must not look like a server answer")
        } catch {
            XCTAssertTrue(error is URLError, "\(type(of: error)): \(error)")
        }
    }

    func testServerURLWithPathPrefixAndTrailingSlash() async throws {
        // Reverse-proxied servers live under a base path; a trailing slash on
        // what the user typed must not double up.
        let config = try XCTUnwrap(LiveConfig.current)
        var slashed = session
        slashed.serverURL = try XCTUnwrap(URL(string: config.url.absoluteString.trimmingCharacters(in: ["/"]) + "/"))
        let albums = try await MusicLibraryAPI(session: slashed).albums()
        XCTAssertEqual(albums.count, Library.albums.count)
        let album = context.album("Voltage")
        let image = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: album.imageTag, maxWidth: 100, session: slashed))
        XCTAssertEqual(image.status, 200)
        let audio = try await fetch(
            StreamURLBuilder.url(for: context.track("Power On").id, request: .directPlay, session: slashed),
            headers: ["Range": "bytes=0-99"])
        XCTAssertEqual(audio.status, 206)
    }
}
