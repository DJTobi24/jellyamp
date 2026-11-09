import Foundation

/// Silence compression at the buffer-scheduling boundary.
///
/// The streaming decoder hands every decoded PCM buffer (≈ 0.2 s) to the gate
/// together with its peak; the gate says whether to schedule or drop it. Only
/// buffers that are silent from the first to the last frame are ever dropped,
/// and only once a silent stretch has run longer than the allowed length — so
/// nothing audible is cut, no samples are spliced (no clicks), and short
/// musical pauses stay intact.
public struct SilenceGate: Equatable, Sendable {
    /// Absolute sample amplitude below which a buffer counts as silent
    /// (0.001 ≈ −60 dBFS).
    public var threshold: Float
    /// Silence kept before the first audible buffer of a track.
    public var maxLeadingSilence: TimeInterval
    /// Silence kept inside and at the end of a track.
    public var maxSilence: TimeInterval

    private var silentRun: TimeInterval = 0
    private var heardAudio = false
    /// Total audio dropped so far; the engine adds it to the playback clock
    /// so the scrubber keeps showing the position in the *file*.
    public private(set) var skippedDuration: TimeInterval = 0

    public init(threshold: Float = 0.001, maxLeadingSilence: TimeInterval = 0.5, maxSilence: TimeInterval = 2) {
        self.threshold = threshold
        self.maxLeadingSilence = maxLeadingSilence
        self.maxSilence = maxSilence
    }

    /// - Parameters:
    ///   - peak: largest absolute sample of the buffer, over all channels
    ///   - duration: buffer length in seconds
    /// - Returns: true to schedule the buffer, false to drop it.
    public mutating func shouldSchedule(peak: Float, duration: TimeInterval) -> Bool {
        if peak >= threshold {
            heardAudio = true
            silentRun = 0
            return true
        }
        let allowed = heardAudio ? maxSilence : maxLeadingSilence
        if silentRun + duration <= allowed {
            silentRun += duration
            return true
        }
        skippedDuration += duration
        return false
    }
}
