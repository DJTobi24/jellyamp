import Foundation

/// High-level playback state observed by the UI and reporters.
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading(trackID: String)
    case playing(trackID: String)
    case paused(trackID: String)
    case failed(trackID: String, message: String)
}

/// The seam between platform-independent logic and the AVAudioEngine
/// implementation in the app shell. UI and services depend only on this.
public protocol PlayerEngine: AnyObject {
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }

    func load(queue: PlayQueue)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func skipToNext()
    func skipToPrevious()
    func setVolume(_ volume: Double)
    func apply(eqPreset: EQPreset)

    // Queue editing (Spotify-style). Adding to an empty queue starts playback.
    /// Append tracks to the end of the queue ("Add to Queue").
    func enqueue(_ tracks: [Track])
    /// Insert tracks right after the current one ("Play Next").
    func playNext(_ tracks: [Track])
    /// Jump to an upcoming item (index into the current `upNext`).
    func playUpNext(at upNextIndex: Int)
    /// Remove an upcoming item (index into the current `upNext`).
    func removeUpNext(at upNextIndex: Int)
    /// Reorder upcoming items (SwiftUI `onMove` offsets into `upNext`).
    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int)

    // Sleep timer.
    /// Stop playback after `duration` seconds, or — when nil — at the end of
    /// the current track. Playback fades out over the configured window.
    func startSleepTimer(duration: TimeInterval?)
    func cancelSleepTimer()

    // Shuffle & repeat. Both persist across `load(queue:)` calls.
    /// Shuffle (keeping the current track) or restore the original order.
    func setShuffle(_ enabled: Bool)
    /// Cycle off → all → one → off.
    func cycleRepeatMode()
    /// Shuffle-play a fresh set of tracks, starting from a random one.
    func playShuffled(_ tracks: [Track])
}
