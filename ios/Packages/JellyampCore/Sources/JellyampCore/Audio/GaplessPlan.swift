import Foundation

/// Per-track schedule the audio engine executes: which frames to play and
/// where the fade windows sit. Produced from `SilenceTrimmer` output plus a
/// `SweetFadePlanner.Decision`; consumed by `TrackSchedulerNode`.
public struct GaplessPlan: Equatable, Sendable {
    public var trackID: String
    public var sampleRate: Double
    /// First frame to schedule (silence-trimmed).
    public var startFrame: Int
    /// One past the last frame to schedule.
    public var endFrame: Int
    /// Seconds the *next* track overlaps into this one's tail. 0 = butt join.
    public var fadeOutOverlap: TimeInterval
    /// Seconds this track fades in under the previous one's tail.
    public var fadeInOverlap: TimeInterval

    public init(
        trackID: String,
        sampleRate: Double,
        startFrame: Int,
        endFrame: Int,
        fadeOutOverlap: TimeInterval = 0,
        fadeInOverlap: TimeInterval = 0
    ) {
        self.trackID = trackID
        self.sampleRate = sampleRate
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.fadeOutOverlap = fadeOutOverlap
        self.fadeInOverlap = fadeInOverlap
    }

    public var frameCount: Int { max(0, endFrame - startFrame) }

    public var playableDuration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    /// Frame (within this track's trimmed range) where the next track should start.
    public var handoffFrame: Int {
        let overlapFrames = Int(fadeOutOverlap * sampleRate)
        return max(startFrame, endFrame - overlapFrames)
    }
}
