import Foundation

/// Where an endless queue gets its next candidates from. The app shell builds
/// one per station (sonic provider, Jellyfin random-by-genre/decade, …);
/// tests use canned closures.
public struct RadioSource: Sendable {
    public struct Request: Equatable, Sendable {
        /// How many candidates to return at most. Grows with the number of
        /// tracks already issued so deterministic (ranked) sources reach past
        /// what was already played.
        public var count: Int
        /// The track playing right now, for sources that drift with playback.
        public var currentTrackID: String?

        public init(count: Int, currentTrackID: String? = nil) {
            self.count = count
            self.currentTrackID = currentTrackID
        }
    }

    public var fetch: @Sendable (Request) async throws -> [Track]

    public init(fetch: @escaping @Sendable (Request) async throws -> [Track]) {
        self.fetch = fetch
    }
}

/// State of one playing station: which tracks it has issued, what was played,
/// and how refills are selected (dedupe against queue + history, artist
/// spacing). Pure value type — the app shell performs the fetches and
/// enqueues what this returns.
public struct StationSession: Sendable {
    public let station: StationDefinition
    public var feeder: RadioQueueFeeder
    /// The same artist is kept at least this many tracks apart when the
    /// candidates allow it.
    public var artistSpacing: Int
    /// Upper bound for `fetchCount`, to keep requests and ID lookups sane.
    public var maxFetchCount: Int

    /// Every track ID this station put into the queue.
    public private(set) var issuedIDs: Set<String> = []
    /// Played track IDs, oldest first.
    public private(set) var history: [String] = []

    public init(
        station: StationDefinition,
        feeder: RadioQueueFeeder = RadioQueueFeeder(),
        artistSpacing: Int = 3,
        maxFetchCount: Int = 300
    ) {
        self.station = station
        self.feeder = feeder
        self.artistSpacing = artistSpacing
        self.maxFetchCount = maxFetchCount
    }

    /// Candidates to ask the source for: enough to survive deduplication and
    /// still fill a batch.
    public var fetchCount: Int {
        min(maxFetchCount, issuedIDs.count + feeder.batchSize * 2)
    }

    public func needsRefill(remaining: Int) -> Bool {
        feeder.needsRefill(remaining: remaining)
    }

    public func owns(trackID: String) -> Bool {
        issuedIDs.contains(trackID)
    }

    /// The station stays in charge of the queue while the current track or
    /// anything still queued came from it. Once the user replaced the queue
    /// with something else, it is over.
    public func isStillPlaying(currentTrackID: String?, upNextIDs: [String]) -> Bool {
        if let currentTrackID, owns(trackID: currentTrackID) { return true }
        return upNextIDs.contains(where: issuedIDs.contains)
    }

    public mutating func notePlayed(trackID: String) {
        guard history.last != trackID else { return }
        history.append(trackID)
        let cap = max(feeder.dedupeWindow * 4, 200)
        if history.count > cap { history.removeFirst(history.count - cap) }
    }

    /// First batch when the station starts: nothing queued, nothing played.
    public mutating func initialBatch(from candidates: [Track]) -> [Track] {
        nextBatch(from: candidates, queued: [])
    }

    /// Picks up to `batchSize` fresh tracks for a refill.
    ///
    /// - Parameter queued: the current track followed by everything up next.
    ///
    /// Tracks already queued are never repeated. Recently played ones are
    /// skipped within `dedupeWindow`; if that leaves nothing (small library,
    /// narrow genre) the window is halved until something qualifies, so a
    /// station on a 30-track genre loops instead of stopping.
    public mutating func nextBatch(from candidates: [Track], queued: [Track]) -> [Track] {
        let queuedIDs = queued.map(\.id)
        var selector = feeder
        // Select from the full candidate list first (spacing may reorder),
        // then cut to the batch size.
        selector.batchSize = max(candidates.count, 1)
        var fresh = selector.selectTracks(from: candidates, queuedIDs: queuedIDs, historyIDs: history)
        while fresh.isEmpty, selector.dedupeWindow > 0 {
            selector.dedupeWindow /= 2
            fresh = selector.selectTracks(from: candidates, queuedIDs: queuedIDs, historyIDs: history)
        }
        let spaced = ArtistSpacer.spaced(fresh, after: queued, minimumGap: artistSpacing)
        let batch = Array(spaced.prefix(feeder.batchSize))
        issuedIDs.formUnion(batch.map(\.id))
        return batch
    }
}

/// Reorders candidates so the same artist does not play back-to-back.
public enum ArtistSpacer {
    /// Greedy pass in candidate order: each slot takes the first remaining
    /// track whose artist did not appear within the previous `minimumGap`
    /// slots (counting the tail of `preceding`). When every remaining track
    /// would violate the gap, the gap shrinks for that slot rather than
    /// dropping tracks — order changes, content never does.
    public static func spaced(_ tracks: [Track], after preceding: [Track] = [], minimumGap: Int) -> [Track] {
        guard minimumGap > 0, tracks.count > 1 else { return tracks }
        var remaining = tracks
        var result: [Track] = []
        result.reserveCapacity(tracks.count)
        var recentArtists: [String] = preceding.suffix(minimumGap).map { artistKey($0) }

        while !remaining.isEmpty {
            let index = bestIndex(in: remaining, recentArtists: recentArtists, minimumGap: minimumGap)
            let track = remaining.remove(at: index)
            result.append(track)
            recentArtists.append(artistKey(track))
            if recentArtists.count > minimumGap {
                recentArtists.removeFirst(recentArtists.count - minimumGap)
            }
        }
        return result
    }

    private static func bestIndex(in remaining: [Track], recentArtists: [String], minimumGap: Int) -> Int {
        var gap = minimumGap
        while gap > 0 {
            let blocked = Set(recentArtists.suffix(gap))
            if let index = remaining.firstIndex(where: { !blocked.contains(artistKey($0)) }) {
                return index
            }
            gap -= 1
        }
        return 0
    }

    private static func artistKey(_ track: Track) -> String {
        if let id = track.artistID, !id.isEmpty { return id }
        return track.artistName.lowercased()
    }
}

/// Mixing helpers for stations fed by more than one source.
public enum RadioBlend {
    /// Interleaves two candidate lists — `primaryRun` items from `primary`,
    /// then one from `secondary` — dropping duplicates. Used by artist radio:
    /// similar tracks carry the station, the artist's own tracks keep it
    /// anchored.
    public static func interleave(primary: [Track], secondary: [Track], primaryRun: Int = 2) -> [Track] {
        let run = max(primaryRun, 1)
        var seen = Set<String>()
        var result: [Track] = []
        var primaryIndex = 0
        var secondaryIndex = 0

        while primaryIndex < primary.count || secondaryIndex < secondary.count {
            var taken = 0
            while taken < run, primaryIndex < primary.count {
                let track = primary[primaryIndex]
                primaryIndex += 1
                taken += 1
                if seen.insert(track.id).inserted { result.append(track) }
            }
            if secondaryIndex < secondary.count {
                let track = secondary[secondaryIndex]
                secondaryIndex += 1
                if seen.insert(track.id).inserted { result.append(track) }
            }
        }
        return result
    }
}

/// Runs one fetch-and-select round for a station. Kept in Core so the
/// refill behaviour (deeper retry for ranked sources) is tested without the
/// app shell.
public enum StationRefill {
    /// Fetches candidates and returns the tracks to enqueue (possibly none).
    /// If the first fetch yields nothing fresh, asks once more for the
    /// source's maximum — ranked sources then reach beyond what was played.
    public static func nextTracks(
        session: inout StationSession,
        source: RadioSource,
        queued: [Track],
        currentTrackID: String?
    ) async throws -> [Track] {
        var working = session
        let firstCount = working.fetchCount
        let candidates = try await source.fetch(RadioSource.Request(count: firstCount, currentTrackID: currentTrackID))
        var batch = working.nextBatch(from: candidates, queued: queued)
        if batch.isEmpty, firstCount < working.maxFetchCount {
            let deeper = try await source.fetch(
                RadioSource.Request(count: working.maxFetchCount, currentTrackID: currentTrackID)
            )
            batch = working.nextBatch(from: deeper, queued: queued)
        }
        session = working
        return batch
    }
}
