import Foundation

/// Rules for automatic offline syncing ("smart sync" in Plexamp terms).
public struct SmartSyncRules: Codable, Equatable, Sendable {
    /// Keep all favorite tracks downloaded.
    public var autoDownloadFavorites: Bool
    /// Keep the tracks of the newest N auto-mixes downloaded (0 = off).
    public var keepLatestMixes: Int

    public init(autoDownloadFavorites: Bool = false, keepLatestMixes: Int = 0) {
        self.autoDownloadFavorites = autoDownloadFavorites
        self.keepLatestMixes = keepLatestMixes
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

        public init(download: [String], evict: [String]) {
            self.download = download
            self.evict = evict
        }
    }

    /// - Parameters:
    ///   - favoriteIDs: the user's favorite tracks
    ///   - mixes: auto-mixes, newest first
    ///   - downloadedIDs: everything currently on disk
    ///   - pinnedIDs: tracks the user downloaded manually — never evicted here
    public func plan(
        favoriteIDs: [String],
        mixes: [MixDescriptor],
        downloadedIDs: Set<String>,
        pinnedIDs: Set<String>
    ) -> Plan {
        var desired: [String] = []
        var seen = Set<String>()
        func want(_ id: String) {
            if seen.insert(id).inserted {
                desired.append(id)
            }
        }
        if rules.autoDownloadFavorites {
            favoriteIDs.forEach(want)
        }
        for mix in mixes.prefix(rules.keepLatestMixes) {
            mix.itemIDs.forEach(want)
        }
        let download = desired.filter { !downloadedIDs.contains($0) }
        let evict = downloadedIDs
            .subtracting(seen)
            .subtracting(pinnedIDs)
            .sorted()
        return Plan(download: download, evict: evict)
    }
}
