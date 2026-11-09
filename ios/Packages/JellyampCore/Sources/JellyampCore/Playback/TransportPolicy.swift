import Foundation

/// Small transport decisions the engine would otherwise hard-code, kept here
/// so they are unit-tested.
public struct TransportPolicy: Sendable {
    public enum PreviousAction: Equatable, Sendable {
        /// Jump back to the start of the current track.
        case restartCurrent
        /// Go to the previous queue item.
        case previousTrack
    }

    /// "Previous" restarts the current track once it has played this long
    /// (the convention every music player follows).
    public var restartThreshold: TimeInterval

    public init(restartThreshold: TimeInterval = 3) {
        self.restartThreshold = restartThreshold
    }

    public func previousAction(position: TimeInterval, hasPrevious: Bool) -> PreviousAction {
        if position > restartThreshold || !hasPrevious {
            return .restartCurrent
        }
        return .previousTrack
    }

    /// Keeps a seek target inside the track, leaving a little room before the
    /// end so the decoder still has something to play.
    public func clampedSeekTarget(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        guard duration > 1 else { return max(0, time) }
        return min(max(0, time), duration - 0.5)
    }
}

/// What to do when a track cannot be loaded: skip ahead a few times (one bad
/// file must not stall the queue), but give up when everything fails (server
/// unreachable) instead of racing through the whole queue.
public struct TrackFailurePolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case skipToNext
        case giveUp
    }

    public var maxConsecutiveFailures: Int
    public private(set) var consecutiveFailures = 0

    public init(maxConsecutiveFailures: Int = 3) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    public mutating func recordFailure() -> Action {
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            consecutiveFailures = 0
            return .giveUp
        }
        return .skipToNext
    }
}

public extension NetworkType {
    /// Maps what `NWPath` reports to the class the playback profile cares
    /// about. Expensive non-cellular paths (personal hotspot) count as
    /// cellular: the user is paying for that data too.
    static func classify(isSatisfied: Bool, usesCellular: Bool, isExpensive: Bool) -> NetworkType {
        guard isSatisfied else { return .offline }
        return (usesCellular || isExpensive) ? .cellular : .wifi
    }
}

/// Hands out the `PlaySessionId` Jellyfin expects on every report of one
/// play-through: a fresh one per `started`, reused for that track's progress
/// and stop reports.
public struct PlaySessionLedger: Sendable {
    private var sessions: [String: String] = [:]

    public init() {}

    public mutating func sessionID(for report: PlaybackReport, makeID: () -> String = { UUID().uuidString }) -> String {
        switch report {
        case .started(let trackID, _):
            let id = makeID()
            sessions[trackID] = id
            return id
        case .progress(let trackID, _, _):
            if let id = sessions[trackID] { return id }
            let id = makeID()
            sessions[trackID] = id
            return id
        case .stopped(let trackID, _):
            return sessions.removeValue(forKey: trackID) ?? makeID()
        }
    }
}
