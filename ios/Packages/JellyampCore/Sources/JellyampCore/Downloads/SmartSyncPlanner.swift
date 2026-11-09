import Foundation

/// Rules for automatic offline syncing ("smart sync" in Plexamp terms).
///
/// Decoding is tolerant like `AppSettings`: rules added later default instead
/// of invalidating what a user already saved.
public struct SmartSyncRules: Codable, Equatable, Sendable {
    /// Keep all favorite tracks downloaded.
    public var autoDownloadFavorites: Bool
    /// Keep the tracks of the newest N auto-mixes downloaded (0 = off).
    public var keepLatestMixes: Int
    /// Keep every track of the favorite albums downloaded.
    public var autoDownloadFavoriteAlbums: Bool
    /// Upper bound for automatically synced music in megabytes (0 = no limit).
    /// Manually downloaded music never counts against it.
    public var maxStorageMB: Int

    public init(
        autoDownloadFavorites: Bool = false,
        keepLatestMixes: Int = 0,
        autoDownloadFavoriteAlbums: Bool = false,
        maxStorageMB: Int = 0
    ) {
        self.autoDownloadFavorites = autoDownloadFavorites
        self.keepLatestMixes = keepLatestMixes
        self.autoDownloadFavoriteAlbums = autoDownloadFavoriteAlbums
        self.maxStorageMB = maxStorageMB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SmartSyncRules()
        autoDownloadFavorites = try c.decodeIfPresent(Bool.self, forKey: .autoDownloadFavorites) ?? d.autoDownloadFavorites
        keepLatestMixes = try c.decodeIfPresent(Int.self, forKey: .keepLatestMixes) ?? d.keepLatestMixes
        autoDownloadFavoriteAlbums =
            try c.decodeIfPresent(Bool.self, forKey: .autoDownloadFavoriteAlbums) ?? d.autoDownloadFavoriteAlbums
        maxStorageMB = try c.decodeIfPresent(Int.self, forKey: .maxStorageMB) ?? d.maxStorageMB
    }

    /// Whether any rule asks for content. With all rules off, smart sync only
    /// cleans up what it downloaded earlier.
    public var isEnabled: Bool {
        autoDownloadFavorites || autoDownloadFavoriteAlbums || keepLatestMixes > 0
    }

    public var maxStorageBytes: Int64? {
        maxStorageMB > 0 ? Int64(maxStorageMB) * 1_048_576 : nil
    }
}

/// Computes which tracks to fetch and which auto-synced ones to evict.
/// Pure function of rules + current state; the DownloadManager executes it.
public struct SmartSyncPlanner: Sendable {
    public var rules: SmartSyncRules

    public init(rules: SmartSyncRules) {
        self.rules = rules
    }

    public struct Plan: Equatable, Sendable {
        /// Track IDs to enqueue for download, in priority order.
        public var download: [String]
        /// Previously auto-synced track IDs no longer covered by any rule.
        public var evict: [String]
        /// Everything the rules cover within the storage cap, in priority
        /// order — what the smart-sync pin should reference afterwards.
        public var desired: [String]
        /// Covered by a rule but left out because of the storage cap.
        public var skippedForStorage: [String]

        public init(download: [String], evict: [String], desired: [String] = [], skippedForStorage: [String] = []) {
            self.download = download
            self.evict = evict
            self.desired = desired
            self.skippedForStorage = skippedForStorage
        }
    }

    /// - Parameters:
    ///   - favoriteIDs: the user's favorite tracks
    ///   - favoriteAlbumTrackIDs: the tracks of the user's favorite albums
    ///   - mixes: auto-mixes, newest first
    ///   - downloadedIDs: everything currently on disk or queued
    ///   - pinnedIDs: tracks the user downloaded manually — never evicted here
    ///   - estimatedBytes: size per track, for the storage cap (unknown = 0)
    ///
    /// Priority when the cap is too small for everything: favorite tracks,
    /// then favorite albums, then mixes (newest first). Manually pinned tracks
    /// are on disk anyway and therefore free.
    public func plan(
        favoriteIDs: [String],
        favoriteAlbumTrackIDs: [String] = [],
        mixes: [MixDescriptor],
        downloadedIDs: Set<String>,
        pinnedIDs: Set<String>,
        estimatedBytes: [String: Int64] = [:]
    ) -> Plan {
        var covered: [String] = []
        var seen = Set<String>()
        func want(_ id: String) {
            if seen.insert(id).inserted {
                covered.append(id)
            }
        }
        if rules.autoDownloadFavorites {
            favoriteIDs.forEach(want)
        }
        if rules.autoDownloadFavoriteAlbums {
            favoriteAlbumTrackIDs.forEach(want)
        }
        for mix in mixes.prefix(max(rules.keepLatestMixes, 0)) {
            mix.itemIDs.forEach(want)
        }

        var desired: [String] = []
        var skipped: [String] = []
        if let cap = rules.maxStorageBytes {
            var used: Int64 = 0
            var isFull = false
            for id in covered {
                let cost = pinnedIDs.contains(id) ? 0 : max(estimatedBytes[id] ?? 0, 0)
                // Strict cut-off (no first-fit): what is kept must not depend
                // on which later track happens to be small enough.
                if cost > 0, isFull || used + cost > cap {
                    isFull = true
                    skipped.append(id)
                } else {
                    used += cost
                    desired.append(id)
                }
            }
        } else {
            desired = covered
        }

        let keep = Set(desired)
        let download = desired.filter { !downloadedIDs.contains($0) }
        let evict = downloadedIDs
            .subtracting(keep)
            .subtracting(pinnedIDs)
            .sorted()
        return Plan(download: download, evict: evict, desired: desired, skippedForStorage: skipped)
    }
}
