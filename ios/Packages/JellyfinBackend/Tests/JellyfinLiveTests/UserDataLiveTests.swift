import XCTest
import JellyfinBackend
import JellyampCore

/// What the user changes: favorites and playlists. Everything created here is
/// removed again, also when an assertion fails half-way.
final class UserDataLiveTests: LiveTestCase {
    // MARK: Favorites

    /// Sets, lists, checks the item itself, unsets — and puts back whatever
    /// state the item had (another client may have favorited it for real).
    private func roundTrip(
        itemID: String,
        isListed: @escaping () async throws -> Bool,
        isFlaggedOnItem: @escaping () async throws -> Bool
    ) async throws {
        let before = try await userData(of: itemID).isFavorite
        try await withCleanup({
            try await self.library.setFavorite(itemID: itemID, isFavorite: true)
            let listedAfterSet = try await isListed()
            XCTAssertTrue(listedAfterSet, "favorite is not listed")
            let flaggedAfterSet = try await isFlaggedOnItem()
            XCTAssertTrue(flaggedAfterSet, "isFavorite is not mapped")
            // Setting twice is not an error.
            try await self.library.setFavorite(itemID: itemID, isFavorite: true)

            try await self.library.setFavorite(itemID: itemID, isFavorite: false)
            let listedAfterUnset = try await isListed()
            XCTAssertFalse(listedAfterUnset, "un-favorited item is still listed")
            let flaggedAfterUnset = try await isFlaggedOnItem()
            XCTAssertFalse(flaggedAfterUnset)
            try await self.library.setFavorite(itemID: itemID, isFavorite: false)
        }, cleanup: {
            try? await self.library.setFavorite(itemID: itemID, isFavorite: before)
        })
    }

    func testFavoriteTrackRoundTrip() async throws {
        let track = context.track("Morning Fog")
        try await roundTrip(
            itemID: track.id,
            isListed: {
                let favorites = try await self.library.favoriteTracks(limit: 500)
                XCTAssertTrue(favorites.allSatisfy { $0.isFavorite && $0.codec != nil })
                return favorites.contains { $0.id == track.id }
            },
            isFlaggedOnItem: {
                let album = self.context.album("Low Tide")
                return try await self.library.tracks(inAlbum: album.id).first { $0.id == track.id }?.isFavorite ?? false
            }
        )
    }

    func testFavoriteAlbumRoundTrip() async throws {
        let album = context.album("Second Shift")
        try await roundTrip(
            itemID: album.id,
            isListed: {
                let favorites = try await self.library.favoriteAlbums(limit: 500)
                XCTAssertTrue(favorites.allSatisfy { $0.isFavorite })
                if let listed = favorites.first(where: { $0.id == album.id }) {
                    XCTAssertEqual(listed.trackCount, 3)
                    XCTAssertEqual(listed.artistName, "The Granite Saints")
                }
                return favorites.contains { $0.id == album.id }
            },
            isFlaggedOnItem: {
                try await self.library.album(id: album.id)?.isFavorite ?? false
            }
        )
    }

    func testFavoriteArtistRoundTrip() async throws {
        let artist = context.artist("Halden Quartet")
        try await roundTrip(
            itemID: artist.id,
            isListed: {
                let favorites = try await self.library.favoriteArtists(limit: 500)
                XCTAssertTrue(favorites.allSatisfy { $0.isFavorite })
                return favorites.contains { $0.id == artist.id && $0.name == "Halden Quartet" }
            },
            isFlaggedOnItem: {
                try await self.library.artist(id: artist.id)?.isFavorite ?? false
            }
        )
    }

    func testFavoriteLimitAndUnknownItem() async throws {
        let first = context.track("Clock In"), second = context.track("Overtime")
        let before = (try await userData(of: first.id).isFavorite, try await userData(of: second.id).isFavorite)
        try await withCleanup({
            try await self.library.setFavorite(itemID: first.id, isFavorite: true)
            try await self.library.setFavorite(itemID: second.id, isFavorite: true)
            let one = try await self.library.favoriteTracks(limit: 1)
            XCTAssertEqual(one.count, 1)
        }, cleanup: {
            try? await self.library.setFavorite(itemID: first.id, isFavorite: before.0)
            try? await self.library.setFavorite(itemID: second.id, isFavorite: before.1)
        })
        await assertThrowsJellyfinError(.notFound) {
            try await self.library.setFavorite(itemID: Library.unknownID, isFavorite: true)
        }
    }

    // MARK: Playlists

    /// A name with everything that can go wrong in a URL or a search.
    private func uniqueName(_ suffix: String = "") -> String {
        "Jellyamp Live Test \(UUID().uuidString.prefix(8)) Café A+B & C\(suffix)"
    }

    private func withPlaylist(
        name: String,
        itemIDs: [String],
        _ body: (String) async throws -> Void
    ) async throws {
        let id = try await library.createPlaylist(name: name, itemIDs: itemIDs)
        try await withCleanup({
            try await body(id)
        }, cleanup: {
            // Deleting twice is a 404, which is fine here.
            try? await self.library.deletePlaylist(playlistID: id)
        })
    }

    private func entries(_ playlistID: String) async throws -> [Track] {
        try await library.tracks(inPlaylist: playlistID)
    }

    func testPlaylistLifecycle() async throws {
        let voltage = context.tracksByAlbum["Voltage"]!
        let name = uniqueName()
        var playlistID = ""
        try await withPlaylist(name: name, itemIDs: voltage.prefix(3).map(\.id)) { id in
            playlistID = id
            XCTAssertFalse(id.isEmpty)

            // Listed, with the exact name ("+", "&", "é" intact) and a count.
            let listed = try await self.library.playlists().first { $0.id == id }
            let created = try XCTUnwrap(listed, "new playlist is not listed")
            XCTAssertEqual(created.name, name)
            XCTAssertEqual(created.trackCount, 3)

            // Tracks in order, as full tracks, each with an entry ID.
            var tracks = try await self.entries(id)
            XCTAssertEqual(tracks.titles, ["Power On", "Gridlock", "Arc Flash"])
            XCTAssertTrue(tracks.allSatisfy { $0.playlistEntryID?.isEmpty == false })
            XCTAssertEqual(Set(tracks.compactMap(\.playlistEntryID)).count, 3)
            XCTAssertEqual(tracks[0].codec, "mp3")
            XCTAssertEqual(tracks[0].albumID, self.context.album("Voltage").id)
            XCTAssertEqual(tracks[0].genres, ["Electronic"])
            XCTAssertNotNil(tracks[0].imageTag)
            XCTAssertNotNil(tracks[0].normalizationGainDB)

            // Append.
            try await self.library.addToPlaylist(playlistID: id, itemIDs: voltage.suffix(2).map(\.id))
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks.titles, ["Power On", "Gridlock", "Arc Flash", "Standby", "Overclock"])
            let count = try await self.library.playlists().first { $0.id == id }?.trackCount
            XCTAssertEqual(count, 5)

            // Move: to the front, to the end, into the middle, and nowhere.
            func move(_ title: String, to index: Int) async throws -> [String] {
                let current = try await self.entries(id)
                let entry = try XCTUnwrap(current.first { $0.title == title }?.playlistEntryID)
                try await self.library.movePlaylistItem(playlistID: id, entryID: entry, toIndex: index)
                return try await self.entries(id).titles
            }
            var order = try await move("Overclock", to: 0)
            XCTAssertEqual(order, ["Overclock", "Power On", "Gridlock", "Arc Flash", "Standby"])
            order = try await move("Overclock", to: 4)
            XCTAssertEqual(order, ["Power On", "Gridlock", "Arc Flash", "Standby", "Overclock"])
            order = try await move("Power On", to: 1)
            XCTAssertEqual(order, ["Gridlock", "Power On", "Arc Flash", "Standby", "Overclock"])
            order = try await move("Standby", to: 2)
            XCTAssertEqual(order, ["Gridlock", "Power On", "Standby", "Arc Flash", "Overclock"])
            order = try await move("Standby", to: 2)
            XCTAssertEqual(order, ["Gridlock", "Power On", "Standby", "Arc Flash", "Overclock"])
            order = try await move("Gridlock", to: 3)
            XCTAssertEqual(order, ["Power On", "Standby", "Arc Flash", "Gridlock", "Overclock"])

            // Remove two entries at once.
            tracks = try await self.entries(id)
            let doomed = tracks.filter { ["Standby", "Overclock"].contains($0.title) }.compactMap(\.playlistEntryID)
            try await self.library.removeFromPlaylist(playlistID: id, entryIDs: doomed)
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks.titles, ["Power On", "Arc Flash", "Gridlock"])

            // Rename keeps the tracks.
            let renamed = self.uniqueName(" (renamed)")
            try await self.library.renamePlaylist(playlistID: id, name: renamed)
            let afterRename = try await self.library.playlists().first { $0.id == id }
            XCTAssertEqual(afterRename?.name, renamed)
            XCTAssertEqual(afterRename?.trackCount, 3)
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks.titles, ["Power On", "Arc Flash", "Gridlock"])

            // Search finds it: by a word, ignoring case and diacritics, and
            // by the part with the "+".
            for term in [String(renamed.split(separator: " ")[3]), "CAFE a+b", "café", "cafe"] {
                let found = try await self.library.search(query: term, limit: 50).playlists
                XCTAssertTrue(found.contains { $0.id == id && $0.name == renamed }, "search \"\(term)\": \(found.map { "\($0.id) \($0.name)" })")
            }

            // Cover image.
            let before = try await self.library.playlists().first { $0.id == id }?.imageTag
            try await self.library.setPlaylistImage(playlistID: id, jpeg: Self.tinyJPEG)
            let after = try await self.library.playlists().first { $0.id == id }?.imageTag
            XCTAssertNotNil(after)
            XCTAssertNotEqual(after, before)
            let image = try await self.fetch(ImageURLBuilder.url(itemID: id, tag: after, maxWidth: 64, session: self.session))
            XCTAssertEqual(image.status, 200)
            XCTAssertTrue(image.contentType.hasPrefix("image/"), image.contentType)

            // Delete.
            try await self.library.deletePlaylist(playlistID: id)
            let gone = try await self.library.playlists().contains { $0.id == id }
            XCTAssertFalse(gone)
        }
        await assertThrowsJellyfinError(.notFound) {
            try await self.library.deletePlaylist(playlistID: playlistID)
        }
        await assertThrowsJellyfinError(.notFound) {
            _ = try await self.library.tracks(inPlaylist: playlistID)
        }
    }

    func testEmptyPlaylistAndRemovingEverything() async throws {
        try await withPlaylist(name: uniqueName(" empty"), itemIDs: []) { id in
            var tracks = try await self.entries(id)
            XCTAssertEqual(tracks, [])
            let listed = try await self.library.playlists().first { $0.id == id }
            XCTAssertEqual(listed?.trackCount ?? 0, 0)

            try await self.library.addToPlaylist(playlistID: id, itemIDs: [self.context.track("Adagio").id])
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks.titles, ["Adagio"])
            try await self.library.removeFromPlaylist(playlistID: id, entryIDs: tracks.compactMap(\.playlistEntryID))
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks, [])
            // Nothing to do is not a request.
            try await self.library.addToPlaylist(playlistID: id, itemIDs: [])
            try await self.library.removeFromPlaylist(playlistID: id, entryIDs: [])
        }
    }

    func testPlaylistsBeyondTheURLLengthLimit() async throws {
        // 400 IDs (13 kB as a query string) to create, 400 more to add, and
        // then all entries removed in one call. Jellyfin 10.10 keeps a track
        // only once per playlist, so the library's 34 tracks are what stays.
        let all = context.allTracks.map(\.id)
        let many = (0..<400).map { all[$0 % all.count] }
        try await withPlaylist(name: uniqueName(" big"), itemIDs: many) { id in
            var tracks = try await self.entries(id)
            XCTAssertEqual(Array(tracks.map(\.id).prefix(all.count)), all)
            try await self.library.addToPlaylist(playlistID: id, itemIDs: many.reversed())
            tracks = try await self.entries(id)
            XCTAssertGreaterThanOrEqual(tracks.count, all.count)
            XCTAssertEqual(Set(tracks.map(\.id)), Set(all))

            let entryIDs = tracks.compactMap(\.playlistEntryID)
            let padded = entryIDs + (0..<300).map { _ in Library.unknownID }
            try await self.library.removeFromPlaylist(playlistID: id, entryIDs: padded)
            tracks = try await self.entries(id)
            XCTAssertEqual(tracks, [])
        }
    }

    func testPlaylistErrors() async throws {
        await assertThrowsJellyfinError(.notFound) {
            try await self.library.addToPlaylist(playlistID: Library.unknownID, itemIDs: [self.context.track("Adagio").id])
        }
        await assertThrowsJellyfinError(.notFound) {
            try await self.library.renamePlaylist(playlistID: Library.unknownID, name: "x")
        }
        await assertThrowsJellyfinError(.notFound) {
            try await self.library.movePlaylistItem(playlistID: Library.unknownID, entryID: Library.unknownID, toIndex: 0)
        }
    }

    /// 32×32 green square.
    static let tinyJPEG = Data(base64Encoded:
        "/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYwLjMxLjEwMgD/2wBDAAgUFBcUFxsbGxsbGyAeICEhISAgICAhISEkJCQqKiokJCQhISQkKCgqKi4vLisr"
        + "KisvLzIyMjw8OTlGRkhWVmf/xABNAAEBAAAAAAAAAAAAAAAAAAAABQEBAQEAAAAAAAAAAAAAAAAAAAUGEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAA"
        + "AAAAAAAA/8AAEQgAIAAgAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiAJLLAAAAAAP/9k="
    )!
}
