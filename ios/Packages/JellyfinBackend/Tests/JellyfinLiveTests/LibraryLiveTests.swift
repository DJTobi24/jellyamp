import XCTest
import JellyfinBackend
import JellyampCore

/// Browsing: albums, artists, tracks, genres and the model mapping.
final class LibraryLiveTests: LiveTestCase {
    // MARK: Albums

    func testAlbumsListTheWholeLibraryWithAllFields() async throws {
        let albums = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 100)
        XCTAssertEqual(albums.titles, Library.albums.map(\.title).sorted())
        for album in albums {
            let spec = Library.spec(album.title)
            XCTAssertEqual(album.artistName, spec.artist, album.title)
            XCTAssertEqual(album.artistID, context.artist(spec.artist).id, album.title)
            XCTAssertEqual(album.productionYear, spec.year, album.title)
            XCTAssertEqual(album.genres, [spec.genre], album.title)
            // Regression: `ChildCount` is only sent when asked for via `fields=`.
            XCTAssertEqual(album.trackCount, spec.tracks.count, album.title)
            XCTAssertEqual(album.duration ?? 0, Library.trackSeconds * Double(spec.tracks.count), accuracy: 1, album.title)
            XCTAssertNotNil(album.imageTag, album.title)
            XCTAssertFalse(album.id.isEmpty)
        }
    }

    func testAlbumPagingIsStableAndEndsWithAnEmptyPage() async throws {
        let all = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 100)
        var paged: [Album] = []
        for start in stride(from: 0, to: 12, by: 4) {
            let page = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: start, limit: 4)
            XCTAssertLessThanOrEqual(page.count, 4)
            paged += page
        }
        XCTAssertEqual(paged.map(\.id), all.map(\.id))
        let beyond = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 50, limit: 4)
        XCTAssertEqual(beyond, [])
    }

    /// Every `sortBy`/`sortOrder` pair `AlbumSort` in LibraryView sends.
    func testEveryAlbumSortTheAppUses() async throws {
        func titles(_ sortBy: String, _ order: String) async throws -> [String] {
            try await library.albums(sortBy: sortBy, sortOrder: order, startIndex: 0, limit: 100).titles
        }
        let byName = Library.albums.map(\.title).sorted()
        let byNameAscending = try await titles("SortName", "Ascending")
        XCTAssertEqual(byNameAscending, byName)
        let byNameDescending = try await titles("SortName", "Descending")
        XCTAssertEqual(byNameDescending, byName.reversed())

        let byYear = Library.albums.sorted { $0.year < $1.year }.map(\.title)
        let byYearDescending = try await titles("ProductionYear", "Descending")
        XCTAssertEqual(byYearDescending, byYear.reversed())
        let byYearAscending = try await titles("ProductionYear", "Ascending")
        XCTAssertEqual(byYearAscending, byYear)

        // "Recently added" = file creation order = generation order.
        let recentlyAdded = try await titles("DateCreated", "Descending")
        XCTAssertEqual(recentlyAdded, Library.albums.map(\.title).reversed())

        // Two sort keys, comma-joined: by album artist, then by album name.
        let byArtist = try await library.albums(sortBy: "AlbumArtist,SortName", sortOrder: "Ascending", startIndex: 0, limit: 100)
        XCTAssertEqual(Set(byArtist.titles), Set(byName))
        var seenArtists: [String] = []
        for album in byArtist where seenArtists.last != album.artistName {
            XCTAssertFalse(seenArtists.contains(album.artistName), "albums of \(album.artistName) are not adjacent")
            seenArtists.append(album.artistName)
        }
        for artist in seenArtists {
            let ofArtist = byArtist.filter { $0.artistName == artist }.titles
            XCTAssertEqual(ofArtist, ofArtist.sorted(), artist)
        }

        // Random: the same albums, in an order that changes between calls.
        var orders = Set<[String]>()
        for _ in 0..<5 {
            let shuffled = try await titles("Random", "Ascending")
            XCTAssertEqual(shuffled.sorted(), byName)
            orders.insert(shuffled)
        }
        XCTAssertGreaterThan(orders.count, 1, "Random returned the same order five times")
    }

    func testAlbumDetail() async throws {
        let listed = context.album("Voltage")
        let fetched = try await library.album(id: listed.id)
        let album = try XCTUnwrap(fetched)
        XCTAssertEqual(album.id, listed.id)
        XCTAssertEqual(album.title, "Voltage")
        XCTAssertEqual(album.artistName, "Neon Circuit")
        XCTAssertEqual(album.artistID, context.artist("Neon Circuit").id)
        XCTAssertEqual(album.productionYear, 2016)
        XCTAssertEqual(album.genres, ["Electronic"])
        XCTAssertEqual(album.trackCount, 5)
        XCTAssertEqual(album.imageTag, listed.imageTag)

        let unknown = try await library.album(id: Library.unknownID)
        XCTAssertNil(unknown)
        let notAnAlbum = try await library.album(id: context.track("Power On").id)
        XCTAssertNil(notAnAlbum, "a track ID is not an album")
        // Regression: Jellyfin ignores an `ids` value it cannot parse and
        // answers with the user's root folders instead.
        let garbage = try await library.album(id: "not-a-guid")
        XCTAssertNil(garbage)
    }

    func testTracksInAlbumComeInTrackOrder() async throws {
        for spec in Library.albums {
            let album = context.album(spec.title)
            let tracks = try await library.tracks(inAlbum: album.id)
            XCTAssertEqual(tracks.titles, spec.tracks, spec.title)
            XCTAssertEqual(tracks.map(\.indexNumber), Array(1...spec.tracks.count), spec.title)
            for track in tracks {
                XCTAssertEqual(track.albumID, album.id, track.title)
                XCTAssertEqual(track.albumName, spec.title, track.title)
            }
        }
        let unknown = try await library.tracks(inAlbum: Library.unknownID)
        XCTAssertEqual(unknown, [])
    }

    // MARK: Track model

    func testTrackModelMappingForEveryCodec() async throws {
        XCTAssertEqual(context.allTracks.count, Library.trackCount)
        XCTAssertEqual(Set(context.allTracks.map(\.id)).count, Library.trackCount)
        for spec in Library.albums {
            let album = context.album(spec.title)
            for track in context.tracksByAlbum[spec.title] ?? [] {
                let label = "\(spec.title) / \(track.title)"
                XCTAssertEqual(track.duration, Library.trackSeconds, accuracy: 0.5, label)
                XCTAssertEqual(track.container, spec.container, label)
                XCTAssertEqual(track.codec, spec.codec, label)
                XCTAssertEqual(track.sampleRate, 44_100, label)
                XCTAssertGreaterThan(track.bitrate ?? 0, 0, label)
                XCTAssertEqual(track.genres, [spec.genre], label)
                XCTAssertEqual(track.productionYear, spec.year, label)
                XCTAssertEqual(track.albumID, album.id, label)
                XCTAssertEqual(track.albumName, spec.title, label)
                // The compilation credits each track to its own artist.
                let artist = Library.samplerTrackArtists[track.title] ?? spec.artist
                XCTAssertEqual(track.artistName, artist, label)
                XCTAssertEqual(track.artistID, context.artist(artist).id, label)
                // Tracks carry no art of their own: the tag falls back to the album's.
                XCTAssertEqual(track.imageTag, album.imageTag, label)
                XCTAssertNotNil(track.imageTag, label)
                XCTAssertNil(track.playlistEntryID, label)
            }
        }
        // Codec-specific details.
        let mp3 = context.track("Power On")
        XCTAssertEqual(Double(mp3.bitrate ?? 0), 192_000, accuracy: 10_000)
        let flac = context.track("Allegro in D")
        XCTAssertNotNil(flac.bitDepth)
        let aac = context.track("Phosphor")
        XCTAssertEqual(Double(aac.bitrate ?? 0), 192_000, accuracy: 20_000)
    }

    /// `NormalizationGain` needs the library's LUFS scan plus the "Audio
    /// Normalization" task (up.sh runs both); see docs/JELLYFIN-API-NOTES.md.
    func testLoudnessGainIsMappedForTracksAndAlbums() async throws {
        for track in context.allTracks {
            let gain = try XCTUnwrap(track.normalizationGainDB, "no NormalizationGain for \(track.title) — did the LUFS scan run?")
            XCTAssertTrue((-40...40).contains(gain), "\(track.title): \(gain) dB")
        }
        for album in context.albums.values {
            let gain = try XCTUnwrap(album.normalizationGainDB, "no NormalizationGain for album \(album.title)")
            XCTAssertTrue((-40...40).contains(gain), "\(album.title): \(gain) dB")
        }
        // Not all the same number: the gain is measured, not a default.
        XCTAssertGreaterThan(Set(context.albums.values.compactMap(\.normalizationGainDB)).count, 1)
        // The single-item fetches carry it too.
        let voltage = try await library.album(id: context.album("Voltage").id)
        XCTAssertEqual(voltage?.normalizationGainDB, context.album("Voltage").normalizationGainDB)
        let byID = try await library.tracks(byIDs: [context.track("Scherzo").id])
        XCTAssertEqual(byID.first?.normalizationGainDB, context.track("Scherzo").normalizationGainDB)
    }

    // MARK: Artists

    func testArtistsListPagingAndSorts() async throws {
        let artists = try await library.artists(sortBy: "SortName", startIndex: 0, limit: 100)
        XCTAssertEqual(Set(artists.map(\.name)), Library.albumArtists)
        XCTAssertEqual(artists.count, Library.albumArtists.count)
        // Jellyfin's sort name drops the leading article: "The Granite Saints" sorts under G.
        XCTAssertEqual(artists.map(\.name), [
            "Aurora Drift", "Blue Hour Trio", "The Granite Saints", "Halden Quartet", "Neon Circuit", "Various Artists",
        ])
        for artist in artists {
            // Regression: `/Artists/AlbumArtists` omits `Genres` unless asked.
            let genres = Set(Library.albums.filter { $0.artist == artist.name }.map(\.genre))
            XCTAssertEqual(Set(artist.genres), genres, artist.name)
        }

        var paged: [Artist] = []
        for start in stride(from: 0, to: 8, by: 4) {
            paged += try await library.artists(sortBy: "SortName", startIndex: start, limit: 4)
        }
        XCTAssertEqual(paged.map(\.id), artists.map(\.id))

        // The artist grid's other sort option.
        var orders = Set<[String]>()
        for _ in 0..<5 {
            let shuffled = try await library.artists(sortBy: "Random", startIndex: 0, limit: 100).map(\.name)
            XCTAssertEqual(Set(shuffled), Library.albumArtists)
            orders.insert(shuffled)
        }
        XCTAssertGreaterThan(orders.count, 1, "Random returned the same order five times")
    }

    func testArtistDetail() async throws {
        let listed = context.artist("Neon Circuit")
        let fetched = try await library.artist(id: listed.id)
        let artist = try XCTUnwrap(fetched)
        XCTAssertEqual(artist.id, listed.id)
        XCTAssertEqual(artist.name, "Neon Circuit")
        XCTAssertEqual(artist.genres, ["Electronic"])
        // `overview` stays nil here: the made-up artists have no biography.
        // The mapping of a present `Overview` is covered by the unit tests.

        let unknown = try await library.artist(id: Library.unknownID)
        XCTAssertNil(unknown)
        // Regression: an unparsable ID used to come back as the "Music"
        // library folder dressed up as an artist.
        let garbage = try await library.artist(id: "not-a-guid")
        XCTAssertNil(garbage)
        let empty = try await library.artist(id: "")
        XCTAssertNil(empty)
    }

    func testAlbumsByArtistNewestFirstWithoutCompilations() async throws {
        let albums = try await library.albums(byArtist: context.artist("Neon Circuit").id)
        XCTAssertEqual(albums.titles, ["Afterimage", "Voltage"])
        XCTAssertEqual(albums.map(\.trackCount), [3, 5])
        let trio = try await library.albums(byArtist: context.artist("Blue Hour Trio").id)
        XCTAssertEqual(trio.titles, ["Live at the Cellar", "Kind of Late"])
        let unknown = try await library.albums(byArtist: Library.unknownID)
        XCTAssertEqual(unknown, [])
    }

    func testAppearsOnFindsTheCompilation() async throws {
        // Regression: this returned nothing at all on a real server.
        for name in ["Neon Circuit", "Aurora Drift"] {
            let albums = try await library.appearsOnAlbums(artistID: context.artist(name).id)
            XCTAssertEqual(albums.titles, ["Jellyamp Sampler"], name)
            XCTAssertEqual(albums.first?.artistName, "Various Artists")
        }
        let none = try await library.appearsOnAlbums(artistID: context.artist("Halden Quartet").id)
        XCTAssertEqual(none, [])
        // The compilation's own album artist does not "appear on" it.
        let various = try await library.appearsOnAlbums(artistID: context.artist("Various Artists").id)
        XCTAssertEqual(various, [])
    }

    func testTracksByArtistIncludeGuestSpots() async throws {
        let tracks = try await library.tracks(byArtist: context.artist("Neon Circuit").id)
        XCTAssertEqual(tracks.titles, [
            "Phosphor", "Persistence", "Scanline",  // Afterimage
            "Sampler Outro",  // Jellyamp Sampler
            "Power On", "Gridlock", "Arc Flash", "Standby", "Overclock",  // Voltage
        ])
        XCTAssertTrue(tracks.allSatisfy { $0.artistName == "Neon Circuit" })
        XCTAssertTrue(tracks.allSatisfy { $0.codec != nil }, "media sources are requested")
    }

    func testTopTracksStayWithinTheArtistAndLimit() async throws {
        let artist = context.artist("The Granite Saints")
        let top = try await library.topTracks(byArtist: artist.id, limit: 5)
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(Set(top.map(\.id)).count, 5)
        XCTAssertTrue(top.allSatisfy { $0.artistID == artist.id })
        let two = try await library.topTracks(byArtist: artist.id, limit: 2)
        XCTAssertEqual(two.count, 2)
    }

    func testSimilarArtistsAreOtherArtists() async throws {
        let known = Set(context.artists.values.map(\.id))
        for name in ["Neon Circuit", "Blue Hour Trio"] {
            let seed = context.artist(name)
            let similar = try await library.similarArtists(artistID: seed.id, limit: 12)
            XCTAssertLessThanOrEqual(similar.count, 12)
            XCTAssertFalse(similar.contains { $0.id == seed.id }, "\(name) is similar to itself")
            XCTAssertTrue(similar.allSatisfy { known.contains($0.id) && !$0.name.isEmpty }, "\(similar)")
        }
        // Metadata similarity = shared genre: the Electronic compilation's
        // album artist is the only other artist with Electronic albums.
        let toNeon = try await library.similarArtists(artistID: context.artist("Neon Circuit").id, limit: 12)
        XCTAssertEqual(toNeon.map(\.name), ["Various Artists"])
        await assertThrowsJellyfinError(.notFound) {
            _ = try await self.library.similarArtists(artistID: Library.unknownID, limit: 12)
        }
    }

    // MARK: Genres

    func testGenresAndTracksInGenre() async throws {
        let genres = try await library.genres()
        XCTAssertEqual(genres.map(\.name), Library.genres.sorted())
        XCTAssertEqual(Set(genres.map(\.id)).count, genres.count)

        for genre in genres {
            let tracks = try await library.tracks(inGenre: genre.id)
            let expected = Library.albums
                .filter { $0.genre == genre.name }
                .sorted { $0.title < $1.title }
                .flatMap(\.tracks)
            // Sorted by album, then track number.
            XCTAssertEqual(tracks.titles, expected, genre.name)
            XCTAssertTrue(tracks.allSatisfy { $0.genres == [genre.name] }, genre.name)
        }
        let unknown = try await library.tracks(inGenre: Library.unknownID)
        XCTAssertEqual(unknown, [])
    }

    // MARK: Home rows

    func testRecentlyAddedAlbums() async throws {
        let albums = try await library.recentlyAddedAlbums(limit: 20)
        XCTAssertEqual(Set(albums.titles), Set(Library.albums.map(\.title)))
        XCTAssertEqual(albums.count, Library.albums.count)
        for album in albums {
            let spec = Library.spec(album.title)
            XCTAssertEqual(album.artistName, spec.artist, album.title)
            XCTAssertEqual(album.artistID, context.artist(spec.artist).id, album.title)
            XCTAssertEqual(album.productionYear, spec.year, album.title)
            XCTAssertEqual(album.imageTag, context.album(album.title).imageTag, album.title)
            // Regression: `/Items/Latest` needs `fields=` like `/Items` does …
            XCTAssertEqual(album.genres, [spec.genre], album.title)
            // … and reports `ChildCount: 0` for every album no matter what.
            XCTAssertTrue(album.trackCount == nil || album.trackCount == spec.tracks.count, "\(album.title): \(String(describing: album.trackCount))")
        }
        let three = try await library.recentlyAddedAlbums(limit: 3)
        XCTAssertEqual(three.count, 3)
    }

    func testPlayedTrackShowsUpInRecentlyPlayedAndTopTracks() async throws {
        let track = context.track("Scherzo")
        let artist = context.artist("Halden Quartet")
        // Marking a track played is the one thing here that is not ours to
        // undo if somebody else played it first — then leave it alone.
        let before = try await userData(of: track.id)
        if !before.played {
            let marked = try await raw("POST", "UserPlayedItems/\(track.id)", query: [URLQueryItem(name: "userId", value: session.userID)])
            XCTAssertEqual(marked.status, 200)
        }
        try await withCleanup({
            let recent = try await self.library.recentlyPlayedTracks(limit: 50)
            XCTAssertTrue(recent.contains { $0.id == track.id }, "\(recent.titles)")
            XCTAssertTrue(recent.allSatisfy { $0.codec != nil })
            let limited = try await self.library.recentlyPlayedTracks(limit: 1)
            XCTAssertEqual(limited.count, 1)

            // Most played first: nothing else by this artist has been played
            // unless another client did so, in which case it is still in the top.
            let top = try await self.library.topTracks(byArtist: artist.id, limit: 4)
            XCTAssertTrue(top.contains { $0.id == track.id }, "\(top.titles)")
        }, cleanup: {
            if !before.played {
                _ = try? await self.raw("DELETE", "UserPlayedItems/\(track.id)", query: [URLQueryItem(name: "userId", value: self.session.userID)])
            }
        })
        if !before.played {
            let after = try await library.recentlyPlayedTracks(limit: 50)
            XCTAssertFalse(after.contains { $0.id == track.id })
        }
    }

    // MARK: Search

    func testSearchFindsEachKindCaseInsensitively() async throws {
        for term in ["power", "POWER", "Power On", "  power on "] {
            let result = try await library.search(query: term, limit: 20)
            XCTAssertEqual(result.tracks.titles, ["Power On"], term)
            XCTAssertEqual(result.albums, [], term)
            XCTAssertEqual(result.artists, [], term)
        }
        let sampler = try await library.search(query: "sampler", limit: 20)
        XCTAssertEqual(Set(sampler.tracks.titles), ["Sampler Intro", "Sampler Outro"])
        XCTAssertEqual(sampler.albums.titles, ["Jellyamp Sampler"])
        XCTAssertEqual(sampler.albums.first?.artistName, "Various Artists")
        XCTAssertEqual(sampler.albums.first?.trackCount, 2)
        XCTAssertEqual(sampler.tracks.first?.codec, "mp3", "search results are full tracks")

        let neon = try await library.search(query: "neon", limit: 20)
        XCTAssertEqual(neon.artists.map(\.name), ["Neon Circuit"])
        XCTAssertEqual(neon.artists.first?.id, context.artist("Neon Circuit").id)
        // The search term matches names only: not the tracks *by* Neon Circuit.
        XCTAssertEqual(neon.tracks, [])

        let phrase = try await library.search(query: "dust and", limit: 20)
        XCTAssertEqual(phrase.tracks.titles, ["Dust and Diesel"])
    }

    func testSearchLimitAndUnusualTerms() async throws {
        let limited = try await library.search(query: "s", limit: 2)
        XCTAssertEqual(limited.tracks.count, 2)
        XCTAssertLessThanOrEqual(limited.albums.count, 2)

        // Reserved characters must survive the trip as data, not as syntax.
        for term in ["xyzzy-nothing", "a&b=c", "100% #1?", "AC+DC", "\"quoted\"", "naïve café", "日本語", "a/b\\c"] {
            let result = try await library.search(query: term, limit: 5)
            XCTAssertEqual(result.tracks, [], term)
            XCTAssertEqual(result.albums, [], term)
            XCTAssertEqual(result.artists, [], term)
        }
    }

    // MARK: Tracks by ID

    func testTracksByIDsKeepRequestOrderAndDropUnknownIDs() async throws {
        let all = context.allTracks
        let reversed = Array(all.reversed().map(\.id))
        let fetched = try await library.tracks(byIDs: reversed)
        XCTAssertEqual(fetched.map(\.id), reversed)
        XCTAssertEqual(fetched.first?.codec, all.last?.codec, "full tracks, not stubs")

        let a = all[0].id, b = all[1].id
        let withUnknown = try await library.tracks(byIDs: [b, Library.unknownID, a, b])
        XCTAssertEqual(withUnknown.map(\.id), [b, a, b], "unknown dropped, duplicates kept, order kept")

        let none = try await library.tracks(byIDs: [])
        XCTAssertEqual(none, [])
        let onlyUnknown = try await library.tracks(byIDs: [Library.unknownID])
        XCTAssertEqual(onlyUnknown, [])
    }

    func testTracksByIDsBeyondTheURLLengthLimit() async throws {
        // 600 IDs are a 20 kB query string; the server answers 414 well
        // before that (between 6.6 kB and 13 kB).
        let ids = (0..<600).map { context.allTracks[$0 % Library.trackCount].id }
        let fetched = try await library.tracks(byIDs: ids)
        XCTAssertEqual(fetched.map(\.id), ids)
    }
}
