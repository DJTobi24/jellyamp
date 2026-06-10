import Foundation

/// Equal-power crossfade math and the "sweet fades" profile.
///
/// All functions are pure; the audio engine samples them per render quantum
/// to drive `playerNode.volume` ramps.
public enum CrossfadeCurve {
    /// Equal-power fade-out gain at `progress` ∈ [0, 1].
    public static func fadeOutGain(progress: Double) -> Double {
        let p = progress.clamped(to: 0...1)
        return cos(p * .pi / 2)
    }

    /// Equal-power fade-in gain at `progress` ∈ [0, 1].
    public static func fadeInGain(progress: Double) -> Double {
        let p = progress.clamped(to: 0...1)
        return sin(p * .pi / 2)
    }
}

/// Decides how (and whether) to fade between two specific tracks.
public struct SweetFadePlanner: Sendable {
    /// User-configured crossfade duration in seconds (0 disables fading).
    public var fadeDuration: TimeInterval
    /// A trailing silence shorter than this means the track "ends hot"
    /// (runs straight into the next one) — typical of gapless albums.
    public var gaplessSilenceThreshold: TimeInterval

    public init(fadeDuration: TimeInterval = 4, gaplessSilenceThreshold: TimeInterval = 0.3) {
        self.fadeDuration = fadeDuration
        self.gaplessSilenceThreshold = gaplessSilenceThreshold
    }

    public struct Decision: Equatable, Sendable {
        /// Seconds of overlap between outgoing and incoming track. 0 = butt join.
        public var overlap: TimeInterval
        public var isGaplessJoin: Bool

        public init(overlap: TimeInterval, isGaplessJoin: Bool) {
            self.overlap = overlap
            self.isGaplessJoin = isGaplessJoin
        }
    }

    /// - Parameters:
    ///   - outgoing: track that is ending
    ///   - incoming: track that will play next
    ///   - trailingSilence: detected silence at the end of `outgoing` (after trimming)
    ///   - isManualSkip: user pressed next (always fade, feels responsive)
    public func decision(outgoing: Track, incoming: Track, trailingSilence: TimeInterval, isManualSkip: Bool) -> Decision {
        // Consecutive tracks of the same album that run into each other must
        // join sample-accurately — fading would destroy live albums and DJ mixes.
        let sameAlbum = outgoing.albumID != nil && outgoing.albumID == incoming.albumID
        let consecutive = sameAlbum
            && outgoing.discNumber == incoming.discNumber
            && (outgoing.indexNumber.map { $0 + 1 } == incoming.indexNumber)
        let endsHot = trailingSilence < gaplessSilenceThreshold
        if consecutive && endsHot && !isManualSkip {
            return Decision(overlap: 0, isGaplessJoin: true)
        }
        guard fadeDuration > 0 else {
            return Decision(overlap: 0, isGaplessJoin: false)
        }
        // "Sweet": tracks that end cold (long natural fade-out into silence)
        // get a shorter overlap so we don't double-fade.
        let sweetened = trailingSilence > 2 ? fadeDuration / 2 : fadeDuration
        // Never overlap more than half of either track.
        let maxOverlap = min(outgoing.duration, incoming.duration) / 2
        return Decision(overlap: min(sweetened, maxOverlap), isGaplessJoin: false)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
