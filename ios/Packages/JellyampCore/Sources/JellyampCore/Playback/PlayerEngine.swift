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
}
