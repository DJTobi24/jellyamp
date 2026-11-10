import Foundation

/// Audio of the demo tracks: raw ADTS AAC (what Jellyfin serves for an
/// `.aac` file), assembled from the bundled loops.
///
/// A loop is a four-second phrase that starts and ends in silence, encoded
/// once by `scripts/demo-audio/make.py`. ADTS frames decode on their own, so
/// a track of any length is simply loops written one after another — no
/// encoder runs on the device, and the stream can be entered at any byte
/// offset (the player's seek) like any other ADTS file.
public enum DemoAudio {
    enum Style: String, CaseIterable, Sendable {
        case ambient, electronic, folk, classical, jazz, rock
    }

    public static let sampleRate = 44_100
    public static let channels = 2
    static let samplesPerFrame = 1024
    static let loopsPerStyle = 4
    /// Frames in every loop file; `make.py` writes them all the same length
    /// (checked by the tests), so a track's duration follows from its loop count.
    static let framesPerLoop = 173

    static func duration(loopCount: Int) -> TimeInterval {
        Double(loopCount * framesPerLoop * samplesPerFrame) / Double(sampleRate)
    }

    /// The complete audio file of a demo track, or nil for an unknown ID.
    public static func data(forTrackID trackID: String) -> Data? {
        guard let track = DemoCatalog.tracks.first(where: { $0.id == trackID }) else { return nil }
        return cache.value(for: trackID) { assemble(track) }
    }

    /// Size of the file without building it more than once.
    static func byteCount(of track: DemoCatalog.Track) -> Int {
        let loops = loopData(for: track.artist.style)
        return arrangement(of: track).reduce(0) { $0 + loops[$1].count }
    }

    /// Average bitrate in bit/s, as Jellyfin would report it.
    static func bitrate(of track: DemoCatalog.Track) -> Int {
        Int((Double(byteCount(of: track)) * 8 / track.duration).rounded())
    }

    /// Which loop plays when. Every track of a style uses the same four
    /// chords but walks through them in its own order, so neighbouring tracks
    /// do not sound identical.
    static func arrangement(of track: DemoCatalog.Track) -> [Int] {
        let patterns: [[Int]] = [
            [0, 1, 2, 3],
            [0, 0, 1, 1, 2, 2, 3, 3],
            [0, 2, 1, 3],
            [0, 1, 0, 3, 2, 1, 2, 3],
            [0, 3, 1, 2],
            [0, 0, 2, 2, 1, 3, 1, 3],
        ]
        let pattern = patterns[Int(DemoRandom.hash(UInt64(track.ordinal)) % UInt64(patterns.count))]
        return (0..<track.loopCount).map { pattern[$0 % pattern.count] }
    }

    private static func assemble(_ track: DemoCatalog.Track) -> Data {
        let loops = loopData(for: track.artist.style)
        var data = Data()
        data.reserveCapacity(byteCount(of: track))
        for index in arrangement(of: track) {
            data.append(loops[index])
        }
        return data
    }

    // MARK: - Loops

    private static let loopStore = LoopStore()

    static func loopData(for style: Style) -> [Data] {
        loopStore.loops(for: style)
    }

    /// Number of ADTS frames in `data`, or nil if it is not a clean sequence
    /// of ADTS frames.
    static func adtsFrameCount(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var offset = 0
        var frames = 0
        while offset < bytes.count {
            guard offset + 7 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { return nil }
            let length = (Int(bytes[offset + 3] & 0x03) << 11) | (Int(bytes[offset + 4]) << 3) | (Int(bytes[offset + 5]) >> 5)
            guard length >= 7, offset + length <= bytes.count else { return nil }
            offset += length
            frames += 1
        }
        return frames
    }

    private final class LoopStore: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [Style: [Data]] = [:]

        func loops(for style: Style) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            if let existing = loaded[style] { return existing }
            let loops = (0..<DemoAudio.loopsPerStyle).map { index -> Data in
                let name = "\(style.rawValue)-\(index)"
                let url = Bundle.module.url(forResource: name, withExtension: "aac", subdirectory: "Loops")
                    ?? Bundle.module.url(forResource: name, withExtension: "aac")
                // A missing resource is a packaging error; an empty loop
                // keeps the app running (the track is then silent and short).
                return url.flatMap { try? Data(contentsOf: $0) } ?? Data()
            }
            loaded[style] = loops
            return loops
        }
    }

    private static let cache = DataCache(limit: 6)
}

/// Small most-recently-used cache for generated payloads (audio files,
/// rendered covers): cheap to rebuild, but asked for repeatedly — the player
/// probes a file's size before it seeks, lists re-request covers.
final class DataCache: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var values: [String: Data] = [:]
    private var order: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    func value(for key: String, make: () -> Data) -> Data {
        lock.lock()
        if let existing = values[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return existing
        }
        lock.unlock()
        // Built outside the lock: two requests for the same key may both
        // build it, which only costs time.
        let fresh = make()
        lock.lock()
        values[key] = fresh
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            values[order.removeFirst()] = nil
        }
        lock.unlock()
        return fresh
    }
}
