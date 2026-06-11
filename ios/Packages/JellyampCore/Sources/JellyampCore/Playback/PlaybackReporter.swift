import Foundation

/// Report events the Jellyfin session API expects
/// (`/Sessions/Playing`, `/Progress`, `/Stopped`).
public enum PlaybackReport: Equatable, Sendable {
    case started(trackID: String, positionTicks: Int64)
    case progress(trackID: String, positionTicks: Int64, isPaused: Bool)
    case stopped(trackID: String, positionTicks: Int64)
}

/// State machine that turns engine state changes and timer ticks into the
/// minimal correct sequence of Jellyfin playback reports. Pure logic: the
/// caller delivers events, this returns reports to send.
public struct PlaybackReporter: Sendable {
    /// 1 tick = 100 ns, Jellyfin's position unit.
    public static func ticks(from seconds: TimeInterval) -> Int64 {
        Int64(seconds * 10_000_000)
    }

    /// Progress reports are emitted at most this often (seconds).
    public var progressInterval: TimeInterval

    private var activeTrackID: String?
    private var lastProgressAt: TimeInterval?

    public init(progressInterval: TimeInterval = 10) {
        self.progressInterval = progressInterval
    }

    /// A new track started playing. Emits a stop for the previous track first.
    public mutating func trackStarted(id: String, at position: TimeInterval, previousPosition: TimeInterval = 0) -> [PlaybackReport] {
        var reports: [PlaybackReport] = []
        if let previous = activeTrackID {
            reports.append(.stopped(trackID: previous, positionTicks: Self.ticks(from: previousPosition)))
        }
        activeTrackID = id
        lastProgressAt = nil
        reports.append(.started(trackID: id, positionTicks: Self.ticks(from: position)))
        return reports
    }

    /// Periodic tick from the engine. `now` is a monotonic seconds clock.
    public mutating func playbackTick(position: TimeInterval, isPaused: Bool, now: TimeInterval) -> [PlaybackReport] {
        guard let id = activeTrackID else { return [] }
        if let last = lastProgressAt, now - last < progressInterval {
            return []
        }
        lastProgressAt = now
        return [.progress(trackID: id, positionTicks: Self.ticks(from: position), isPaused: isPaused)]
    }

    /// Pause/resume/seek must report immediately, ignoring the throttle.
    public mutating func stateChanged(position: TimeInterval, isPaused: Bool, now: TimeInterval) -> [PlaybackReport] {
        guard let id = activeTrackID else { return [] }
        lastProgressAt = now
        return [.progress(trackID: id, positionTicks: Self.ticks(from: position), isPaused: isPaused)]
    }

    /// Playback ended (stop, queue exhausted, app teardown).
    public mutating func stopped(at position: TimeInterval) -> [PlaybackReport] {
        guard let id = activeTrackID else { return [] }
        activeTrackID = nil
        lastProgressAt = nil
        return [.stopped(trackID: id, positionTicks: Self.ticks(from: position))]
    }
}
