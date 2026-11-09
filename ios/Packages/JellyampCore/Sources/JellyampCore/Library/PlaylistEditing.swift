import Foundation

/// A playlist row with an identity that stays unique when the playlist holds
/// the same track more than once.
public struct PlaylistRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var track: Track

    public init(id: String, track: Track) {
        self.id = id
        self.track = track
    }
}

/// One `POST /Playlists/{id}/Items/{entryID}/Move/{index}` call.
public struct PlaylistMoveOperation: Equatable, Sendable {
    public var entryID: String
    public var index: Int

    public init(entryID: String, index: Int) {
        self.entryID = entryID
        self.index = index
    }
}

/// Pure playlist editing: what the list looks like after an edit (applied
/// optimistically) and which server calls bring the server there.
public enum PlaylistEditing {
    /// Row identities: the server's playlist entry id, or — for entries
    /// without one — the track id plus its occurrence number, so a track that
    /// is in the playlist twice still yields two distinct rows.
    public static func rows(for tracks: [Track]) -> [PlaylistRow] {
        var occurrences: [String: Int] = [:]
        var used: Set<String> = []
        return tracks.map { track in
            var id = track.playlistEntryID ?? ""
            if id.isEmpty || used.contains(id) {
                let count = occurrences[track.id, default: 0]
                occurrences[track.id] = count + 1
                id = "\(track.id)#\(count)"
            }
            used.insert(id)
            return PlaylistRow(id: id, track: track)
        }
    }

    /// Removes rows. Returns the remaining tracks and the entry ids to delete
    /// on the server (rows without an entry id cannot be deleted there).
    public static func removing(_ offsets: IndexSet, from tracks: [Track]) -> (remaining: [Track], entryIDs: [String]) {
        let valid = offsets.filter { tracks.indices.contains($0) }
        let entryIDs = valid.compactMap { tracks[$0].playlistEntryID }
        let remaining = tracks.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        return (remaining, entryIDs)
    }

    /// Moves one row using SwiftUI's `onMove` convention (`destination` is
    /// the insertion offset in the list *before* the move). Returns the new
    /// order and the row's final index, or nil when nothing changes.
    public static func moving(_ tracks: [Track], from source: Int, toOffset destination: Int) -> (result: [Track], finalIndex: Int)? {
        guard tracks.indices.contains(source), destination >= 0, destination <= tracks.count else { return nil }
        let finalIndex = destination > source ? destination - 1 : destination
        guard finalIndex != source else { return nil }
        var result = tracks
        let moved = result.remove(at: source)
        result.insert(moved, at: finalIndex)
        return (result, finalIndex)
    }

    /// Finds the single move that turns `current` into `desired`, if the two
    /// orders differ by exactly one moved element.
    public static func singleMove(from current: [String], to desired: [String]) -> (id: String, from: Int, to: Int)? {
        guard current.count == desired.count, current != desired else { return nil }
        guard let low = current.indices.first(where: { current[$0] != desired[$0] }),
              let high = current.indices.last(where: { current[$0] != desired[$0] }) else { return nil }
        // Inside the differing window the moved element travelled from one
        // end to the other; everything else shifted by one.
        var forward = current
        let head = forward.remove(at: low)
        forward.insert(head, at: high)
        if forward == desired { return (head, low, high) }
        var backward = current
        let tail = backward.remove(at: high)
        backward.insert(tail, at: low)
        if backward == desired { return (tail, high, low) }
        return nil
    }

    // MARK: - Jellyfin 10.10 move quirk

    /// What Jellyfin 10.10 actually does with `Move/{requestedIndex}`
    /// (verified against 10.10.7): the item is inserted *after* the item that
    /// currently sits at the requested index when moving down, and after the
    /// one before it when moving up. Consequences: moving down lands one row
    /// too low, and nothing can be moved to the very top directly.
    public static func simulateLegacyServerMove(_ order: [String], id: String, requestedIndex: Int) -> [String] {
        guard let oldIndex = order.firstIndex(of: id), !order.isEmpty else { return order }
        let requested = min(max(0, requestedIndex), order.count - 1)
        let priorIndex = requested > oldIndex ? requested : max(0, requested - 1)
        let insertionIndex = priorIndex + 1
        var result = order
        result.remove(at: oldIndex)
        result.insert(id, at: min(insertionIndex, result.count))
        return result
    }

    /// Calls that turn `current` into `desired` on a server with the 10.10
    /// behaviour, or nil when the two orders differ by more than one move.
    /// Used as the correction step when the straightforward request did not
    /// produce the expected order.
    public static func legacyMoveOperations(current: [String], desired: [String]) -> [PlaylistMoveOperation]? {
        if current == desired { return [] }
        guard let move = singleMove(from: current, to: desired) else { return nil }
        let (id, from, to) = move
        let last = current.count - 1
        if to == 0 {
            // Nothing lands on top directly: park the row in second place,
            // then push the old first row down behind it.
            var operations: [PlaylistMoveOperation] = []
            if from > 1 { operations.append(PlaylistMoveOperation(entryID: id, index: 1)) }
            operations.append(PlaylistMoveOperation(entryID: current[0], index: 0))
            return operations
        }
        if to < from {
            return [PlaylistMoveOperation(entryID: id, index: to)]
        }
        if to == last {
            return [PlaylistMoveOperation(entryID: id, index: to)]
        }
        if to > from + 1 {
            return [PlaylistMoveOperation(entryID: id, index: to - 1)]
        }
        // One step down (not onto the last row).
        if from == 0 {
            return [PlaylistMoveOperation(entryID: id, index: 0)]
        }
        return [PlaylistMoveOperation(entryID: current[from + 1], index: from)]
    }
}
