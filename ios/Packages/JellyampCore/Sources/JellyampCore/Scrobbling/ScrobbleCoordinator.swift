import Foundation

/// What the scrobble engine should do in response to playback.
public enum ScrobbleAction: Equatable, Sendable {
    /// Tell the services what is playing right now (not a scrobble).
    case nowPlaying(ScrobbleListen)
    /// This play has earned a scrobble.
    case scrobble(ScrobbleListen)
}

/// Decides *when* a play becomes a scrobble. Pure state machine: the app
/// shell forwards what the player publishes (track, playing flag, position)
/// and gets back the actions to perform.
///
/// Rule (the Last.fm standard, which ListenBrainz shares): the track is
/// longer than 30 s and has been *played* for half its length or 4 minutes,
/// whichever comes first. Played time is accumulated from progress samples —
/// position advancing in step with the wall clock — so seeking forward does
/// not earn a scrobble and seeking back does not lose one. The scrobble is
/// emitted the moment the threshold is crossed rather than at the end of the
/// track, so a play still counts if the app is killed afterwards.
public struct ScrobbleCoordinator: Sendable {
    /// Tracks this short are never scrobbled.
    public static let minimumTrackDuration: TimeInterval = 30
    /// Played time that always suffices, however long the track is.
    public static let maximumRequiredPlayTime: TimeInterval = 240

    /// Played seconds needed before a track of `duration` may be scrobbled;
    /// nil when it never qualifies. A track of unknown length (duration 0,
    /// e.g. a stream still being probed) falls back to the 4-minute rule.
    public static func requiredPlayTime(forDuration duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration > 0 else { return maximumRequiredPlayTime }
        guard duration > minimumTrackDuration else { return nil }
        return min(duration / 2, maximumRequiredPlayTime)
    }

    public static func qualifies(playedSeconds: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let required = requiredPlayTime(forDuration: duration) else { return false }
        return playedSeconds >= required
    }

    /// A position at or below this, reached by jumping backwards, can be the
    /// start of a replay (repeat-one, or the only track of a repeat-all queue).
    public var restartWindow: TimeInterval = 3
    /// How close to the end the position must have been for a jump back to
    /// the start to count as "the track ended and began again".
    public var endWindow: TimeInterval = 15
    /// Position may run this far ahead of the wall clock between two samples
    /// (timer jitter) and still count fully as played time.
    public var jitterTolerance: TimeInterval = 1
    /// Now-playing is re-sent on resume only after this long, so buffering
    /// flaps do not spam the services.
    public var nowPlayingResendInterval: TimeInterval = 30

    private struct Sample: Sendable {
        var position: TimeInterval
        var at: Date
    }

    private struct Play: Sendable {
        var track: Track
        var startedAt: Date?
        var playedSeconds: TimeInterval = 0
        var lastSample: Sample?
        var lastPosition: TimeInterval?
        var hasScrobbled = false
        var nowPlayingSentAt: Date?
    }

    private var play: Play?
    private var isPlaying = false

    public init() {}

    /// Seconds of real listening accumulated for the current play.
    public var playedSeconds: TimeInterval { play?.playedSeconds ?? 0 }
    /// Whether the current play has already produced its scrobble.
    public var hasScrobbledCurrentPlay: Bool { play?.hasScrobbled ?? false }

    /// The player moved to another track (or to none: stopped / queue ended).
    /// Calling it again with the track that is already current starts a new
    /// play of it, so callers that cannot tell should de-duplicate by id and
    /// leave replays to the position-based detection in `progress`.
    public mutating func trackChanged(to track: Track?, at now: Date) -> [ScrobbleAction] {
        guard let track else {
            play = nil
            return []
        }
        return begin(track, at: now)
    }

    /// The player started or stopped producing audio (pause, resume,
    /// buffering).
    public mutating func playbackStateChanged(isPlaying nowPlaying: Bool, at now: Date) -> [ScrobbleAction] {
        isPlaying = nowPlaying
        guard var current = play else { return [] }
        // Time spent paused must not count: the next sample starts a new span.
        current.lastSample = nil
        var actions: [ScrobbleAction] = []
        if nowPlaying {
            let startedAt = current.startedAt ?? now
            current.startedAt = startedAt
            var shouldSend = true
            if let last = current.nowPlayingSentAt, now.timeIntervalSince(last) < nowPlayingResendInterval {
                shouldSend = false
            }
            if shouldSend {
                current.nowPlayingSentAt = now
                actions.append(.nowPlaying(ScrobbleListen(track: current.track, startedAt: startedAt)))
            }
        }
        play = current
        return actions
    }

    /// A position sample from the player (any rate; a few per second is
    /// plenty). Samples that arrive while paused only move the baseline.
    public mutating func progress(position: TimeInterval, at now: Date) -> [ScrobbleAction] {
        guard var current = play else { return [] }
        var actions: [ScrobbleAction] = []

        if isRestart(of: current, position: position) {
            // Same track from the top again (repeat-one): a new play with its
            // own timestamp and its own chance to scrobble.
            actions.append(contentsOf: begin(current.track, at: now))
            guard let restarted = play else { return actions }
            current = restarted
        }

        if isPlaying, let last = current.lastSample {
            let wall = now.timeIntervalSince(last.at)
            let moved = position - last.position
            if wall > 0, moved > 0 {
                // A forward seek moves the position much further than the
                // clock; only the time that actually passed was listened to.
                current.playedSeconds += moved <= wall + jitterTolerance ? moved : wall
            }
        }
        current.lastSample = isPlaying ? Sample(position: position, at: now) : nil
        current.lastPosition = position

        if !current.hasScrobbled,
           let startedAt = current.startedAt,
           Self.qualifies(playedSeconds: current.playedSeconds, duration: current.track.duration) {
            current.hasScrobbled = true
            actions.append(.scrobble(ScrobbleListen(track: current.track, startedAt: startedAt)))
        }
        play = current
        return actions
    }

    private mutating func begin(_ track: Track, at now: Date) -> [ScrobbleAction] {
        var fresh = Play(track: track)
        var actions: [ScrobbleAction] = []
        if isPlaying {
            fresh.startedAt = now
            fresh.nowPlayingSentAt = now
            actions.append(.nowPlaying(ScrobbleListen(track: track, startedAt: now)))
        }
        play = fresh
        return actions
    }

    private func isRestart(of current: Play, position: TimeInterval) -> Bool {
        guard let previous = current.lastPosition,
              position <= restartWindow, previous > restartWindow, position < previous else { return false }
        // Already scrobbled: whatever comes after a jump back to the start
        // is a second listen.
        if current.hasScrobbled { return true }
        // Not scrobbled: only a wrap from the very end is a replay (a seek
        // back to the start mid-track keeps the same play). Requiring some
        // played time ignores the stale position of the previous track that
        // can arrive right after a track change.
        let duration = current.track.duration
        return duration > 0 && previous >= duration - endWindow && current.playedSeconds >= 1
    }
}
