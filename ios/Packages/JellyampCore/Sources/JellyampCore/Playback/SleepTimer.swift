import Foundation

/// Sleep-timer state machine. Pure value type driven by an injected clock so
/// it is fully testable; the app layer samples it from a timer and applies
/// the returned fade gain to the output mixer.
public struct SleepTimer: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Stop after a fixed interval.
        case duration(endsAt: TimeInterval)
        /// Stop when the current track ends (engine resolves the moment).
        case endOfTrack
    }

    public private(set) var mode: Mode?
    /// Seconds over which playback fades out before stopping.
    public var fadeOutDuration: TimeInterval

    public init(fadeOutDuration: TimeInterval = 10) {
        self.mode = nil
        self.fadeOutDuration = fadeOutDuration
    }

    public var isActive: Bool { mode != nil }

    public mutating func start(duration: TimeInterval, now: TimeInterval) {
        mode = .duration(endsAt: now + duration)
    }

    public mutating func startEndOfTrack() {
        mode = .endOfTrack
    }

    public mutating func extend(by seconds: TimeInterval, now: TimeInterval) {
        switch mode {
        case .duration(let endsAt):
            mode = .duration(endsAt: max(endsAt, now) + seconds)
        case .endOfTrack, nil:
            mode = .duration(endsAt: now + seconds)
        }
    }

    public mutating func cancel() {
        mode = nil
    }

    public func remaining(now: TimeInterval) -> TimeInterval? {
        guard case .duration(let endsAt) = mode else { return nil }
        return max(0, endsAt - now)
    }

    /// Output gain in [0, 1] for the fade-out window; 1 outside it.
    public func fadeGain(now: TimeInterval) -> Double {
        guard let remaining = remaining(now: now), fadeOutDuration > 0 else { return 1 }
        guard remaining < fadeOutDuration else { return 1 }
        return remaining / fadeOutDuration
    }

    public func shouldStop(now: TimeInterval) -> Bool {
        guard case .duration(let endsAt) = mode else { return false }
        return now >= endsAt
    }
}
