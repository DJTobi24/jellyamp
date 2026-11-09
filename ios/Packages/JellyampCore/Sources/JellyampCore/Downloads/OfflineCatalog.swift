import Foundation

/// A browsable library reconstructed from the download index: only fully
/// downloaded tracks, grouped back into albums, artists, genres and the
/// pinned playlists. This is what the app shows while offline.
public struct OfflineCatalog: Equatable, Sendable {
    /// Prefix of the synthetic genre ids used offline (Jellyfin's real genre
    /// ids are GUIDs the tracks don't carry).
    public static let genreIDPrefix = "offline-genre:"

    public private(set) var tracks: [Track]
    private var addedAt: [String: Date]
    private var albumMetadata: [String: Album]
    private var artistMetadata: [String: DownloadPin]
    private var playlistPins: [DownloadPin]
    private var playlistTrackIDs: [String: [String]]
    private var tracksByID: [String: Track]
    /// Real Jellyfin genre id → name, learned while online, so a genre screen
    /// opened before going offline still resolves.
    public var genreNamesByID: [String: String]

    public init(index: DownloadIndex, genreNamesByID: [String: String] = [:]) {
        let complete = index.completeEntries
        tracks = complete.map(\.track)
        addedAt = [:]
        tracksByID = [:]
        for entry in complete {
            addedAt[entry.id] = entry.completedAt ?? entry.addedAt
            tracksByID[entry.id] = entry.track
        }
        albumMetadata = [:]
        artistMetadata = [:]
        playlistPins = []
        playlistTrackIDs = [:]
        for pin in index.pins {
            switch pin.kind {
            case .album:
                if let album = pin.album { albumMetadata[pin.itemID] = album }
            case .artist:
                artistMetadata[pin.itemID] = pin
            case .playlist:
                playlistPins.append(pin)
                playlistTrackIDs[pin.itemID] = pin.trackIDs
            case .track, .smartSync:
                break
            }
        }
        self.genreNamesByID = genreNamesByID
    }

    public var isEmpty: Bool { tracks.isEmpty }

    // MARK: Tracks

    public func track(id: String) -> Track? { tracksByID[id] }

    /// Downloaded tracks among `ids`, in the order asked for.
    public func tracks(byIDs ids: [String]) -> [Track] {
        ids.compactMap { tracksByID[$0] }
    }

    /// All downloaded tracks, sorted by title.
    public var tracksByTitle: [Track] {
        tracks.sorted { Self.ordered($0.title, $1.title, tieBreak: $0.id < $1.id) }
    }

    public func favoriteTracks(limit: Int) -> [Track] {
        Array(tracksByTitle.filter(\.isFavorite).prefix(max(limit, 0)))
    }

    // MARK: Albums

    public func albums(sortBy: String = "SortName", sortOrder: String = "Ascending", startIndex: Int = 0, limit: Int = 100) -> [Album] {
        let all = allAlbums()
        let keys = sortBy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let sorted: [Album]
        if keys.first == "Random" {
            sorted = all.shuffled()
        } else {
            let descending = sortOrder.caseInsensitiveCompare("Descending") == .orderedSame
            let dates = albumDates()
            let ascending = all.sorted { lhs, rhs in
                for key in keys {
                    let comparison: ComparisonResult
                    switch key {
                    case "DateCreated":
                        comparison = Self.compare(dates[lhs.id] ?? .distantPast, dates[rhs.id] ?? .distantPast)
                    case "ProductionYear", "PremiereDate":
                        comparison = Self.compare(lhs.productionYear ?? 0, rhs.productionYear ?? 0)
                    case "AlbumArtist", "Artist":
                        comparison = Self.sortKey(lhs.artistName).compare(Self.sortKey(rhs.artistName))
                    default:
                        comparison = Self.sortKey(lhs.title).compare(Self.sortKey(rhs.title))
                    }
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                }
                let byTitle = Self.sortKey(lhs.title).compare(Self.sortKey(rhs.title))
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return lhs.id < rhs.id
            }
            sorted = descending ? Array(ascending.reversed()) : ascending
        }
        return Self.page(sorted, startIndex: startIndex, limit: limit)
    }

    public func album(id: String) -> Album? {
        let albumTracks = tracks.filter { $0.albumID == id }
        guard !albumTracks.isEmpty else { return nil }
        return makeAlbum(id: id, tracks: albumTracks)
    }

    /// Album tracks in disc / track-number order.
    public func tracks(inAlbum albumID: String) -> [Track] {
        Self.albumOrder(tracks.filter { $0.albumID == albumID })
    }

    /// Albums with the most recently downloaded track first.
    public func recentlyAddedAlbums(limit: Int) -> [Album] {
        albums(sortBy: "DateCreated", sortOrder: "Descending", startIndex: 0, limit: limit)
    }

    public func favoriteAlbums(limit: Int) -> [Album] {
        Array(albums(limit: Int.max).filter(\.isFavorite).prefix(max(limit, 0)))
    }

    // MARK: Artists

    public func artists(sortBy: String = "SortName", startIndex: Int = 0, limit: Int = 100) -> [Artist] {
        let all = allArtists()
        let sorted = sortBy.hasPrefix("Random")
            ? all.shuffled()
            : all.sorted { Self.ordered($0.name, $1.name, tieBreak: $0.id < $1.id) }
        return Self.page(sorted, startIndex: startIndex, limit: limit)
    }

    public func artist(id: String) -> Artist? {
        allArtists().first { $0.id == id }
    }

    /// Albums credited to the artist (album artist, or — for albums we only
    /// know from their tracks — the tracks' artist), newest first.
    public func albums(byArtist artistID: String) -> [Album] {
        allAlbums()
            .filter { $0.artistID == artistID }
            .sorted { lhs, rhs in
                let byYear = Self.compare(lhs.productionYear ?? 0, rhs.productionYear ?? 0)
                if byYear != .orderedSame { return byYear == .orderedDescending }
                return Self.ordered(lhs.title, rhs.title, tieBreak: lhs.id < rhs.id)
            }
    }

    /// Albums by someone else that contain a track of this artist.
    public func appearsOnAlbums(artistID: String) -> [Album] {
        let albumIDs = Set(tracks.filter { $0.artistID == artistID }.compactMap(\.albumID))
        return allAlbums()
            .filter { albumIDs.contains($0.id) && $0.artistID != artistID }
            .sorted { Self.ordered($0.title, $1.title, tieBreak: $0.id < $1.id) }
    }

    /// The artist's downloaded tracks, album by album.
    public func tracks(byArtist artistID: String) -> [Track] {
        let own = tracks.filter { $0.artistID == artistID }
        return own.sorted { lhs, rhs in
            let byAlbum = Self.sortKey(lhs.albumName ?? "").compare(Self.sortKey(rhs.albumName ?? ""))
            if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
            return Self.precedesInAlbum(lhs, rhs)
        }
    }

    public func favoriteArtists(limit: Int) -> [Artist] {
        Array(artists(limit: Int.max).filter(\.isFavorite).prefix(max(limit, 0)))
    }

    // MARK: Genres

    public func genres() -> [Genre] {
        var names: [String: String] = [:]
        for track in tracks {
            for genre in track.genres {
                let key = Self.fold(genre)
                if !key.isEmpty, names[key] == nil { names[key] = genre }
            }
        }
        return names.values
            .sorted { Self.ordered($0, $1, tieBreak: $0 < $1) }
            .map { Genre(id: Self.genreIDPrefix + $0, name: $0) }
    }

    /// Accepts an offline genre id, a real Jellyfin genre id seen while
    /// online, or a plain genre name.
    public func tracks(inGenre genreID: String) -> [Track] {
        let name: String
        if genreID.hasPrefix(Self.genreIDPrefix) {
            name = String(genreID.dropFirst(Self.genreIDPrefix.count))
        } else {
            name = genreNamesByID[genreID] ?? genreID
        }
        let wanted = Self.fold(name)
        return tracksByTitle.filter { track in track.genres.contains { Self.fold($0) == wanted } }
    }

    // MARK: Playlists

    public func playlists() -> [Playlist] {
        playlistPins
            .map { pin in
                let downloaded = tracks(byIDs: pin.trackIDs)
                return Playlist(
                    id: pin.itemID,
                    name: pin.title,
                    trackCount: downloaded.count,
                    duration: downloaded.reduce(0) { $0 + $1.duration },
                    imageTag: pin.imageTag
                )
            }
            .sorted { Self.ordered($0.name, $1.name, tieBreak: $0.id < $1.id) }
    }

    /// The playlist's downloaded tracks in playlist order.
    public func tracks(inPlaylist playlistID: String) -> [Track] {
        tracks(byIDs: playlistTrackIDs[playlistID] ?? [])
    }

    // MARK: Search

    public struct SearchResults: Equatable, Sendable {
        public var tracks: [Track]
        public var albums: [Album]
        public var artists: [Artist]
        public var playlists: [Playlist]
    }

    /// Case- and diacritic-insensitive search; every word of the query must
    /// occur. Tracks also match on artist and album so "artist song" works.
    public func search(query: String, limit: Int) -> SearchResults {
        let folded = Self.fold(query)
        let tokens = folded.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            return SearchResults(tracks: [], albums: [], artists: [], playlists: [])
        }
        func matches(_ haystack: String) -> Bool {
            let foldedHaystack = Self.fold(haystack)
            return tokens.allSatisfy { foldedHaystack.contains($0) }
        }
        /// Title starts with the query → title contains it → matched elsewhere.
        func rank(_ title: String) -> Int {
            let foldedTitle = Self.fold(title)
            if foldedTitle.hasPrefix(folded) { return 0 }
            if foldedTitle.contains(folded) { return 1 }
            return 2
        }
        func ranked<T>(_ items: [T], title: (T) -> String) -> [T] {
            let keyed = items.enumerated().map { (rank: rank(title($0.element)), offset: $0.offset, item: $0.element) }
            let sorted = keyed.sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
            }
            return sorted.prefix(max(limit, 0)).map { $0.item }
        }
        let matchedTracks = tracksByTitle.filter { matches("\($0.title) \($0.artistName) \($0.albumName ?? "")") }
        let matchedAlbums = albums(limit: Int.max).filter { matches("\($0.title) \($0.artistName)") }
        let matchedArtists = artists(limit: Int.max).filter { matches($0.name) }
        let matchedPlaylists = playlists().filter { matches($0.name) }
        return SearchResults(
            tracks: ranked(matchedTracks, title: \.title),
            albums: ranked(matchedAlbums, title: \.title),
            artists: ranked(matchedArtists, title: \.name),
            playlists: ranked(matchedPlaylists, title: \.name)
        )
    }

    // MARK: Reconstruction

    /// Builds an album from nothing but its tracks.
    public static func derivedAlbum(id: String, tracks: [Track]) -> Album {
        // The most common track artist stands in for the album artist.
        var counts: [String: Int] = [:]
        var artistIDs: [String: String] = [:]
        for track in tracks {
            counts[track.artistName, default: 0] += 1
            if let artistID = track.artistID, artistIDs[track.artistName] == nil {
                artistIDs[track.artistName] = artistID
            }
        }
        let artistName = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key ?? ""
        var genres: [String] = []
        for genre in tracks.flatMap(\.genres) where !genres.contains(genre) { genres.append(genre) }
        return Album(
            id: id,
            title: tracks.first?.albumName ?? "",
            artistName: artistName,
            artistID: artistIDs[artistName],
            productionYear: tracks.compactMap(\.productionYear).max(),
            genres: genres,
            trackCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            isFavorite: false,
            imageTag: tracks.first?.imageTag
        )
    }

    private func makeAlbum(id: String, tracks albumTracks: [Track]) -> Album {
        var album = Self.derivedAlbum(id: id, tracks: albumTracks)
        if let known = albumMetadata[id] {
            // Pinned albums keep the server's metadata; the counts describe
            // what is actually on the device.
            let count = album.trackCount
            let duration = album.duration
            album = known
            album.trackCount = count
            album.duration = duration
        }
        return album
    }

    private func allAlbums() -> [Album] {
        var grouped: [String: [Track]] = [:]
        var order: [String] = []
        for track in tracks {
            guard let albumID = track.albumID else { continue }
            if grouped[albumID] == nil { order.append(albumID) }
            grouped[albumID, default: []].append(track)
        }
        return order.map { makeAlbum(id: $0, tracks: grouped[$0] ?? []) }
    }

    /// Newest download time among each album's tracks.
    private func albumDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for track in tracks {
            guard let albumID = track.albumID, let date = addedAt[track.id] else { continue }
            if let existing = dates[albumID], existing >= date { continue }
            dates[albumID] = date
        }
        return dates
    }

    private func allArtists() -> [Artist] {
        var artists: [String: Artist] = [:]
        var order: [String] = []
        func add(id: String?, name: String, genres: [String]) {
            guard !name.isEmpty || id != nil else { return }
            // Tracks without an artist id are grouped by name.
            let key = id ?? "offline-artist:\(Self.fold(name))"
            if var existing = artists[key] {
                for genre in genres where !existing.genres.contains(genre) { existing.genres.append(genre) }
                artists[key] = existing
            } else {
                order.append(key)
                let pin = artistMetadata[key]
                artists[key] = Artist(id: key, name: pin?.title ?? name, genres: genres, imageTag: pin?.imageTag)
            }
        }
        for track in tracks {
            add(id: track.artistID, name: track.artistName, genres: track.genres)
        }
        for album in allAlbums() {
            add(id: album.artistID, name: album.artistName, genres: [])
        }
        return order.compactMap { artists[$0] }
    }

    // MARK: Ordering helpers

    static func albumOrder(_ tracks: [Track]) -> [Track] {
        tracks.sorted(by: precedesInAlbum)
    }

    private static func precedesInAlbum(_ lhs: Track, _ rhs: Track) -> Bool {
        let discs = compare(lhs.discNumber ?? 1, rhs.discNumber ?? 1)
        if discs != .orderedSame { return discs == .orderedAscending }
        let numbers = compare(lhs.indexNumber ?? Int.max, rhs.indexNumber ?? Int.max)
        if numbers != .orderedSame { return numbers == .orderedAscending }
        return ordered(lhs.title, rhs.title, tieBreak: lhs.id < rhs.id)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    private static func ordered(_ lhs: String, _ rhs: String, tieBreak: @autoclosure () -> Bool) -> Bool {
        let comparison = sortKey(lhs).compare(sortKey(rhs))
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return tieBreak()
    }

    /// Lowercased, diacritics removed, whitespace collapsed.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Like Jellyfin's `SortName`: folded, leading article dropped.
    static func sortKey(_ text: String) -> String {
        let folded = fold(text)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) && folded.count > article.count {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    private static func page<T>(_ items: [T], startIndex: Int, limit: Int) -> [T] {
        guard startIndex < items.count else { return [] }
        let start = max(startIndex, 0)
        let end = limit >= items.count - start ? items.count : start + max(limit, 0)
        return Array(items[start..<end])
    }
}
