import Foundation

/// Favorite flags the user changed in this session, layered over what the
/// server last told each screen. Every heart reads through this, so toggling
/// a track in one list immediately shows in every other list and survives
/// navigating back to a screen that still holds the stale server value.
public struct FavoriteOverrides: Equatable, Sendable {
    public private(set) var values: [String: Bool] = [:]
    /// Bumped on every change; lists of favorites reload when it moves.
    public private(set) var revision = 0

    public init() {}

    public func isFavorite(_ itemID: String, serverValue: Bool) -> Bool {
        values[itemID] ?? serverValue
    }

    public mutating func set(_ itemID: String, isFavorite: Bool) {
        values[itemID] = isFavorite
        revision += 1
    }

    /// Undo of a failed optimistic change: restore what was there before
    /// (`previous == nil` → no override).
    public mutating func restore(_ itemID: String, previous: Bool?) {
        values[itemID] = previous
        revision += 1
    }

    public mutating func reset() {
        values = [:]
        revision += 1
    }
}

/// Sizing rules for artwork grids, kept out of the views so they are
/// testable and identical on every grid screen. The views hand the minimum
/// item width to an adaptive grid, which fits as many columns as possible
/// (2 on a phone, more on an iPad).
public enum AdaptiveGrid {
    /// Width beyond which lists and detail headers stop growing (iPad,
    /// landscape): long lines of text are hard to scan.
    public static let readableContentWidth: Double = 720

    /// The smallest width an item may have; larger at accessibility text
    /// sizes so two-line captions stay readable.
    public static func minimumItemWidth(base: Double = 150, isAccessibilitySize: Bool) -> Double {
        isAccessibilitySize ? base * 1.8 : base
    }
}

/// Accessibility summaries for rows, so VoiceOver reads one sentence per row
/// ("Title, Artist, 3 minutes, 5 seconds") instead of three fragments.
public enum AccessibilityText {
    /// - Parameter detail: free-form second line (e.g. "Artist · Album")
    ///   read after the title; replaces the artist/album flags when set.
    public static func trackRow(
        _ track: Track,
        showsArtist: Bool = true,
        showsAlbum: Bool = false,
        trackNumber: Int? = nil,
        detail: String? = nil
    ) -> String {
        var parts: [String] = []
        if let trackNumber { parts.append("Track \(trackNumber)") }
        parts.append(track.title)
        if let detail {
            if !detail.isEmpty { parts.append(detail) }
        } else {
            if showsArtist, !track.artistName.isEmpty { parts.append(track.artistName) }
            if showsAlbum, let album = track.albumName, !album.isEmpty { parts.append(album) }
        }
        if track.duration >= 1 { parts.append(DurationText.spoken(track.duration)) }
        return parts.joined(separator: ", ")
    }

    public static func album(_ album: Album) -> String {
        var parts = [album.title]
        if !album.artistName.isEmpty { parts.append(album.artistName) }
        if let year = album.productionYear, year > 0 { parts.append(String(year)) }
        return parts.joined(separator: ", ")
    }

    public static func playlist(_ playlist: Playlist) -> String {
        var parts = [playlist.name]
        if let count = playlist.trackCount { parts.append(DurationText.plural(count, "song")) }
        return parts.joined(separator: ", ")
    }
}

/// Which slice of a long, partially loaded list becomes the play queue when
/// a row is tapped. Queuing every loaded row of a 50,000-song list would
/// make each queue operation crawl; a window around the tapped row keeps
/// "previous" working and gives hours of music ahead.
public enum PlayQueueWindow {
    public static func around(index: Int, count: Int, before: Int = 100, after: Int = 400) -> (range: Range<Int>, startAt: Int) {
        guard count > 0 else { return (0..<0, 0) }
        let index = min(max(0, index), count - 1)
        let lower = max(0, index - max(0, before))
        let upper = min(count, index + max(0, after) + 1)
        return (lower..<upper, index - lower)
    }

    /// The windowed tracks and the position of the tapped one inside them.
    public static func queue(from tracks: [Track], tappedIndex: Int) -> PlayQueue? {
        guard !tracks.isEmpty else { return nil }
        let window = around(index: tappedIndex, count: tracks.count)
        return PlayQueue(tracks: Array(tracks[window.range]), startAt: window.startAt)
    }
}

/// A hue derived from a name that is the same on every launch and device
/// (`String.hashValue` is seeded per process, so it is not).
public enum StableColor {
    /// Hue in 0..<1.
    public static func hue(for name: String) -> Double {
        // FNV-1a over the UTF-8 bytes.
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }
}
