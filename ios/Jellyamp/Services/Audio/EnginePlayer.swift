import Foundation
import AVFoundation
import Combine
import OSLog
import JellyampCore
import JellyfinBackend

/// `AVPlayer`-based player: streams directly from `/Audio/{id}/universal`,
/// which lets the server transcode anything the device can't decode (Opus,
/// Ogg, …) and avoids the full-file-download + `AVAudioFile` open that the
/// old `AVAudioEngine` scaffold needed (see ADR-0002).
///
/// Playback state is driven by `AVPlayer.timeControlStatus` (the source of
/// truth for "is sound actually coming out"), not by the brittle item-status
/// dance; `currentItem.status == .failed` is used only to surface errors.
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

    private var itemStatusObserver: AnyCancellable?
    private var timeControlObserver: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    private var masterVolume: Float = 1.0
    /// Per-track loudness multiplier (linear); combined with `masterVolume`.
    private var loudnessGain: Float = 1.0
    private var sessionActivated = false
    /// Core state machine; ticked by the periodic time observer. Drives the
    /// pre-stop fade and the actual stop.
    private var sleepTimer = SleepTimer()
    private var monotonicNow: TimeInterval { Date().timeIntervalSinceReferenceDate }
    /// True while the user/queue wants audio: lets us tell a transient
    /// buffering `.paused` apart from a deliberate pause.
    private var intendsToPlay = false
    /// One-shot guard so we log the first real time advance only once.
    private var loggedFirstTick = false

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Playback")

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.stateModel = stateModel
        self.sleepTimer = SleepTimer(fadeOutDuration: settings.sleepTimerFadeOut)
        super.init()
        // Keep the default stall-avoidance on: the `/Items/{id}/File` endpoint
        // serves a proper Content-Length + byte ranges, so AVPlayer can buffer
        // ahead and play smoothly with an advancing clock. (Disabling it makes
        // the player report `.playing` while still starved, so time appears
        // stuck — which is exactly the bad behaviour we saw.)
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
        addPeriodicTimeObserver()
        log.info("EnginePlayer init: server=\(session.serverURL.absoluteString, privacy: .public) userID=\(session.userID ?? "nil", privacy: .public) hasToken=\(session.accessToken != nil, privacy: .public)")
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        log.info("load(queue): count=\(queue.upNext.count + 1, privacy: .public) current=\(queue.currentTrack?.title ?? "nil", privacy: .public)")
        self.queue = queue
        guard let track = queue.currentTrack else {
            log.error("load(queue): queue has no current track")
            return
        }
        startPlayback(of: track)
    }

    func play() {
        log.info("play() tapped — state=\(self.describe(self.state), privacy: .public) rate=\(self.player.rate, privacy: .public)")
        intendsToPlay = true
        activateSessionIfNeeded()
        player.play()
    }

    func pause() {
        log.info("pause() tapped — state=\(self.describe(self.state), privacy: .public)")
        intendsToPlay = false
        player.pause()
    }

    func seek(to time: TimeInterval) {
        log.info("seek(to: \(time, privacy: .public))")
        // Direct-play (`static=true`) streams are byte-seekable, so AVPlayer
        // can seek in place. Seeking a live transcode (re-request with
        // `startTimeTicks`) is a follow-up.
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        // Don't write the @Published time here: this runs inside the slider's
        // edit-changed callback, and mutating shared state mid-update trips
        // SwiftUI's "modifying state during view update" warning. The periodic
        // time observer fires on the seek's time-jump and syncs it safely.
        currentTime = time
    }

    func skipToNext() {
        guard let next = queue.skipToNext() else { return }
        log.info("skipToNext → \(next.title, privacy: .public)")
        startPlayback(of: next)
    }

    func skipToPrevious() {
        guard let previous = queue.skipToPrevious() else { return }
        log.info("skipToPrevious → \(previous.title, privacy: .public)")
        startPlayback(of: previous)
    }

    func setVolume(_ volume: Double) {
        masterVolume = Float(volume)
        applyEffectiveVolume()
    }

    func enqueue(_ tracks: [Track]) {
        log.info("enqueue \(tracks.count, privacy: .public) track(s)")
        let wasIdle = queue.currentTrack == nil
        queue.append(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playNext(_ tracks: [Track]) {
        log.info("playNext \(tracks.count, privacy: .public) track(s)")
        let wasIdle = queue.currentTrack == nil
        queue.insertNext(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playUpNext(at upNextIndex: Int) {
        let absolute = (queue.currentIndex ?? -1) + 1 + upNextIndex
        queue.jump(to: absolute)
        guard let track = queue.currentTrack else { return }
        log.info("playUpNext[\(upNextIndex, privacy: .public)] → \(track.title, privacy: .public)")
        startPlayback(of: track)
    }

    func removeUpNext(at upNextIndex: Int) {
        let absolute = (queue.currentIndex ?? -1) + 1 + upNextIndex
        queue.remove(at: absolute)
        publishQueue()
    }

    func apply(eqPreset: EQPreset) {
        // No-op: a graphic EQ needs an AVAudioEngine graph or an
        // MTAudioProcessingTap, neither of which a plain AVPlayer offers.
    }

    func startSleepTimer(duration: TimeInterval?) {
        if let duration {
            sleepTimer.start(duration: duration, now: monotonicNow)
            log.info("sleep timer: \(Int(duration), privacy: .public)s")
        } else {
            sleepTimer.startEndOfTrack()
            log.info("sleep timer: end of track")
        }
        publishSleepTimer()
    }

    func cancelSleepTimer() {
        log.info("sleep timer cancelled")
        sleepTimer.cancel()
        applyEffectiveVolume()
        publishSleepTimer()
    }

    // MARK: - Internals

    /// Builds the stream URL, swaps in a fresh item, and starts playback.
    /// Always called on the main thread (load / skip / track-finished).
    private func startPlayback(of track: Track) {
        intendsToPlay = true
        loggedFirstTick = false
        activateSessionIfNeeded()

        let profile = settings.playbackProfile.profile
        let request = profile.request(for: track, network: .wifi)
        let url = StreamURLBuilder.url(for: track.id, request: request, session: session)

        log.info("""
        startPlayback: "\(track.title, privacy: .public)" id=\(track.id, privacy: .public) \
        codec=\(track.codec ?? "nil", privacy: .public) container=\(track.container ?? "nil", privacy: .public) \
        bitrate=\(track.bitrate ?? -1, privacy: .public) request=\(self.describe(request), privacy: .public)
        """)
        log.info("stream URL: \(url.absoluteString, privacy: .public)")

        let item = AVPlayerItem(url: url)
        observe(item: item, track: track)

        loudnessGain = Float(LoudnessMath.playbackGain(
            normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
            preampDB: settings.loudnessPreampDB
        ))
        player.replaceCurrentItem(with: item)
        applyEffectiveVolume()
        publish(state: .loading(trackID: track.id), track: track)
        publishQueue()
        player.play()

        sendStartReports(for: track)
    }

    /// `player.volume` carries master × per-track loudness × sleep fade.
    /// AVPlayer clamps to [0, 1], so loudness *boost* (gain > unity, e.g.
    /// quiet tracks) is capped at unity for now; full boost returns with the
    /// AVAudioEngine path.
    private func applyEffectiveVolume() {
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        player.volume = max(0, min(1, masterVolume * loudnessGain * fade))
    }

    /// Called from the periodic time observer (every 0.5 s on main).
    private func tickSleepTimer() {
        guard sleepTimer.isActive else { return }
        if sleepTimer.shouldStop(now: monotonicNow) {
            log.info("sleep timer elapsed — pausing")
            sleepTimer.cancel()
            intendsToPlay = false
            player.pause()
        }
        applyEffectiveVolume()
        publishSleepTimer()
    }

    private func publishSleepTimer() {
        stateModel?.sleepTimerActive = sleepTimer.isActive
        stateModel?.sleepTimerRemaining = sleepTimer.remaining(now: monotonicNow)
    }

    /// Drives state from whether audio is actually playing. This is the
    /// reliable signal — item.status alone leaves the player stuck "loading".
    private func observePlayer() {
        timeControlObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleTimeControl(status)
            }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        guard let track = queue.currentTrack else { return }
        switch status {
        case .playing:
            log.info("timeControlStatus = playing")
            publish(state: .playing(trackID: track.id), track: track)
        case .waitingToPlayAtSpecifiedRate:
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "nil"
            log.info("timeControlStatus = waiting (reason=\(reason, privacy: .public))")
            publish(state: .loading(trackID: track.id), track: track)
        case .paused:
            if case .failed = state { return }
            if intendsToPlay {
                log.info("timeControlStatus = paused but intendsToPlay → loading")
                publish(state: .loading(trackID: track.id), track: track)
            } else {
                log.info("timeControlStatus = paused (user)")
                publish(state: .paused(trackID: track.id), track: track)
            }
        @unknown default:
            break
        }
    }

    /// Surfaces a failed item and handles end-of-track.
    private func observe(item: AVPlayerItem, track: Track) {
        itemStatusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .failed:
                    let error = item.error
                    let comment = item.errorLog()?.events.last?.errorComment
                    self.log.error("""
                    item.status = FAILED — \(error?.localizedDescription ?? "unknown", privacy: .public) \
                    (\((error as NSError?)?.domain ?? "?", privacy: .public) \
                    code=\((error as NSError?)?.code ?? 0, privacy: .public)) \
                    errorLog=\(comment ?? "nil", privacy: .public)
                    """)
                    self.intendsToPlay = false
                    self.publish(
                        state: .failed(trackID: track.id, message: error?.localizedDescription ?? "Playback failed."),
                        track: track
                    )
                case .readyToPlay:
                    self.log.info("item.status = readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                case .unknown:
                    self.log.debug("item.status = unknown")
                @unknown default:
                    break
                }
            }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.log.info("item reached end")
            self?.trackFinished()
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            if !self.loggedFirstTick, seconds > 0 {
                self.loggedFirstTick = true
                self.log.info("playback advancing — first tick at \(seconds, privacy: .public)s")
            }
            self.currentTime = seconds
            self.stateModel?.currentTime = seconds
            self.tickSleepTimer()
        }
    }

    private func trackFinished() {
        if case .endOfTrack = sleepTimer.mode {
            log.info("sleep timer: end of track reached — stopping")
            sleepTimer.cancel()
            intendsToPlay = false
            publishSleepTimer()
            applyEffectiveVolume()
            publish(state: .idle, track: nil)
            stateModel?.upNext = []
            return
        }
        guard let next = queue.advance() else {
            intendsToPlay = false
            publish(state: .idle, track: nil)
            stateModel?.upNext = []
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
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActivated = true
            log.info("AVAudioSession activated (category=\(AVAudioSession.sharedInstance().category.rawValue, privacy: .public))")
        } catch {
            log.error("AVAudioSession.setActive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mirrors the upcoming queue into the view model for the Up Next list.
    private func publishQueue() {
        stateModel?.upNext = queue.upNext
    }

    /// Single point that mutates published state — must run on the main thread.
    private func publish(state newState: PlaybackState, track: Track?) {
        if newState != state {
            log.debug("state: \(self.describe(self.state), privacy: .public) → \(self.describe(newState), privacy: .public)")
        }
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

    // MARK: - Logging helpers

    private func describe(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading(let id): return "loading(\(id))"
        case .playing(let id): return "playing(\(id))"
        case .paused(let id): return "paused(\(id))"
        case .failed(_, let message): return "failed(\(message))"
        }
    }

    private func describe(_ request: StreamRequest) -> String {
        switch request {
        case .directPlay: return "directPlay"
        case .transcode(let codec, let container, let bitrate): return "transcode(\(codec)/\(container)@\(bitrate))"
        }
    }
}
