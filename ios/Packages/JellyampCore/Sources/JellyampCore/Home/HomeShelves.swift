import Foundation

/// Pure derivations behind the Home shelves; the view model only fetches.
public enum HomeShelves {
    /// "Jump Back In": the distinct albums behind the most recently played
    /// tracks, most recent first. Built from the tracks themselves so the
    /// shelf costs no extra request.
    public static func jumpBackInAlbums(fromRecentTracks tracks: [Track], limit: Int = 12) -> [Album] {
        var seen = Set<String>()
        var albums: [Album] = []
        for track in tracks {
            guard albums.count < limit else { break }
            guard let albumID = track.albumID, !albumID.isEmpty, seen.insert(albumID).inserted else { continue }
            albums.append(
                Album(
                    id: albumID,
                    title: track.albumName ?? track.title,
                    artistName: track.artistName,
                    artistID: track.artistID,
                    productionYear: track.productionYear,
                    genres: track.genres,
                    imageTag: track.imageTag
                )
            )
        }
        return albums
    }

    /// Removes duplicate IDs while keeping the first occurrence — server
    /// responses (mixes, adventures, similar lists) may repeat items.
    public static func uniqued<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID: Hashable {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// What Home should show as a whole, derived from what has loaded so far.
public enum HomeContentState: Equatable, Sendable {
    /// Nothing cached and the first refresh is still running: skeletons.
    case loadingFirstTime
    /// At least one shelf has content.
    case content
    /// Requests succeeded and the library has nothing to show.
    case emptyLibrary
    /// Nothing cached and every request failed (offline, server down).
    case unreachable

    public static func resolve(hasAnyContent: Bool, hasFinishedRefresh: Bool, anyRequestSucceeded: Bool) -> HomeContentState {
        if hasAnyContent { return .content }
        if !hasFinishedRefresh { return .loadingFirstTime }
        return anyRequestSucceeded ? .emptyLibrary : .unreachable
    }
}
