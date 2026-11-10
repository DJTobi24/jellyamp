import Foundation

/// One search result of any kind, used for the "Top Result" card.
public enum SearchHit: Hashable, Identifiable, Sendable {
    case artist(Artist)
    case album(Album)
    case track(Track)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .artist(let artist): return "artist:\(artist.id)"
        case .album(let album): return "album:\(album.id)"
        case .track(let track): return "track:\(track.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        }
    }

    public var title: String {
        switch self {
        case .artist(let artist): return artist.name
        case .album(let album): return album.title
        case .track(let track): return track.title
        case .playlist(let playlist): return playlist.name
        }
    }
}

/// Search results ranked and grouped for display.
public struct GroupedSearchResults: Equatable, Sendable {
    public var topResult: SearchHit?
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    public var playlists: [Playlist]

    public init(topResult: SearchHit? = nil, artists: [Artist] = [], albums: [Album] = [], tracks: [Track] = [], playlists: [Playlist] = []) {
        self.topResult = topResult
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && tracks.isEmpty && playlists.isEmpty
    }
}

public enum SearchRanker {
    /// How well a name matches the query; 0 means no textual match.
    public enum Match: Int, Comparable, Sendable {
        case none = 0
        /// Every query word appears somewhere.
        case allWords = 30
        /// The query appears inside the name.
        case contains = 40
        /// A word of the name starts with the query ("saints" → The Granite Saints).
        case wordPrefix = 60
        /// The name starts with the query, ignoring a leading article.
        case prefix = 80
        case exact = 100

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Lower-cased, diacritics folded, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    public static func match(name: String, query: String) -> Match {
        let name = normalize(name)
        let query = normalize(query)
        guard !query.isEmpty, !name.isEmpty else { return .none }
        if name == query { return .exact }
        let withoutArticle = AlphabetIndex.sortKey(for: name)
        if withoutArticle == query { return .exact }
        if name.hasPrefix(query) || withoutArticle.hasPrefix(query) { return .prefix }
        let words = name.split(separator: " ")
        if words.contains(where: { $0.hasPrefix(query) }) { return .wordPrefix }
        if name.contains(query) { return .contains }
        let queryWords = query.split(separator: " ")
        if queryWords.count > 1, queryWords.allSatisfy({ word in words.contains { $0.hasPrefix(word) } }) {
            return .allWords
        }
        return .none
    }

    /// Ranks each group (best textual match first, server order among equals,
    /// so the server's own relevance survives) and picks the top result.
    ///
    /// The top result is the best match across all kinds. Between equally
    /// good matches an artist wins over an album, an album over a song, a
    /// song over a playlist — searching "neon circuit" should offer the
    /// artist, not the song that happens to share the name.
    public static func group(
        query: String,
        tracks: [Track],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist]
    ) -> GroupedSearchResults {
        let rankedArtists = rank(artists) { match(name: $0.name, query: query) }
        let rankedAlbums = rank(albums) { match(name: $0.title, query: query) }
        let rankedPlaylists = rank(playlists) { match(name: $0.name, query: query) }
        // A song found through its artist or album still belongs in the
        // list, but below songs whose title matches.
        let rankedTracks = rank(tracks) { track in
            let title = match(name: track.title, query: query)
            if title != .none { return title }
            let credit = max(match(name: track.artistName, query: query), match(name: track.albumName ?? "", query: query))
            return credit == .none ? .none : .allWords
        }

        var candidates: [(hit: SearchHit, match: Match, kindPriority: Int)] = []
        if let best = rankedArtists.first { candidates.append((.artist(best.item), best.match, 0)) }
        if let best = rankedAlbums.first { candidates.append((.album(best.item), best.match, 1)) }
        if let best = rankedTracks.first { candidates.append((.track(best.item), best.match, 2)) }
        if let best = rankedPlaylists.first { candidates.append((.playlist(best.item), best.match, 3)) }
        let top = candidates.min { lhs, rhs in
            lhs.match != rhs.match ? lhs.match > rhs.match : lhs.kindPriority < rhs.kindPriority
        }

        return GroupedSearchResults(
            topResult: top?.hit,
            artists: rankedArtists.map(\.item),
            albums: rankedAlbums.map(\.item),
            tracks: rankedTracks.map(\.item),
            playlists: rankedPlaylists.map(\.item)
        )
    }

    private static func rank<Item>(_ items: [Item], by score: (Item) -> Match) -> [(item: Item, match: Match)] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, match: score($0.element)) }
            .sorted { lhs, rhs in lhs.match != rhs.match ? lhs.match > rhs.match : lhs.offset < rhs.offset }
            .map { (item: $0.item, match: $0.match) }
    }
}

/// When a typed query is worth sending.
public enum SearchQueryPolicy {
    /// Pause after the last keystroke before the request goes out.
    public static let debounceNanoseconds: UInt64 = 300_000_000

    /// The query to send, or nil when there is nothing to search for.
    public static func effectiveQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Most-recent-first list of search terms, without duplicates.
public struct RecentSearchList: Equatable, Codable, Sendable {
    public private(set) var terms: [String]
    public let limit: Int

    public init(terms: [String] = [], limit: Int = 10) {
        self.limit = max(1, limit)
        self.terms = []
        // Re-adding oldest first restores the order and drops duplicates or
        // blanks that an older app version may have persisted.
        for term in terms.reversed() { add(term) }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Records a term the user acted on. One-letter terms are typing noise.
    public mutating func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        if terms.count > limit { terms.removeLast(terms.count - limit) }
    }

    public mutating func remove(_ term: String) {
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    public mutating func clear() {
        terms = []
    }
}
