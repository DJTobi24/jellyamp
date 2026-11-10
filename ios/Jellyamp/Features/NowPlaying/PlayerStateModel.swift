import Foundation
import Combine
import JellyampCore

/// Observable bridge between `PlayerEngine` state and SwiftUI. A single
/// instance lives in `DependencyContainer` and is fed by the active engine
/// (`AudioEnginePlayer`, always on the main thread) and injected into the
/// player views.
final class PlayerStateModel: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    /// The current track is being fetched; show a spinner instead of "paused".
    @Published var isLoading = false
    @Published var currentTime: TimeInterval = 0
    /// Upcoming tracks after the current one, for the Up Next / queue view.
    @Published var upNext: [Track] = []
    /// Tracks of this queue that were already played, oldest first.
    @Published var history: [Track] = []
    /// Non-nil when the current track failed to start; surfaced in the UI.
    @Published var errorMessage: String?
    /// Sleep-timer state for the moon button / countdown in the player.
    @Published var sleepTimerActive = false
    @Published var sleepTimerRemaining: TimeInterval?
    /// Shuffle / repeat state for the transport buttons.
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    /// What is actually being streamed for the current track (quality badge).
    @Published var quality: AudioQualityInfo?
}
