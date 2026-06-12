import Foundation
import AVFoundation
import OSLog
import JellyampCore
import JellyfinBackend

/// `AVAudioEngine`-based player: two `AVAudioPlayerNode` chains feed one mixer,
/// so they **mix** — enabling a real, audible crossfade (unlike two separate
/// `AVPlayer`s, which iOS won't sum). Tracks play from a local file (offline
/// download or the streaming cache), since the engine can't stream like
/// `AVPlayer`; the next track is preloaded so transitions stay seamless.
///
/// This is the ADR-0002 path. The simpler `EnginePlayer` (AVPlayer) remains in
/// the codebase as a one-line fallback in `DependencyContainer`.
final class AudioEnginePlayer: NSObject, PlayerEngine, ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private final class Chain {
        let scheduler: TrackSchedulerNode
        var file: AVAudioFile?
        var startOffset: TimeInterval = 0      // seconds the scheduled segment starts at
        var generation = 0                     // ignore completions from replaced schedules
        var player: AVAudioPlayerNode { scheduler.player }
        init(engine: AVAudioEngine) {
            scheduler = TrackSchedulerNode(engine: engine)
            scheduler.attach(to: engine)
        }
    }

    private let engine = AVAudioEngine()
    private let chainA: Chain
    private let chainB: Chain
    private var activeIsA = true
    private var active: Chain { activeIsA ? chainA : chainB }
    private var idle: Chain { activeIsA ? chainB : chainA }

    private let session: JellyfinSession
    private var settings: AppSettings
    private var queue = PlayQueue()
    private var reporter = PlaybackReporter()
    private let reporting: PlaybackReportingAPI
    private let cache: StreamingAssetCache
    private weak var stateModel: PlayerStateModel?

    private var masterVolume: Float = 1.0
    private var loudnessGain: Float = 1.0
    private var sessionActivated = false
    private var intendsToPlay = false
    private var shuffleEnabled = false
    private var preferredRepeatMode: RepeatMode = .off
    private var eqPreset: EQPreset?

    private var sleepTimer = SleepTimer()
    private var monotonicNow: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private var fadePlanner: SweetFadePlanner
    private enum Transition: Equatable { case none, preloading(String), crossfading }
    private var transition: Transition = .none
    private var crossfadeStart: TimeInterval = 0
    private var crossfadeOverlap: TimeInterval = 0
    private var incomingTrack: Track?
    private var incomingLoudness: Float = 1.0
    private var preloadedID: String?

    private var ticker: Timer?
    private var startGeneration = 0   // bumped on every explicit (re)start

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Playback")

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.cache = StreamingAssetCache(session: session)
        self.stateModel = stateModel
        self.sleepTimer = SleepTimer(fadeOutDuration: settings.sleepTimerFadeOut)
        self.fadePlanner = SweetFadePlanner(fadeDuration: settings.crossfadeDuration)
        self.chainA = Chain(engine: engine)
        self.chainB = Chain(engine: engine)
        super.init()
        engine.prepare()
        log.info("AudioEnginePlayer init: server=\(session.serverURL.absoluteString, privacy: .public)")
    }

    deinit { ticker?.invalidate() }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        var queue = queue
        queue.setRepeatMode(preferredRepeatMode)
        if shuffleEnabled { queue.shuffle() }
        self.queue = queue
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func play() {
        intendsToPlay = true
        activateSession()
        startEngineIfNeeded()
        active.player.play()
        if transition == .crossfading { idle.player.play() }
        publish(state: .playing(trackID: queue.currentTrack?.id ?? ""), track: queue.currentTrack)
        startTicker()
    }

    func pause() {
        intendsToPlay = false
        active.player.pause()
        idle.player.pause()
        publish(state: .paused(trackID: queue.currentTrack?.id ?? ""), track: queue.currentTrack)
    }

    func seek(to time: TimeInterval) {
        guard let file = active.file else { return }
        cancelTransition()
        scheduleAndPlay(active, file: file, fromSeconds: time)
        currentTime = time
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

    func enqueue(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.append(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playNext(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.insertNext(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playUpNext(at upNextIndex: Int) {
        let absolute = (queue.currentIndex ?? -1) + 1 + upNextIndex
        queue.jump(to: absolute)
        guard let track = queue.currentTrack else { return }
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
        queue.move(from: base + from, to: base + (destination > from ? destination - 1 : destination))
        publishQueue()
    }

    func setShuffle(_ enabled: Bool) {
        shuffleEnabled = enabled
        if enabled { queue.shuffle() } else { queue.unshuffle() }
        publishQueue()
        publishShuffleRepeat()
    }

    func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: preferredRepeatMode = .all
        case .all: preferredRepeatMode = .one
        case .one: preferredRepeatMode = .off
        }
        queue.setRepeatMode(preferredRepeatMode)
        publishShuffleRepeat()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        var fresh = PlayQueue(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
        fresh.setRepeatMode(preferredRepeatMode)
        fresh.shuffle()
        queue = fresh
        if let track = queue.currentTrack { startPlayback(of: track) }
        publishShuffleRepeat()
    }

    func apply(eqPreset: EQPreset) {
        self.eqPreset = eqPreset
        chainA.scheduler.apply(preset: eqPreset)
        chainB.scheduler.apply(preset: eqPreset)
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        fadePlanner.fadeDuration = newSettings.crossfadeDuration
    }

    func startSleepTimer(duration: TimeInterval?) {
        if let duration { sleepTimer.start(duration: duration, now: monotonicNow) }
        else { sleepTimer.startEndOfTrack() }
        publishSleepTimer()
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
        applyEffectiveVolume()
        publishSleepTimer()
    }

    // MARK: - Playback

    private func startPlayback(of track: Track) {
        cancelTransition()
        intendsToPlay = true
        loudnessGain = gain(for: track)
        publish(state: .loading(trackID: track.id), track: track)
        publishQueue()
        publishShuffleRepeat()
        let generation = bumpStartGeneration()
        Task { [weak self] in
            guard let self else { return }
            let url = await self.resolveLocalURL(for: track)
            await self.finishStart(generation: generation, track: track, url: url)
        }
    }

    @MainActor
    private func finishStart(generation: Int, track: Track, url: URL?) {
        guard startGeneration == generation else { return }
        guard let url else {
            publish(state: .failed(trackID: track.id, message: "Couldn't load track."), track: track)
            return
        }
        beginPlay(track, url: url, on: active)
    }

    private func beginPlay(_ track: Track, url: URL, on chain: Chain) {
        activateSession()
        guard let file = openFile(url) else {
            publish(state: .failed(trackID: track.id, message: "Couldn't open audio (unsupported format?)."), track: track)
            return
        }
        chain.file = file
        startEngineIfNeeded()
        scheduleAndPlay(chain, file: file, fromSeconds: 0)
        applyEffectiveVolume()
        publish(state: .playing(trackID: track.id), track: track)
        startTicker()
        sendStartReports(for: track)
        preloadedID = nil
    }

    /// Schedules `file` from `fromSeconds` on a chain and starts the node.
    private func scheduleAndPlay(_ chain: Chain, file: AVAudioFile, fromSeconds: TimeInterval) {
        let generation = chain.generation + 1
        chain.generation = generation
        chain.startOffset = fromSeconds
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, fromSeconds) * sampleRate)
        let frames = AVAudioFrameCount(max(0, file.length - startFrame))
        // Match the chain's input format to the file so varying sample rates
        // play correctly. Safe: the chain isn't producing output mid-reconnect.
        engine.connect(chain.player, to: chain.scheduler.eq, format: file.processingFormat)
        chain.player.stop()
        guard frames > 0 else { return }
        chain.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                                     completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.chainFinished(chain, generation: generation) }
        }
        startEngineIfNeeded()
        chain.player.play()
    }

    private func chainFinished(_ chain: Chain, generation: Int) {
        guard chain.generation == generation else { return }   // stale (replaced/seeked)
        guard chain === active, transition == .none else { return }
        trackFinished()
    }

    private func trackFinished() {
        if case .endOfTrack = sleepTimer.mode {
            sleepTimer.cancel(); publishSleepTimer(); stop(); return
        }
        guard let next = queue.advance() else { stop(); return }
        startPlayback(of: next)
    }

    private func stop() {
        intendsToPlay = false
        active.player.stop()
        idle.player.stop()
        publish(state: .idle, track: nil)
        stateModel?.upNext = []
        stopTicker()
    }

    // MARK: - Crossfade / preload (driven by the ticker)

    private func tick() {
        guard let file = active.file else { return }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let position = currentSeconds(of: active)
        currentTime = min(position, duration)
        stateModel?.currentTime = currentTime
        tickSleepTimer()

        if transition == .crossfading { driveCrossfade(); return }
        guard intendsToPlay, transition == .none,
              let current = queue.currentTrack, let next = queue.nextTrack, next.id != current.id,
              duration > 1 else { return }
        let remaining = duration - position
        let overlap = fadePlanner.decision(outgoing: current, incoming: next, trailingSilence: 0, isManualSkip: false).overlap
        if overlap > 0, remaining <= overlap {
            beginCrossfade(to: next, overlap: overlap)
        } else if remaining <= overlap + 6, preloadedID != next.id {
            preload(next)               // warm the cache so the fade/handoff is instant
        }
    }

    private func preload(_ next: Track) {
        preloadedID = next.id
        Task { [weak self] in _ = await self?.resolveLocalURL(for: next) }
    }

    private func beginCrossfade(to next: Track, overlap: TimeInterval) {
        transition = .crossfading
        incomingTrack = next
        incomingLoudness = gain(for: next)
        crossfadeOverlap = overlap
        crossfadeStart = 0   // set once the incoming chain actually starts
        let generation = startGeneration
        Task { [weak self] in
            guard let self else { return }
            let url = await self.resolveLocalURL(for: next)
            await self.startIncoming(generation: generation, next: next, url: url, overlap: overlap)
        }
    }

    @MainActor
    private func startIncoming(generation: Int, next: Track, url: URL?, overlap: TimeInterval) {
        guard transition == .crossfading, startGeneration == generation else { return }
        guard let url, let file = openFile(url) else { cancelTransition(); return }
        let chain = idle
        chain.file = file
        chain.player.volume = 0
        startEngineIfNeeded()
        scheduleAndPlay(chain, file: file, fromSeconds: 0)
        crossfadeStart = monotonicNow
        log.info("crossfade → \"\(next.title, privacy: .public)\" over \(overlap, privacy: .public)s")
    }

    private func driveCrossfade() {
        guard crossfadeStart > 0 else { return }   // incoming not started yet
        let progress = crossfadeOverlap > 0 ? (monotonicNow - crossfadeStart) / crossfadeOverlap : 1
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        active.player.volume = clamp(masterVolume * loudnessGain * fade * Float(CrossfadeCurve.fadeOutGain(progress: progress)))
        idle.player.volume = clamp(masterVolume * incomingLoudness * fade * Float(CrossfadeCurve.fadeInGain(progress: progress)))
        if progress >= 1 { finishCrossfade() }
    }

    private func finishCrossfade() {
        guard transition == .crossfading, let next = incomingTrack else { return }
        active.player.stop()
        active.file = nil
        activeIsA.toggle()
        loudnessGain = incomingLoudness
        transition = .none
        incomingTrack = nil
        _ = queue.advance()
        applyEffectiveVolume()
        publish(state: .playing(trackID: next.id), track: next)
        publishQueue()
        sendStartReports(for: next)
        log.info("crossfade complete → \"\(next.title, privacy: .public)\"")
    }

    private func cancelTransition() {
        guard transition != .none else { return }
        idle.player.stop()
        idle.file = nil
        transition = .none
        incomingTrack = nil
        applyEffectiveVolume()
    }

    // MARK: - Helpers

    private func currentSeconds(of chain: Chain) -> TimeInterval {
        guard let nodeTime = chain.player.lastRenderTime,
              let playerTime = chain.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return chain.startOffset }
        return chain.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func applyEffectiveVolume() {
        guard transition != .crossfading else { return }
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        active.player.volume = clamp(masterVolume * loudnessGain * fade)
    }

    private func clamp(_ value: Float) -> Float { max(0, min(1, value)) }

    private func gain(for track: Track) -> Float {
        Float(LoudnessMath.playbackGain(
            normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
            preampDB: settings.loudnessPreampDB))
    }

    private func openFile(_ url: URL) -> AVAudioFile? {
        do { return try AVAudioFile(forReading: url) }
        catch { log.error("AVAudioFile open failed: \(error.localizedDescription, privacy: .public)"); return nil }
    }

    /// Local file for a track: offline download first, else the streaming cache
    /// (downloads the original file once, then reuses it).
    private func resolveLocalURL(for track: Track) async -> URL? {
        if let offline = DownloadStore.localURL(for: track) { return offline }
        let request = settings.playbackProfile.profile.request(for: track, network: .wifi)
        let remote = StreamURLBuilder.url(for: track.id, request: request, session: session)
        return try? await cache.localFile(for: track.id, remoteURL: remote)
    }

    private func bumpStartGeneration() -> Int { startGeneration += 1; return startGeneration }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { log.error("engine.start failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func activateSession() {
        guard !sessionActivated else { return }
        do { try AVAudioSession.sharedInstance().setActive(true); sessionActivated = true }
        catch { log.error("setActive failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tickSleepTimer() {
        guard sleepTimer.isActive else { return }
        if sleepTimer.shouldStop(now: monotonicNow) {
            sleepTimer.cancel(); cancelTransition(); stop(); publishSleepTimer(); return
        }
        if transition != .crossfading { applyEffectiveVolume() }
        publishSleepTimer()
    }

    // MARK: - Publishing

    private func sendStartReports(for track: Track) {
        Task {
            for report in reporter.trackStarted(id: track.id, at: 0) {
                try? await reporting.send(report, playSessionID: track.id)
            }
        }
    }

    private func publishQueue() { stateModel?.upNext = queue.upNext }

    private func publishSleepTimer() {
        stateModel?.sleepTimerActive = sleepTimer.isActive
        stateModel?.sleepTimerRemaining = sleepTimer.remaining(now: monotonicNow)
    }

    private func publishShuffleRepeat() {
        if stateModel?.isShuffled != queue.isShuffled { stateModel?.isShuffled = queue.isShuffled }
        if stateModel?.repeatMode != queue.repeatMode { stateModel?.repeatMode = queue.repeatMode }
    }

    private func publish(state newState: PlaybackState, track: Track?) {
        state = newState
        stateModel?.currentTrack = track
        if case .playing = newState { stateModel?.isPlaying = true } else { stateModel?.isPlaying = false }
        if case .failed(_, let message) = newState { stateModel?.errorMessage = message } else { stateModel?.errorMessage = nil }
    }
}
