import Foundation
import AVFoundation
import Combine
import OSLog
import JellyampCore
import JellyfinBackend

/// Two-`AVPlayer` engine: the active player streams the current track (or plays
/// a local download), while the idle player is used to *preload* and *crossfade*
/// into the next track near the end. `SweetFadePlanner` decides the overlap —
/// consecutive tracks of the same album join gaplessly; otherwise the user's
/// crossfade duration applies. State is driven by `timeControlStatus`.
///
/// A graphic EQ still needs an AVAudioEngine graph (see ADR-0002); until then
/// `apply(eqPreset:)` is a no-op.
final class EnginePlayer: NSObject, PlayerEngine, ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private let playerA = AVPlayer()
    private let playerB = AVPlayer()
    private var activeIsA = true
    private var activePlayer: AVPlayer { activeIsA ? playerA : playerB }
    private var idlePlayer: AVPlayer { activeIsA ? playerB : playerA }

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
    private var timeObserverToken: Any?
    private var timeObserverPlayer: AVPlayer?

    private var masterVolume: Float = 1.0
    /// Per-track loudness multiplier (linear) of the *active* track.
    private var loudnessGain: Float = 1.0
    private var sessionActivated = false
    private var sleepTimer = SleepTimer()
    private var monotonicNow: TimeInterval { Date().timeIntervalSinceReferenceDate }
    private var intendsToPlay = false
    private var loggedFirstTick = false
    private var shuffleEnabled = false
    private var preferredRepeatMode: RepeatMode = .off

    // Crossfade / preload. The crossfade ramp is driven by the *outgoing*
    // (active) player's periodic observer — which ticks reliably — while the
    // incoming player fades up on the idle player. We only switch `active` to
    // the incoming player once the fade completes.
    private var fadePlanner: SweetFadePlanner
    private enum Transition: Equatable { case none, preloaded(Track), crossfading }
    private var transition: Transition = .none
    private var crossfadeStart: TimeInterval = 0
    private var crossfadeOverlap: TimeInterval = 0
    private var incomingTrack: Track?
    private var incomingLoudness: Float = 1.0
    private var outgoingLoudness: Float = 1.0

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Playback")

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.stateModel = stateModel
        self.sleepTimer = SleepTimer(fadeOutDuration: settings.sleepTimerFadeOut)
        self.fadePlanner = SweetFadePlanner(fadeDuration: settings.crossfadeDuration)
        super.init()
        // Default stall-avoidance keeps a clean Content-Length/range stream
        // buffering smoothly (see prior debugging notes).
        playerA.automaticallyWaitsToMinimizeStalling = true
        playerB.automaticallyWaitsToMinimizeStalling = true
        bindActiveObservers()
        log.info("EnginePlayer init: server=\(session.serverURL.absoluteString, privacy: .public) userID=\(session.userID ?? "nil", privacy: .public) hasToken=\(session.accessToken != nil, privacy: .public)")
    }

    deinit {
        if let timeObserverToken { timeObserverPlayer?.removeTimeObserver(timeObserverToken) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        log.info("load(queue): count=\(queue.upNext.count + 1, privacy: .public) current=\(queue.currentTrack?.title ?? "nil", privacy: .public)")
        var queue = queue
        queue.setRepeatMode(preferredRepeatMode)
        if shuffleEnabled { queue.shuffle() }
        self.queue = queue
        guard let track = queue.currentTrack else {
            log.error("load(queue): queue has no current track")
            return
        }
        startPlayback(of: track)
    }

    func play() {
        log.info("play() tapped — state=\(self.describe(self.state), privacy: .public)")
        intendsToPlay = true
        activateSessionIfNeeded()
        activePlayer.play()
    }

    func pause() {
        log.info("pause() tapped — state=\(self.describe(self.state), privacy: .public)")
        intendsToPlay = false
        activePlayer.pause()
        idlePlayer.pause()
    }

    func seek(to time: TimeInterval) {
        log.info("seek(to: \(time, privacy: .public))")
        activePlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        // See note in tick(): writing the @Published time happens off the
        // periodic observer to avoid mutating state during a view update.
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

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let from = source.first else { return }
        let base = (queue.currentIndex ?? -1) + 1
        let absoluteFrom = base + from
        let absoluteTo = base + (destination > from ? destination - 1 : destination)
        queue.move(from: absoluteFrom, to: absoluteTo)
        publishQueue()
    }

    func setShuffle(_ enabled: Bool) {
        shuffleEnabled = enabled
        if enabled { queue.shuffle() } else { queue.unshuffle() }
        log.info("shuffle \(enabled ? "on" : "off", privacy: .public)")
        publishQueue()
        publishShuffleRepeat()
    }

    func cycleRepeatMode() {
        let next: RepeatMode
        switch queue.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        preferredRepeatMode = next
        queue.setRepeatMode(next)
        log.info("repeat → \(String(describing: next), privacy: .public)")
        publishShuffleRepeat()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        var fresh = PlayQueue(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
        fresh.setRepeatMode(preferredRepeatMode)
        fresh.shuffle()
        queue = fresh
        log.info("playShuffled \(tracks.count, privacy: .public) track(s)")
        if let track = queue.currentTrack { startPlayback(of: track) }
        publishShuffleRepeat()
    }

    func apply(eqPreset: EQPreset) {
        // No-op: a graphic EQ needs an AVAudioEngine graph or an
        // MTAudioProcessingTap, neither of which a plain AVPlayer offers.
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        fadePlanner.fadeDuration = newSettings.crossfadeDuration
        log.info("settings updated: crossfade=\(newSettings.crossfadeDuration, privacy: .public)s")
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

    // MARK: - Playback core

    /// Immediate, explicit playback (load / skip / restart) on the active
    /// player. Cancels any preload/crossfade in flight.
    private func startPlayback(of track: Track) {
        cancelTransition()
        intendsToPlay = true
        loggedFirstTick = false
        activateSessionIfNeeded()

        let item = makeItem(for: track)
        loudnessGain = gain(for: track)
        observeActiveItem(item, track: track)
        activePlayer.replaceCurrentItem(with: item)
        applyEffectiveVolume()
        publish(state: .loading(trackID: track.id), track: track)
        publishQueue()
        publishShuffleRepeat()
        activePlayer.play()
        sendStartReports(for: track)
    }

    /// Builds an `AVPlayerItem` for a track — local download if present, else
    /// the streaming URL.
    private func makeItem(for track: Track) -> AVPlayerItem {
        if let local = DownloadStore.localURL(for: track) {
            log.info("startPlayback (offline): \"\(track.title, privacy: .public)\" id=\(track.id, privacy: .public)")
            return AVPlayerItem(url: local)
        }
        let request = settings.playbackProfile.profile.request(for: track, network: .wifi)
        let url = StreamURLBuilder.url(for: track.id, request: request, session: session)
        log.info("""
        startPlayback: "\(track.title, privacy: .public)" id=\(track.id, privacy: .public) \
        codec=\(track.codec ?? "nil", privacy: .public) container=\(track.container ?? "nil", privacy: .public) \
        request=\(self.describe(request), privacy: .public)
        """)
        log.info("stream URL: \(url.absoluteString, privacy: .public)")
        return AVPlayerItem(url: url)
    }

    private func gain(for track: Track) -> Float {
        Float(LoudnessMath.playbackGain(
            normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
            preampDB: settings.loudnessPreampDB
        ))
    }

    /// The active player's volume = master × per-track loudness × sleep fade.
    /// Skipped while crossfading (the ramp drives volumes directly).
    private func applyEffectiveVolume() {
        guard transition != .crossfading else { return }
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        activePlayer.volume = clamp(masterVolume * loudnessGain * fade)
    }

    private func clamp(_ value: Float) -> Float { max(0, min(1, value)) }

    // MARK: - Transitions (preload + crossfade)

    /// Called every tick while not yet transitioning: starts a crossfade or a
    /// gapless preload as the active track nears its end.
    private func maybeBeginTransition(at seconds: TimeInterval) {
        guard intendsToPlay, transition == .none,
              let current = queue.currentTrack,
              let next = queue.nextTrack, next.id != current.id,
              let item = activePlayer.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 1 else { return }
        let remaining = duration - seconds
        let decision = fadePlanner.decision(outgoing: current, incoming: next, trailingSilence: 0, isManualSkip: false)
        if decision.overlap > 0 {
            if remaining <= decision.overlap { beginCrossfade(to: next, overlap: decision.overlap) }
        } else if remaining <= 5 {
            preloadNext(next)
        }
    }

    private func beginCrossfade(to next: Track, overlap: TimeInterval) {
        log.info("crossfade → \"\(next.title, privacy: .public)\" over \(overlap, privacy: .public)s")
        transition = .crossfading
        crossfadeStart = monotonicNow
        crossfadeOverlap = overlap
        outgoingLoudness = loudnessGain
        incomingTrack = next
        incomingLoudness = gain(for: next)

        // Start the incoming track silently on the idle player; the active
        // (outgoing) player stays active and keeps driving the ramp via its
        // periodic observer. We switch over only when the fade completes.
        let incoming = idlePlayer
        incoming.replaceCurrentItem(with: makeItem(for: next))
        incoming.volume = 0
        activateSessionIfNeeded()
        incoming.play()
    }

    private func driveCrossfade() {
        guard transition == .crossfading else { return }
        let progress = crossfadeOverlap > 0 ? (monotonicNow - crossfadeStart) / crossfadeOverlap : 1
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        // active = outgoing (fades out), idle = incoming (fades in).
        activePlayer.volume = clamp(masterVolume * outgoingLoudness * fade * Float(CrossfadeCurve.fadeOutGain(progress: progress)))
        idlePlayer.volume = clamp(masterVolume * incomingLoudness * fade * Float(CrossfadeCurve.fadeInGain(progress: progress)))
        if progress >= 1 { finishCrossfade() }
    }

    private func finishCrossfade() {
        guard transition == .crossfading, let next = incomingTrack else { return }
        let previousActive = activePlayer
        activeIsA.toggle()                       // active is now the incoming player
        loudnessGain = incomingLoudness
        loggedFirstTick = false
        if let item = activePlayer.currentItem { observeActiveItem(item, track: next) }
        bindActiveObservers()
        queue.advance()
        previousActive.pause()
        previousActive.replaceCurrentItem(with: nil)
        transition = .none
        incomingTrack = nil
        applyEffectiveVolume()
        publish(state: .playing(trackID: next.id), track: next)
        publishQueue()
        sendStartReports(for: next)
        log.info("crossfade complete → now playing \"\(next.title, privacy: .public)\"")
    }

    /// Buffers the next track on the idle player so the hand-off at end-of-track
    /// has no gap (used when no crossfade applies).
    private func preloadNext(_ next: Track) {
        log.info("preload next: \"\(next.title, privacy: .public)\"")
        transition = .preloaded(next)
        let item = makeItem(for: next)
        idlePlayer.replaceCurrentItem(with: item)
        idlePlayer.volume = clamp(masterVolume * gain(for: next) * Float(sleepTimer.fadeGain(now: monotonicNow)))
    }

    /// At the real end of the outgoing track, hand off to the preloaded player.
    private func completePreloadHandoff(to next: Track) {
        guard let advanced = queue.advance() else {
            transition = .none
            idlePlayer.replaceCurrentItem(with: nil)
            finishToIdle()
            return
        }
        // Queue changed since preload → don't trust the buffered item.
        guard advanced.id == next.id else {
            transition = .none
            idlePlayer.replaceCurrentItem(with: nil)
            startPlayback(of: advanced)
            return
        }
        let previousActive = activePlayer
        activeIsA.toggle()
        loudnessGain = gain(for: next)
        loggedFirstTick = false
        if let item = activePlayer.currentItem { observeActiveItem(item, track: next) }
        bindActiveObservers()
        applyEffectiveVolume()
        activateSessionIfNeeded()
        activePlayer.play()
        previousActive.pause()
        previousActive.replaceCurrentItem(with: nil)
        transition = .none
        publish(state: .playing(trackID: next.id), track: next)
        publishQueue()
        sendStartReports(for: next)
        log.info("gapless hand-off → \"\(next.title, privacy: .public)\"")
    }

    private func cancelTransition() {
        guard transition != .none else { return }
        // The incoming track is always on the idle player; drop it.
        idlePlayer.pause()
        idlePlayer.replaceCurrentItem(with: nil)
        transition = .none
        incomingTrack = nil
        applyEffectiveVolume()
    }

    // MARK: - Observation

    /// (Re)binds the periodic time + timeControl observers to the active player.
    private func bindActiveObservers() {
        timeControlObserver = activePlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.handleTimeControl(status) }

        if let timeObserverToken { timeObserverPlayer?.removeTimeObserver(timeObserverToken) }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        let target = activePlayer
        timeObserverToken = target.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time: time)
        }
        timeObserverPlayer = target
    }

    private func tick(time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if !loggedFirstTick, seconds > 0 {
            loggedFirstTick = true
            log.info("playback advancing — first tick at \(seconds, privacy: .public)s")
        }
        currentTime = seconds
        stateModel?.currentTime = seconds
        tickSleepTimer()
        if transition == .crossfading {
            driveCrossfade()
        } else {
            maybeBeginTransition(at: seconds)
        }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        // While crossfading the state is already "playing(next)"; ignore the
        // incoming player's transient buffering states.
        guard transition != .crossfading, let track = queue.currentTrack else { return }
        switch status {
        case .playing:
            publish(state: .playing(trackID: track.id), track: track)
        case .waitingToPlayAtSpecifiedRate:
            let reason = activePlayer.reasonForWaitingToPlay?.rawValue ?? "nil"
            log.info("timeControlStatus = waiting (reason=\(reason, privacy: .public))")
            publish(state: .loading(trackID: track.id), track: track)
        case .paused:
            if case .failed = state { return }
            if intendsToPlay {
                publish(state: .loading(trackID: track.id), track: track)
            } else {
                publish(state: .paused(trackID: track.id), track: track)
            }
        @unknown default:
            break
        }
    }

    /// Observes the active item's failure + end-of-track. Replaces any previous.
    private func observeActiveItem(_ item: AVPlayerItem, track: Track) {
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
                    self.publish(state: .failed(trackID: track.id, message: error?.localizedDescription ?? "Playback failed."), track: track)
                case .readyToPlay:
                    self.log.info("item.status = readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
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

    private func trackFinished() {
        log.info("item reached end")
        if case .endOfTrack = sleepTimer.mode {
            log.info("sleep timer: end of track reached — stopping")
            sleepTimer.cancel()
            cancelTransition()
            intendsToPlay = false
            publishSleepTimer()
            finishToIdle()
            return
        }
        if transition == .crossfading {
            // The outgoing track ended before the fade finished — complete now.
            finishCrossfade()
            return
        }
        if case .preloaded(let next) = transition {
            completePreloadHandoff(to: next)
            return
        }
        guard let next = queue.advance() else {
            finishToIdle()
            return
        }
        startPlayback(of: next)
    }

    private func finishToIdle() {
        intendsToPlay = false
        applyEffectiveVolume()
        publish(state: .idle, track: nil)
        stateModel?.upNext = []
    }

    // MARK: - Reports / session / publishing

    private func sendStartReports(for track: Track) {
        Task {
            for report in reporter.trackStarted(id: track.id, at: 0) {
                try? await reporting.send(report, playSessionID: track.id)
            }
        }
    }

    private func tickSleepTimer() {
        guard sleepTimer.isActive else { return }
        if sleepTimer.shouldStop(now: monotonicNow) {
            log.info("sleep timer elapsed — pausing")
            sleepTimer.cancel()
            cancelTransition()
            intendsToPlay = false
            activePlayer.pause()
            idlePlayer.pause()
        }
        if transition != .crossfading { applyEffectiveVolume() }
        publishSleepTimer()
    }

    private func publishSleepTimer() {
        stateModel?.sleepTimerActive = sleepTimer.isActive
        stateModel?.sleepTimerRemaining = sleepTimer.remaining(now: monotonicNow)
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

    private func publishQueue() {
        stateModel?.upNext = queue.upNext
    }

    private func publishShuffleRepeat() {
        if stateModel?.isShuffled != queue.isShuffled { stateModel?.isShuffled = queue.isShuffled }
        if stateModel?.repeatMode != queue.repeatMode { stateModel?.repeatMode = queue.repeatMode }
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
