import Foundation

/// Where a download is in its lifecycle. Persisted with the index so the queue
/// survives app termination.
public enum DownloadPhase: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    /// Failed transiently; will be retried automatically at `retryAt`.
    case waitingToRetry
    /// Gave up (permanent error or retries exhausted); needs a manual retry.
    case failed
    case complete
}

/// Why a download attempt failed. Decides between automatic retry and giving
/// up, and is what the UI explains to the user.
public enum DownloadFailure: String, Codable, Sendable, Equatable {
    case network
    case timeout
    case serverError
    case rateLimited
    case unauthorized
    /// Jellyfin answers 403 on `/Items/{id}/Download` when the administrator
    /// disabled "Allow media downloads" for the user.
    case forbidden
    case notFound
    case badResponse
    case insufficientStorage
    case fileSystem

    /// Transient failures are retried with backoff; the rest need the user
    /// (or the server admin) to change something first.
    public var isTransient: Bool {
        switch self {
        case .network, .timeout, .serverError, .rateLimited:
            return true
        case .unauthorized, .forbidden, .notFound, .badResponse, .insufficientStorage, .fileSystem:
            return false
        }
    }

    /// Classifies an HTTP status of the download response; nil means success.
    public static func from(httpStatus status: Int) -> DownloadFailure? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404, 410: return .notFound
        case 408: return .timeout
        case 429: return .rateLimited
        case 500..<600: return .serverError
        default: return .badResponse
        }
    }
}

/// One track in the download index: the track's metadata (so it can be
/// browsed and played without the server), its file and its queue state.
public struct DownloadEntry: Codable, Equatable, Sendable, Identifiable {
    public var track: Track
    /// File name inside the downloads directory.
    public var fileName: String
    public var phase: DownloadPhase
    /// Enqueue order; lower starts first.
    public var sequence: Int
    /// Size on disk once complete.
    public var bytes: Int64
    /// Attempts started since the last manual (re)queue.
    public var attempts: Int
    public var failure: DownloadFailure?
    public var retryAt: Date?
    public var addedAt: Date
    public var completedAt: Date?

    public var id: String { track.id }

    public init(
        track: Track,
        fileName: String,
        phase: DownloadPhase = .queued,
        sequence: Int = 0,
        bytes: Int64 = 0,
        attempts: Int = 0,
        failure: DownloadFailure? = nil,
        retryAt: Date? = nil,
        addedAt: Date,
        completedAt: Date? = nil
    ) {
        self.track = track
        self.fileName = fileName
        self.phase = phase
        self.sequence = sequence
        self.bytes = bytes
        self.attempts = attempts
        self.failure = failure
        self.retryAt = retryAt
        self.addedAt = addedAt
        self.completedAt = completedAt
    }
}

/// The reason a set of tracks is kept offline. A track stays downloaded for as
/// long as at least one pin references it.
public struct DownloadPin: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case album
        case playlist
        case artist
        case track
        /// Maintained by smart sync (favorites, mixes); never user-pinned.
        case smartSync
    }

    public var kind: Kind
    /// Jellyfin item id of the album / playlist / artist / track.
    public var itemID: String
    public var title: String
    public var subtitle: String?
    public var imageTag: String?
    /// Full album metadata for album pins, so offline browsing shows the real
    /// album artist / year instead of values guessed from the tracks.
    public var album: Album?
    /// Ordered (playlist order matters), without duplicates.
    public var trackIDs: [String]
    public var addedAt: Date

    public var id: String { Self.id(kind: kind, itemID: itemID) }
    public var isAutomatic: Bool { kind == .smartSync }

    public static let smartSyncItemID = "smart-sync"

    public static func id(kind: Kind, itemID: String) -> String {
        "\(kind.rawValue):\(itemID)"
    }

    public init(
        kind: Kind,
        itemID: String,
        title: String,
        subtitle: String? = nil,
        imageTag: String? = nil,
        album: Album? = nil,
        trackIDs: [String] = [],
        addedAt: Date
    ) {
        self.kind = kind
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.imageTag = imageTag
        self.album = album
        self.trackIDs = trackIDs
        self.addedAt = addedAt
    }

    public static func album(_ album: Album, now: Date) -> DownloadPin {
        DownloadPin(
            kind: .album, itemID: album.id, title: album.title, subtitle: album.artistName,
            imageTag: album.imageTag, album: album, addedAt: now
        )
    }

    public static func playlist(_ playlist: Playlist, now: Date) -> DownloadPin {
        DownloadPin(kind: .playlist, itemID: playlist.id, title: playlist.name, imageTag: playlist.imageTag, addedAt: now)
    }

    public static func artist(_ artist: Artist, now: Date) -> DownloadPin {
        DownloadPin(kind: .artist, itemID: artist.id, title: artist.name, imageTag: artist.imageTag, addedAt: now)
    }

    public static func track(_ track: Track, now: Date) -> DownloadPin {
        DownloadPin(
            kind: .track, itemID: track.id, title: track.title, subtitle: track.artistName,
            imageTag: track.imageTag, addedAt: now
        )
    }

    public static func smartSync(now: Date) -> DownloadPin {
        DownloadPin(kind: .smartSync, itemID: smartSyncItemID, title: "Smart Sync", addedAt: now)
    }
}

public enum DownloadIndexError: Error, Equatable {
    /// Written by a newer app version; refusing to guess keeps the data intact.
    case unsupportedSchemaVersion(Int)
}

/// The persisted truth about offline content: which tracks, in which state,
/// and which pins keep them. All mutations are pure and return what the app
/// shell must do on disk (files to delete, tracks to fetch).
public struct DownloadIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public private(set) var schemaVersion: Int
    public internal(set) var entries: [String: DownloadEntry]
    public private(set) var pins: [DownloadPin]
    private var nextSequence: Int

    public init() {
        schemaVersion = Self.currentSchemaVersion
        entries = [:]
        pins = []
        nextSequence = 0
    }

    // MARK: Persistence

    /// Decodes the current schema, or migrates the pre-collection index (a bare
    /// JSON array of `Track`s, all of them complete and individually pinned).
    public static func decode(from data: Data, now: Date = Date()) throws -> DownloadIndex {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([Track].self, from: data) {
            return migrated(fromLegacyTracks: legacy, now: now)
        }
        let index = try decoder.decode(DownloadIndex.self, from: data)
        guard index.schemaVersion <= currentSchemaVersion else {
            throw DownloadIndexError.unsupportedSchemaVersion(index.schemaVersion)
        }
        return index
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Schema 1 → 2. Files keep their legacy names (`<id>.<container>`), so
    /// nothing has to be renamed on disk. Sizes are unknown here; the app
    /// shell's reconcile pass fills them in from the file system.
    public static func migrated(fromLegacyTracks tracks: [Track], now: Date) -> DownloadIndex {
        var index = DownloadIndex()
        for track in tracks where index.entries[track.id] == nil {
            index.entries[track.id] = DownloadEntry(
                track: track,
                fileName: DownloadFileNaming.legacyFileName(for: track),
                phase: .complete,
                sequence: index.takeSequence(),
                addedAt: now,
                completedAt: now
            )
            var pin = DownloadPin.track(track, now: now)
            pin.trackIDs = [track.id]
            index.pins.append(pin)
        }
        return index
    }

    // MARK: Queries

    public func entry(for trackID: String) -> DownloadEntry? { entries[trackID] }

    public func pin(id: String) -> DownloadPin? { pins.first { $0.id == id } }

    /// All entries in enqueue order.
    public var orderedEntries: [DownloadEntry] {
        entries.values.sorted { $0.sequence < $1.sequence }
    }

    public var completeEntries: [DownloadEntry] {
        orderedEntries.filter { $0.phase == .complete }
    }

    /// Everything not finished yet, in the order it will be worked on.
    public var pendingEntries: [DownloadEntry] {
        orderedEntries.filter { $0.phase != .complete }
    }

    public func isComplete(_ trackID: String) -> Bool { entries[trackID]?.phase == .complete }

    public var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + ($1.phase == .complete ? $1.bytes : 0) }
    }

    public func pins(containing trackID: String) -> [DownloadPin] {
        pins.filter { $0.trackIDs.contains(trackID) }
    }

    /// Tracks kept by at least one user-created pin. Smart sync never evicts these.
    public var manuallyPinnedTrackIDs: Set<String> {
        var ids = Set<String>()
        for pin in pins where !pin.isAutomatic { ids.formUnion(pin.trackIDs) }
        return ids
    }

    /// Tracks the smart-sync pin currently covers.
    public var smartSyncTrackIDs: [String] {
        pin(id: DownloadPin.id(kind: .smartSync, itemID: DownloadPin.smartSyncItemID))?.trackIDs ?? []
    }

    /// The pin's tracks in pin order (missing entries skipped).
    public func entries(forPin pinID: String) -> [DownloadEntry] {
        guard let pin = pin(id: pinID) else { return [] }
        return pin.trackIDs.compactMap { entries[$0] }
    }

    public struct Progress: Equatable, Sendable {
        public var complete: Int
        public var total: Int
        public var bytes: Int64

        public var isComplete: Bool { total > 0 && complete == total }
        public var fraction: Double { total == 0 ? 0 : Double(complete) / Double(total) }
    }

    public func progress(forTrackIDs ids: [String]) -> Progress {
        var progress = Progress(complete: 0, total: 0, bytes: 0)
        for id in ids {
            guard let entry = entries[id] else { continue }
            progress.total += 1
            if entry.phase == .complete {
                progress.complete += 1
                progress.bytes += entry.bytes
            }
        }
        return progress
    }

    public func progress(forPin pinID: String) -> Progress {
        progress(forTrackIDs: pin(id: pinID)?.trackIDs ?? [])
    }

    /// Item ids whose cover should be kept on disk: every album of a
    /// downloaded track, artists, and the pinned playlists / artists.
    public var referencedArtworkItemIDs: Set<String> {
        var ids = Set<String>()
        for entry in entries.values {
            ids.insert(entry.track.albumID ?? entry.track.id)
            if let artistID = entry.track.artistID { ids.insert(artistID) }
        }
        for pin in pins where pin.kind != .smartSync && pin.kind != .track {
            ids.insert(pin.itemID)
        }
        return ids
    }

    // MARK: Pinning

    public struct Change: Equatable, Sendable {
        /// Track ids that were newly queued.
        public var queued: [String] = []
        /// Entries dropped from the index; their files must be deleted and any
        /// running transfer cancelled.
        public var removed: [DownloadEntry] = []

        public init(queued: [String] = [], removed: [DownloadEntry] = []) {
            self.queued = queued
            self.removed = removed
        }
    }

    /// Creates or updates a pin so it covers exactly `tracks` (in that order).
    /// New tracks are queued; tracks the pin no longer covers are dropped
    /// unless another pin still needs them. Re-pinning refreshes the stored
    /// metadata, which is how playlists follow server-side edits.
    @discardableResult
    public mutating func setPin(_ pin: DownloadPin, tracks: [Track], now: Date) -> Change {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.id).inserted }
        var updated = pin
        updated.trackIDs = unique.map(\.id)
        if let existing = pins.firstIndex(where: { $0.id == pin.id }) {
            updated.addedAt = pins[existing].addedAt
            pins[existing] = updated
        } else {
            pins.append(updated)
        }

        var change = Change()
        for track in unique {
            if var entry = entries[track.id] {
                // Keep `playlistEntryID` out of the shared entry: it belongs to
                // one playlist, while the entry can be shared by many pins.
                var fresh = track
                fresh.playlistEntryID = nil
                entry.track = fresh
                entries[track.id] = entry
            } else {
                var fresh = track
                fresh.playlistEntryID = nil
                entries[track.id] = DownloadEntry(
                    track: fresh,
                    fileName: DownloadFileNaming.fileName(for: track),
                    sequence: takeSequence(),
                    addedAt: now
                )
                change.queued.append(track.id)
            }
        }
        change.removed = sweepUnreferenced()
        return change
    }

    /// Removes a pin; its tracks go too unless another pin still needs them.
    @discardableResult
    public mutating func removePin(id: String) -> Change {
        pins.removeAll { $0.id == id }
        return Change(removed: sweepUnreferenced())
    }

    /// Explicit "Remove Download" on one track: it is taken out of every pin
    /// (a playlist re-sync may bring it back) and dropped.
    @discardableResult
    public mutating func removeTrack(id trackID: String) -> Change {
        for index in pins.indices {
            pins[index].trackIDs.removeAll { $0 == trackID }
        }
        pins.removeAll { $0.trackIDs.isEmpty && !$0.isAutomatic }
        return Change(removed: sweepUnreferenced())
    }

    /// "Remove album" from the downloads list: drops the album pin and the
    /// single-track pins of its tracks. Tracks a playlist, artist or smart
    /// sync pin still needs stay on disk.
    @discardableResult
    public mutating func removeAlbum(id albumID: String) -> Change {
        pins.removeAll { pin in
            switch pin.kind {
            case .album:
                return pin.itemID == albumID
            case .track:
                return entries[pin.itemID]?.track.albumID == albumID
            case .playlist, .artist, .smartSync:
                return false
            }
        }
        return Change(removed: sweepUnreferenced())
    }

    @discardableResult
    public mutating func removeAll() -> Change {
        let removed = orderedEntries
        entries = [:]
        pins = []
        return Change(removed: removed)
    }

    private mutating func sweepUnreferenced() -> [DownloadEntry] {
        var referenced = Set<String>()
        for pin in pins { referenced.formUnion(pin.trackIDs) }
        let orphans = orderedEntries.filter { !referenced.contains($0.id) }
        for orphan in orphans { entries[orphan.id] = nil }
        return orphans
    }

    mutating func takeSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }
}

/// Infers the right pins for a bare list of tracks (the "Download" action of a
/// context menu knows the tracks but not what they were listed under).
public enum DownloadPinInference {
    /// Two or more tracks that all belong to one album are treated as "this
    /// album"; anything else becomes individual track pins.
    public static func singleAlbum(in tracks: [Track]) -> Album? {
        guard tracks.count >= 2, let first = tracks.first, let albumID = first.albumID else { return nil }
        guard tracks.allSatisfy({ $0.albumID == albumID }) else { return nil }
        return OfflineCatalog.derivedAlbum(id: albumID, tracks: tracks)
    }
}
