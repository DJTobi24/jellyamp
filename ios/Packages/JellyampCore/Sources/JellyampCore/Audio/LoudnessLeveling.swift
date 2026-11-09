import Foundation

/// EBU R128 measurement of one track (jellyamp-server `GET /api/v1/loudness/{id}`).
public struct MeasuredLoudness: Codable, Equatable, Sendable {
    public var integratedLufs: Double
    /// True peak in dBTP (0 = full scale); nil when unknown.
    public var truePeakDB: Double?

    public init(integratedLufs: Double, truePeakDB: Double? = nil) {
        self.integratedLufs = integratedLufs
        self.truePeakDB = truePeakDB
    }
}

/// The leveling gain chosen for a track, before the user preamp.
public struct LevelingGain: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Jellyfin `NormalizationGain` on the track.
        case trackTag
        /// Derived from a measured LUFS value.
        case measured
        /// One gain shared by a run of consecutive same-album tracks.
        case album
    }

    public var gainDB: Double
    /// Loudest known true peak the gain applies to; nil when unknown.
    public var truePeakDB: Double?
    public var source: Source

    public init(gainDB: Double, truePeakDB: Double? = nil, source: Source) {
        self.gainDB = gainDB
        self.truePeakDB = truePeakDB
        self.source = source
    }
}

/// How a gain is realised in the engine: attenuation on the player node's
/// volume (which cannot exceed 1), boost on the chain's EQ output gain.
public struct GainStage: Equatable, Sendable {
    /// Linear node volume in (0, 1].
    public var volume: Double
    /// Extra boost in dB (≥ 0), only ever granted inside known headroom.
    public var boostDB: Double

    public init(volume: Double = 1, boostDB: Double = 0) {
        self.volume = volume
        self.boostDB = boostDB
    }

    public static let unity = GainStage()
}

/// Decides per-track leveling gain: the track's own tag, else a measured
/// value, and one shared gain for consecutive tracks of the same album so a
/// gapless album never jumps in level between tracks.
public struct LoudnessLeveler: Sendable {
    public var referenceLUFS: Double
    /// Boost is never larger than this, whatever the headroom.
    public var maxBoostDB: Double

    public init(referenceLUFS: Double = LoudnessMath.referenceLUFS, maxBoostDB: Double = 12) {
        self.referenceLUFS = referenceLUFS
        self.maxBoostDB = maxBoostDB
    }

    /// Gain for a track on its own (tag first, measurement second).
    public func trackGain(for track: Track, measured: MeasuredLoudness?) -> LevelingGain? {
        if let tagged = track.normalizationGainDB {
            return LevelingGain(gainDB: tagged, truePeakDB: measured?.truePeakDB, source: .trackTag)
        }
        if let measured {
            return LevelingGain(
                gainDB: LoudnessMath.gainDB(integratedLufs: measured.integratedLufs, reference: referenceLUFS),
                truePeakDB: measured.truePeakDB,
                source: .measured
            )
        }
        return nil
    }

    /// The contiguous run of queue items around `index` that belong to the
    /// same album. A run of one means "not in album context".
    public func albumRun(in tracks: [Track], around index: Int) -> Range<Int> {
        guard tracks.indices.contains(index), let albumID = tracks[index].albumID else {
            return index..<(index + 1)
        }
        var lower = index
        while lower > 0, tracks[lower - 1].albumID == albumID { lower -= 1 }
        var upper = index + 1
        while upper < tracks.count, tracks[upper].albumID == albumID { upper += 1 }
        return lower..<upper
    }

    /// Gain for the queue item at `index`.
    ///
    /// When its neighbours are from the same album, every track of that run
    /// gets the same gain: the album's own gain when known, else the lowest
    /// track gain in the run (so the loudest track lands on the reference and
    /// quieter ones keep their intended distance).
    public func gain(
        at index: Int,
        in tracks: [Track],
        measured: (String) -> MeasuredLoudness?,
        albumGainDB: (String) -> Double?
    ) -> LevelingGain? {
        guard tracks.indices.contains(index) else { return nil }
        let track = tracks[index]
        let run = albumRun(in: tracks, around: index)
        guard run.count > 1, let albumID = track.albumID else {
            return trackGain(for: track, measured: measured(track.id))
        }
        let runGains = tracks[run].map { trackGain(for: $0, measured: measured($0.id)) }
        // A shared peak is only trustworthy when every track in the run has one.
        let peaks = runGains.compactMap { $0?.truePeakDB }
        let sharedPeak = peaks.count == run.count ? peaks.max() : nil
        if let albumGain = albumGainDB(albumID) {
            return LevelingGain(gainDB: albumGain, truePeakDB: sharedPeak, source: .album)
        }
        guard let lowest = runGains.compactMap({ $0?.gainDB }).min() else { return nil }
        return LevelingGain(gainDB: lowest, truePeakDB: sharedPeak, source: .album)
    }

    /// Splits gain + preamp into the node volume and a peak-safe boost.
    ///
    /// Attenuation is always applied. Boost needs proof of headroom: with a
    /// known true peak it is limited so peak + boost stays at or below
    /// 0 dBTP; without one nothing is boosted (a blind boost clips).
    public func stage(for gain: LevelingGain?, preampDB: Double) -> GainStage {
        let requestedDB = (gain?.gainDB ?? 0) + preampDB
        guard requestedDB > 0 else {
            return GainStage(volume: LoudnessMath.linearGain(fromDB: requestedDB), boostDB: 0)
        }
        guard let peak = gain?.truePeakDB else { return .unity }
        let headroomDB = max(0, -peak)
        return GainStage(volume: 1, boostDB: min(requestedDB, headroomDB, maxBoostDB))
    }
}

/// Measured loudness values persisted as one small JSON file, so each track is
/// asked from the sonic server once. Thread-safe.
public final class LoudnessCache: @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: MeasuredLoudness]
    /// Oldest entries are dropped beyond this (the file stays small).
    private let maxEntries: Int

    /// - Parameter fileURL: where to persist; nil keeps the cache in memory.
    public init(fileURL: URL?, maxEntries: Int = 50_000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: MeasuredLoudness].self, from: data) {
            entries = stored
        } else {
            entries = [:]
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func value(for trackID: String) -> MeasuredLoudness? {
        lock.lock(); defer { lock.unlock() }
        return entries[trackID]
    }

    public func store(_ value: MeasuredLoudness, for trackID: String) {
        store([trackID: value])
    }

    public func store(_ values: [String: MeasuredLoudness]) {
        guard !values.isEmpty else { return }
        lock.lock()
        entries.merge(values) { _, new in new }
        if entries.count > maxEntries {
            // No recency information is kept; dropping arbitrary entries only
            // costs a re-fetch.
            let evictable = entries.keys.filter { values[$0] == nil }
            for key in evictable.prefix(entries.count - maxEntries) {
                entries.removeValue(forKey: key)
            }
        }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    public func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func persist(_ snapshot: [String: MeasuredLoudness]) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
