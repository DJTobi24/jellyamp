import Foundation
import AVFAudio
import Combine
import MediaPlayer
import OSLog
import UIKit
import JellyampCore
import JellyfinBackend

/// Connects playback to the system: lock-screen / Control Center metadata
/// (`MPNowPlayingInfoCenter`), remote commands (lock screen, headphones,
/// watch, car bluetooth), and audio-session events (calls/Siri interruptions,
/// headphones unplugged).
///
/// Observes the shared `PlayerStateModel` instead of the engine so it stays
/// engine-agnostic; commands go through the `PlayerEngine` protocol.
final class SystemMediaController {
    private let player: PlayerEngine
    private let playerState: PlayerStateModel
    private let session: JellyfinSession

    private var cancellables: Set<AnyCancellable> = []
    /// Last time tick we saw; a jump larger than the tick interval means seek.
    private var lastObservedTime: TimeInterval = 0
    /// Artwork is fetched async per track; remember which track it belongs to.
    private var artworkTrackID: String?
    private var wasPlayingBeforeInterruption = false

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "SystemMedia")

    init(player: PlayerEngine, playerState: PlayerStateModel, session: JellyfinSession) {
        self.player = player
        self.playerState = playerState
        self.session = session
        configureRemoteCommands()
        observePlayerState()
        observeAudioSession()
    }

    deinit {
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
         center.nextTrackCommand, center.previousTrackCommand,
         center.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
    }

    // MARK: - Remote commands (lock screen, headphone buttons, watch, car)

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playerState.isPlaying ? self.player.pause() : self.player.play()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player.skipToNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player.skipToPrevious()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: event.positionTime)
            return .success
        }
    }

    // MARK: - Now-playing info

    private func observePlayerState() {
        playerState.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in
                self?.updateStaticInfo(for: track)
            }
            .store(in: &cancellables)

        playerState.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.updatePlaybackState(isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        // The system extrapolates elapsed time from rate, so we only push a
        // new position when it jumps (seek) — not on every 0.5 s tick.
        playerState.$currentTime
            .sink { [weak self] time in
                guard let self else { return }
                if abs(time - self.lastObservedTime) > 1.5 {
                    self.updateElapsed(time)
                }
                self.lastObservedTime = time
            }
            .store(in: &cancellables)
    }

    private func updateStaticInfo(for track: Track?) {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: playerState.isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: track)
    }

    private func loadArtwork(for track: Track) {
        artworkTrackID = track.id
        guard let url = ImageURLBuilder.trackImageURL(track: track, maxWidth: 600, session: session) else { return }
        let trackID = track.id
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await self?.applyArtwork(image, forTrackID: trackID)
        }
    }

    @MainActor
    private func applyArtwork(_ image: UIImage, forTrackID trackID: String) {
        guard artworkTrackID == trackID else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updatePlaybackState(isPlaying: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playerState.currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateElapsed(_ time: TimeInterval) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Audio-session events

    private func observeAudioSession() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
            }
            .store(in: &cancellables)
    }

    /// Calls, Siri, alarms: pause on begin, resume when the system says so.
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            log.info("interruption began — pausing (wasPlaying=\(self.playerState.isPlaying, privacy: .public))")
            wasPlayingBeforeInterruption = playerState.isPlaying
            player.pause()
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            log.info("interruption ended (shouldResume=\(options.contains(.shouldResume), privacy: .public))")
            if options.contains(.shouldResume), wasPlayingBeforeInterruption {
                player.play()
            }
        @unknown default:
            break
        }
    }

    /// Headphones unplugged / bluetooth device gone: pause, never blast the
    /// speaker (standard iOS behaviour).
    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            log.info("audio route lost (headphones unplugged?) — pausing")
            player.pause()
        }
    }
}
