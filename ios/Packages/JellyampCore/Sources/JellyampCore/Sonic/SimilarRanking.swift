import Foundation

/// Ordering/cleanup of similarity results before they are resolved to
/// library items and shown ("Sonically Similar" sections).
public enum SimilarRanking {
    /// IDs ordered by ascending distance (stable for ties, so rank-as-distance
    /// from the Jellyfin fallback keeps its order), without the seed itself
    /// and without duplicates, capped at `limit`.
    public static func orderedIDs(
        from results: [(itemID: String, distance: Double)],
        excluding seedID: String,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let sorted = results.enumerated().sorted { lhs, rhs in
            if lhs.element.distance != rhs.element.distance {
                return lhs.element.distance < rhs.element.distance
            }
            return lhs.offset < rhs.offset
        }
        var seen: Set<String> = [seedID]
        var ids: [String] = []
        for entry in sorted {
            guard ids.count < limit else { break }
            if seen.insert(entry.element.itemID).inserted {
                ids.append(entry.element.itemID)
            }
        }
        return ids
    }

    /// Puts resolved items back into the ranked order; unresolvable IDs drop
    /// out (the library returns items in its own order, and only those the
    /// user may see).
    public static func ordered<Item: Identifiable>(_ items: [Item], byIDs ids: [String]) -> [Item] where Item.ID == String {
        var byID: [String: Item] = [:]
        for item in items where byID[item.id] == nil {
            byID[item.id] = item
        }
        return ids.compactMap { byID[$0] }
    }

    /// Similar tracks for display: drops other tracks of the seed's album so
    /// the section doesn't just repeat the album the user is looking at.
    public static func excludingAlbum(_ tracks: [Track], albumID: String?) -> [Track] {
        guard let albumID, !albumID.isEmpty else { return tracks }
        return tracks.filter { $0.albumID != albumID }
    }
}
