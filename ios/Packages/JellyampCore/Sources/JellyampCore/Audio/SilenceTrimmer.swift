import Foundation

/// Finds the audible region of decoded PCM so the engine can schedule
/// gapless joins and compress long silences.
public struct SilenceTrimmer: Sendable {
    /// Absolute sample amplitude below which a frame counts as silent.
    public var threshold: Float

    public init(threshold: Float = 0.001) {
        self.threshold = threshold
    }

    public struct Result: Equatable, Sendable {
        /// First audible frame.
        public var startFrame: Int
        /// One past the last audible frame.
        public var endFrame: Int

        public init(startFrame: Int, endFrame: Int) {
            self.startFrame = startFrame
            self.endFrame = endFrame
        }

        public var audibleFrameCount: Int { max(0, endFrame - startFrame) }
    }

    /// Scans mono (or channel-max-reduced) samples. Returns nil when the
    /// buffer is entirely silent.
    public func audibleRange(of samples: [Float]) -> Result? {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }) else { return nil }
        let last = samples.lastIndex(where: { abs($0) >= threshold })!
        return Result(startFrame: first, endFrame: last + 1)
    }

    /// Mid-buffer silent stretches of at least `minimumFrames`, as ranges —
    /// used by the silence-compression feature to skip ahead.
    public func silentStretches(in samples: [Float], minimumFrames: Int) -> [Range<Int>] {
        var stretches: [Range<Int>] = []
        var runStart: Int?
        for (index, sample) in samples.enumerated() {
            if abs(sample) < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= minimumFrames {
                    stretches.append(start..<index)
                }
                runStart = nil
            }
        }
        if let start = runStart, samples.count - start >= minimumFrames {
            stretches.append(start..<samples.count)
        }
        return stretches
    }
}
