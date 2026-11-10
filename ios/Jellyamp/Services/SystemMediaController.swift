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
    /// Favorites go through the app's one favorites path (`FavoritesModel`),
    /// handed in as closures so this class stays free of app state: reading
    /// includes changes the server has not echoed back yet, writing updates
    /// every other heart and rolls back on failure.
    private let isFavorite: (Track) -> Bool
    private let setFavorite: (Track, Bool) -> Void

    private var cancellables: Set<AnyCancellable> = []
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    /// The system extrapolates elapsed time from the last value we pushed and
    /// the playback rate. These remember that baseline, so a new value is
    /// pushed only when the real position disagrees (seek, stall, pause).
    private var pushedElapsed: TimeInterval = 0
    private var pushedAt: TimeInterval = 0
    private var pushedRate: Double = 0

    /// Artwork is fetched async per track; remember which track it belongs to.
    private var artworkTrackID: String?
    private let artworkCache = NSCache<NSString, MPMediaItemArtwork>()
    private var wasPlayingBeforeInterruption = false

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "SystemMedia")

    init(
        player: PlayerEngine,
        playerState: PlayerStateModel,
        session: JellyfinSession,
        isFavorite: @escaping (Track) -> Bool,
        setFavorite: @escaping (Track, Bool) -> Void
    ) {
        self.player = player
        self.playerState = playerState
        self.session = session
        self.isFavorite = isFavorite
        self.setFavorite = setFavorite
        artworkCache.countLimit = 24
        configureRemoteCommands()
        observePlayerState()
        observeAudioSession()
    }

    deinit {
        // Remove exactly our handlers: another object (CarPlay scene, a new
        // controller after re-login) may have registered its own.
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands (lock screen, headphone buttons, watch, car)

    private func register(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        commandTargets.append((command, target))
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { [weak self] _ in
            guard let self, self.playerState.currentTrack != nil else { return .noActionableNowPlayingItem }
            self.player.play()
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self, self.playerState.currentTrack != nil else { return .noActionableNowPlayingItem }
            if self.playerState.isPlaying || self.playerState.isLoading {
                self.player.pause()
            } else {
                self.player.play()
            }
            return .success
        }
        register(center.nextTrackCommand) { [weak self] _ in
            self?.player.skipToNext()
            return .success
        }
        register(center.previousTrackCommand) { [weak self] _ in
            self?.player.skipToPrevious()
            return .success
        }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: event.positionTime)
            // Tell the system right away; the engine's clock catches up once
            // the stream has been reopened at the new position.
            self.pushElapsed(event.positionTime)
            return .success
        }
        register(center.changeShuffleModeCommand) { [weak self] event in
            guard let self, let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            self.player.setShuffle(event.shuffleType != .off)
            return .success
        }
        register(center.changeRepeatModeCommand) { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch event.repeatType {
            case .off: self.player.setRepeatMode(.off)
            case .one: self.player.setRepeatMode(.one)
            case .all: self.player.setRepeatMode(.all)
            @unknown default: return .commandFailed
            }
            return .success
        }

        center.likeCommand.localizedTitle = String(localized: "Favorite")
        center.likeCommand.localizedShortTitle = String(localized: "Favorite")
        register(center.likeCommand) { [weak self] _ in
            guard let self, let track = self.playerState.currentTrack else { return .noActionableNowPlayingItem }
            // "Like" is a toggle in every system UI that shows it.
            self.setFavorite(track, !self.isFavorite(track))
            return .success
        }
        center.dislikeCommand.localizedTitle = String(localized: "Remove Favorite")
        center.dislikeCommand.localizedShortTitle = String(localized: "Unfavorite")
        register(center.dislikeCommand) { [weak self] _ in
            guard let self, let track = self.playerState.currentTrack else { return .noActionableNowPlayingItem }
            self.setFavorite(track, false)
            return .success
        }

        // A music player skips tracks; the ±15 s buttons belong to podcasts.
        // Disabled explicitly so the system shows previous/next instead.
        let unused: [MPRemoteCommand] = [
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackRateCommand, center.ratingCommand, center.bookmarkCommand,
        ]
        for command in unused {
            command.isEnabled = false
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

        // The heart can change without the track changing: a favorite
        // change republishes the current track (`PlayerEngine.setFavorite`).
        playerState.$currentTrack
            .sink { [weak self] track in
                var isFavorite = false
                if let track {
                    isFavorite = self?.isFavorite(track) ?? track.isFavorite
                }
                MPRemoteCommandCenter.shared().likeCommand.isActive = isFavorite
            }
            .store(in: &cancellables)

        playerState.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                // `$isPlaying` fires before the property changes, so pass the
                // new value along instead of reading it back.
                self.pushElapsed(self.playerState.currentTime, rate: isPlaying ? 1 : 0)
            }
            .store(in: &cancellables)

        playerState.$currentTime
            .sink { [weak self] time in
                self?.reconcileElapsed(with: time)
            }
            .store(in: &cancellables)

        playerState.$isShuffled
            .removeDuplicates()
            .sink { isShuffled in
                MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
            }
            .store(in: &cancellables)

        playerState.$repeatMode
            .removeDuplicates()
            .sink { mode in
                let type: MPRepeatType
                switch mode {
                case .off: type = .off
                case .one: type = .one
                case .all: type = .all
                }
                MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = type
            }
            .store(in: &cancellables)

        playerState.$upNext
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                // Queue edits change "track 3 of 12" without a track change.
                DispatchQueue.main.async { self?.updateQueuePosition() }
            }
            .store(in: &cancellables)
    }

    private func updateStaticInfo(for track: Track?) {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            artworkTrackID = nil
            return
        }
        let elapsed = playerState.currentTime
        let rate: Double = playerState.isPlaying ? 1 : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // Without this some accessories treat an HTTP-fed player as a
            // radio stream and hide the scrubber.
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playerState.history.count,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playerState.history.count + 1 + playerState.upNext.count,
        ]
        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let number = track.indexNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = number
        }
        if let disc = track.discNumber {
            info[MPMediaItemPropertyDiscNumber] = disc
        }
        // Same album as before: keep the cover instead of flashing a blank.
        if let cached = artworkCache.object(forKey: artworkKey(for: track) as NSString) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        rememberPush(elapsed: elapsed, rate: rate)
        loadArtwork(for: track)
    }

    private func updateQueuePosition() {
        guard playerState.currentTrack != nil, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = playerState.history.count
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playerState.history.count + 1 + playerState.upNext.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Cache key: tracks of one album share a cover.
    private func artworkKey(for track: Track) -> String {
        "\(track.albumID ?? track.id)|\(track.imageTag ?? "")"
    }

    private func loadArtwork(for track: Track) {
        artworkTrackID = track.id
        let key = artworkKey(for: track)
        // The stored cover of a downloaded album first, so the lock screen
        // shows artwork offline too (like `ArtworkView` in the app).
        guard artworkCache.object(forKey: key as NSString) == nil,
              let url = DownloadArtworkStore.localURL(itemID: track.albumID ?? track.id)
                ?? ImageURLBuilder.trackImageURL(track: track, maxWidth: 600, session: session) else { return }
        let trackID = track.id
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await self?.applyArtwork(image, key: key, forTrackID: trackID)
        }
    }

    @MainActor
    private func applyArtwork(_ image: UIImage, key: String, forTrackID trackID: String) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkCache.setObject(artwork, forKey: key as NSString)
        guard artworkTrackID == trackID, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Pushes a new elapsed-time baseline (and optionally a new rate).
    private func pushElapsed(_ time: TimeInterval, rate: Double? = nil) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let newRate = rate ?? pushedRate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        info[MPNowPlayingInfoPropertyPlaybackRate] = newRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        rememberPush(elapsed: time, rate: newRate)
    }

    private func rememberPush(elapsed: TimeInterval, rate: Double) {
        pushedElapsed = elapsed
        pushedRate = rate
        pushedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Called on every engine clock tick. Compares the real position with
    /// what the system is extrapolating and corrects it when they drift apart
    /// — after a seek, while a stream stalls, or when a pause sneaks in.
    private func reconcileElapsed(with time: TimeInterval) {
        guard playerState.currentTrack != nil else { return }
        let expected = pushedElapsed + pushedRate * (ProcessInfo.processInfo.systemUptime - pushedAt)
        if abs(time - expected) > 1.0 {
            pushElapsed(time)
        }
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
            wasPlayingBeforeInterruption = playerState.isPlaying || playerState.isLoading
            player.pause()
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            log.info("interruption ended (shouldResume=\(options.contains(.shouldResume), privacy: .public))")
            if options.contains(.shouldResume), wasPlayingBeforeInterruption {
                player.play()
            }
            wasPlayingBeforeInterruption = false
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
