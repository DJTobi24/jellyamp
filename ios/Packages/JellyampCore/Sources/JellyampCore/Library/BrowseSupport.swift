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

/// Column maths for artwork grids, kept out of the views so the breakpoints
/// are testable and identical on every grid screen.
public enum AdaptiveGrid {
    /// Width beyond which lists and detail headers stop growing (iPad,
    /// landscape): long lines of text are hard to scan.
    public static let readableContentWidth: Double = 720

    /// Number of columns that fit. At accessibility text sizes captions under
    /// narrow covers would truncate after a few letters, so the minimum item
    /// width grows and phones fall back to a single column (a list).
    public static func columnCount(
        availableWidth: Double,
        minimumItemWidth: Double = 150,
        spacing: Double = 12,
        isAccessibilitySize: Bool = false
    ) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 1 }
        let minimum = isAccessibilitySize ? minimumItemWidth * 1.8 : minimumItemWidth
        let count = Int((availableWidth + spacing) / (minimum + spacing))
        return min(max(1, count), 8)
    }

    /// Width of one item for a given column count.
    public static func itemWidth(availableWidth: Double, columns: Int, spacing: Double = 12) -> Double {
        let columns = max(1, columns)
        return max(0, (availableWidth - spacing * Double(columns - 1)) / Double(columns))
    }
}

/// Accessibility summaries for rows, so VoiceOver reads one sentence per row
/// ("Title, Artist, 3 minutes, 5 seconds") instead of three fragments.
public enum AccessibilityText {
    public static func trackRow(_ track: Track, showsArtist: Bool = true, showsAlbum: Bool = false, trackNumber: Int? = nil) -> String {
        var parts: [String] = []
        if let trackNumber { parts.append("Track \(trackNumber)") }
        parts.append(track.title)
        if showsArtist, !track.artistName.isEmpty { parts.append(track.artistName) }
        if showsAlbum, let album = track.albumName, !album.isEmpty { parts.append(album) }
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
