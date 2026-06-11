import Foundation
import AVFoundation
import Combine
import JellyampCore
import JellyfinBackend

/// `AVPlayer`-based player: streams directly from `/Audio/{id}/universal`,
/// which lets the server transcode anything the device can't decode (Opus,
/// Ogg, …) and avoids the full-file-download + `AVAudioFile` open that the
/// old `AVAudioEngine` scaffold needed (see ADR-0002).
///
/// Native gapless joins / crossfades and a graphic EQ are not available on a
/// plain `AVPlayer`; those return on an `AVAudioEngine` path in a later phase.
/// Until then `apply(eqPreset:)` is a no-op.
final class EnginePlayer: NSObject, PlayerEngine, ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private let player = AVPlayer()
    private let session: JellyfinSession
    private var settings: AppSettings
    private var queue = PlayQueue()
    private var reporter = PlaybackReporter()
    private let reporting: PlaybackReportingAPI

    /// Shared bridge that drives the SwiftUI player views. Updated only on the
    /// main thread (every callback below is delivered on `.main`).
    private weak var stateModel: PlayerStateModel?

    private var statusObserver: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var masterVolume: Float = 1.0
    /// Per-track loudness multiplier (linear); combined with `masterVolume`.
    private var loudnessGain: Float = 1.0
    private var sessionActivated = false

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.stateModel = stateModel
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        addPeriodicTimeObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        self.queue = queue
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func play() {
        guard case .paused(let trackID) = state else { return }
        activateSessionIfNeeded()
        player.play()
        publish(state: .playing(trackID: trackID), track: queue.currentTrack)
    }

    func pause() {
        guard case .playing(let trackID) = state else { return }
        player.pause()
        publish(state: .paused(trackID: trackID), track: queue.currentTrack)
    }

    func seek(to time: TimeInterval) {
        // Direct-play (`static=true`) streams are byte-seekable, so AVPlayer
        // can seek in place. Seeking a live transcode (re-request with
        // `startTimeTicks`) is a follow-up.
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        stateModel?.currentTime = time
    }

    func skipToNext() {
        guard let next = queue.skipToNext() else { return }
        startPlayback(of: next)
    }

    func skipToPrevious() {
        guard let previous = queue.skipToPrevious() else { return }
        startPlayback(of: previous)
    }

    func setVolume(_ volume: Double) {
        masterVolume = Float(volume)
        applyEffectiveVolume()
    }

    func apply(eqPreset: EQPreset) {
        // No-op: a graphic EQ needs an AVAudioEngine graph or an
        // MTAudioProcessingTap, neither of which a plain AVPlayer offers.
    }

    // MARK: - Internals

    /// Builds the stream URL, swaps in a fresh item, and starts playback.
    /// Always called on the main thread (load / skip / track-finished).
    private func startPlayback(of track: Track) {
        activateSessionIfNeeded()

        let profile = settings.playbackProfile.profile
        let request = profile.request(for: track, network: .wifi)
        let url = StreamURLBuilder.url(for: track.id, request: request, session: session)

        let item = AVPlayerItem(url: url)
        observe(item: item, track: track)

        loudnessGain = Float(LoudnessMath.playbackGain(
            normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
            preampDB: settings.loudnessPreampDB
        ))
        player.replaceCurrentItem(with: item)
        applyEffectiveVolume()
        publish(state: .loading(trackID: track.id), track: track)
        player.play()

        sendStartReports(for: track)
    }

    /// `player.volume` carries master × per-track loudness. AVPlayer clamps to
    /// [0, 1], so loudness *boost* (gain > unity, e.g. quiet tracks) is capped
    /// at unity for now; full boost returns with the AVAudioEngine path.
    private func applyEffectiveVolume() {
        player.volume = max(0, min(1, masterVolume * loudnessGain))
    }

    /// KVO on item status (ready → playing, error → failed) plus end-of-item.
    private func observe(item: AVPlayerItem, track: Track) {
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if case .loading = self.state {
                        self.publish(state: .playing(trackID: track.id), track: track)
                    }
                case .failed:
                    let message = item.error?.localizedDescription ?? "Playback failed."
                    self.publish(state: .failed(trackID: track.id, message: message), track: track)
                default:
                    break
                }
            }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.trackFinished()
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.currentTime = seconds
            self.stateModel?.currentTime = seconds
        }
    }

    private func trackFinished() {
        guard let next = queue.advance() else {
            publish(state: .idle, track: nil)
            return
        }
        startPlayback(of: next)
    }

    private func sendStartReports(for track: Track) {
        Task {
            for report in reporter.trackStarted(id: track.id, at: 0) {
                try? await reporting.send(report, playSessionID: track.id)
            }
        }
    }

    private func activateSessionIfNeeded() {
        guard !sessionActivated else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionActivated = true
    }

    /// Single point that mutates published state — must run on the main thread.
    private func publish(state newState: PlaybackState, track: Track?) {
        state = newState
        stateModel?.currentTrack = track
        if case .playing = newState {
            stateModel?.isPlaying = true
        } else {
            stateModel?.isPlaying = false
        }
        if case .failed(_, let message) = newState {
            stateModel?.errorMessage = message
        } else {
            stateModel?.errorMessage = nil
        }
    }
}
