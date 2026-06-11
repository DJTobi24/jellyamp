import Foundation

/// Decides when and with what an endless queue (radio/station/instant mix)
/// should be refilled, deduplicating against recent history.
public struct RadioQueueFeeder: Sendable {
    /// Refill when fewer than this many tracks remain after the current one.
    public var refillThreshold: Int
    /// How many tracks to request per refill.
    public var batchSize: Int
    /// A track ID played within this many recent tracks is not re-queued.
    public var dedupeWindow: Int

    public init(refillThreshold: Int = 5, batchSize: Int = 25, dedupeWindow: Int = 50) {
        self.refillThreshold = refillThreshold
        self.batchSize = batchSize
        self.dedupeWindow = dedupeWindow
    }

    public func needsRefill(remaining: Int) -> Bool {
        remaining < refillThreshold
    }

    /// Filters fetched candidates against the queue and recent history,
    /// returning at most `batchSize` fresh tracks in candidate order.
    public func selectTracks(from candidates: [Track], queuedIDs: [String], historyIDs: [String]) -> [Track] {
        var seen = Set(queuedIDs)
        seen.formUnion(historyIDs.suffix(dedupeWindow))
        var result: [Track] = []
        for track in candidates where !seen.contains(track.id) {
            seen.insert(track.id)
            result.append(track)
            if result.count == batchSize { break }
        }
        return result
    }
}
