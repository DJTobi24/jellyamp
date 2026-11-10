import Foundation

/// The tracks of one disc of an album.
public struct DiscSection: Equatable, Identifiable, Sendable {
    public var disc: Int
    public var tracks: [Track]

    public var id: Int { disc }

    public init(disc: Int, tracks: [Track]) {
        self.disc = disc
        self.tracks = tracks
    }
}

/// How an album's track list is laid out: disc grouping, track numbers,
/// compilation detection and the metadata line under the title.
public enum AlbumPresentation {
    /// Groups tracks by disc and orders them by track number. Tracks without
    /// a disc number belong to disc 1; tracks without a track number keep
    /// their server order after the numbered ones.
    public static func discSections(_ tracks: [Track]) -> [DiscSection] {
        var byDisc: [Int: [(offset: Int, track: Track)]] = [:]
        for (offset, track) in tracks.enumerated() {
            byDisc[max(1, track.discNumber ?? 1), default: []].append((offset, track))
        }
        return byDisc.keys.sorted().map { disc in
            let ordered = (byDisc[disc] ?? []).sorted { lhs, rhs in
                switch (lhs.track.indexNumber, rhs.track.indexNumber) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
            return DiscSection(disc: disc, tracks: ordered.map(\.track))
        }
    }

    /// Disc headers are noise on a single-disc album.
    public static func showsDiscHeaders(_ sections: [DiscSection]) -> Bool {
        sections.count > 1
    }

    /// The order "Play" uses: disc by disc.
    public static func playbackOrder(_ sections: [DiscSection]) -> [Track] {
        sections.flatMap(\.tracks)
    }

    /// The number shown in front of a row: the tagged track number, or the
    /// row's position when the file has none.
    public static func trackNumber(for track: Track, positionInDisc: Int) -> Int {
        if let number = track.indexNumber, number > 0 { return number }
        return positionInDisc + 1
    }

    /// True when rows should name their artist: on compilations and albums
    /// with guests, i.e. whenever a track artist differs from the album
    /// artist. Comparison ignores case, diacritics and surrounding spaces.
    public static func showsTrackArtists(tracks: [Track], albumArtist: String) -> Bool {
        let reference = fold(albumArtist)
        return tracks.contains { track in
            let artist = fold(track.artistName)
            return !artist.isEmpty && artist != reference
        }
    }

    public static func totalDuration(_ tracks: [Track]) -> TimeInterval {
        tracks.reduce(0) { $0 + max(0, $1.duration.isFinite ? $1.duration : 0) }
    }

    /// The line under an album title, e.g. `2021 · Electronic · 3 songs ·
    /// 15 min`. Parts that are unknown are left out.
    public static func metadataLine(year: Int?, genres: [String], trackCount: Int?, duration: TimeInterval?) -> String {
        var parts: [String] = []
        if let year, year > 0 { parts.append(String(year)) }
        if let genre = genres.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            parts.append(genre)
        }
        if let trackCount, trackCount > 0 { parts.append(CoreStrings.current.songCount(trackCount)) }
        if let duration, duration >= 1 { parts.append(DurationText.approximate(duration)) }
        return parts.joined(separator: " · ")
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// An artist's releases, split the way the artist page shows them.
public struct Discography: Equatable, Sendable {
    public var albums: [Album]
    public var singlesAndEPs: [Album]

    /// Releases with fewer tracks than this count as singles / EPs.
    public static let albumMinimumTrackCount = 4

    /// Splits by track count and sorts each group by year. Releases whose
    /// track count is unknown are treated as albums (never hide a release in
    /// the smaller shelf on a guess); releases without a year go last.
    public init(releases: [Album], newestFirst: Bool = true) {
        let sorted = Discography.sortedByYear(releases, newestFirst: newestFirst)
        albums = sorted.filter { ($0.trackCount ?? Discography.albumMinimumTrackCount) >= Discography.albumMinimumTrackCount }
        singlesAndEPs = sorted.filter { ($0.trackCount ?? Discography.albumMinimumTrackCount) < Discography.albumMinimumTrackCount }
    }

    public static func sortedByYear(_ releases: [Album], newestFirst: Bool) -> [Album] {
        releases.enumerated().sorted { lhs, rhs in
            switch (lhs.element.productionYear, rhs.element.productionYear) {
            case let (left?, right?) where left != right:
                return newestFirst ? left > right : left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = lhs.element.title.localizedCaseInsensitiveCompare(rhs.element.title)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
        }.map(\.element)
    }
}
