import Foundation
import AVFoundation
import JellyampCore
import JellyfinBackend
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Behavioural scenarios for the real AudioEnginePlayer against fake audio
// nodes (see make.py). Run with scripts/engine-sim/run.sh.
//
// Timing: the fake nodes run on the wall clock, so scenarios wait real
// (fractions of) seconds and assert with generous tolerances.

var failures = 0
var checks = 0

@MainActor func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("    ok   \(message)")
    } else {
        failures += 1
        print("    FAIL \(message)")
    }
}

@MainActor func wait(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor final class Rig {
    let model = PlayerStateModel()
    let player: AudioEnginePlayer
    let engine: AVAudioEngine

    init(session: JellyfinSession, settings: AppSettings = AppSettings()) {
        SimWorld.shared.failing = []
        SimWorld.shared.loadDelay = 0
        SimWorld.shared.opened = []
        player = AudioEnginePlayer(session: session, settings: settings, stateModel: model)
        engine = AVAudioEngine.last!
    }

    var playingNodes: Int { engine.playerNodes.filter(\.isPlaying).count }
    var current: String? { model.currentTrack?.title }
    var time: TimeInterval { model.currentTime }
}

func settings(crossfade: TimeInterval = 0, sleepFade: TimeInterval = 10) -> AppSettings {
    var settings = AppSettings()
    settings.crossfadeDuration = crossfade
    settings.sleepTimerFadeOut = sleepFade
    return settings
}

struct ItemDetail: Decodable {
    struct UserDataDto: Decodable { var PlayCount: Int? }
    var UserData: UserDataDto?
}
struct SessionInfo: Decodable {
    struct NowPlaying: Decodable { var Id: String }
    struct PlayStateDto: Decodable { var PositionTicks: Int64?; var IsPaused: Bool?; var PlayMethod: String? }
    var DeviceId: String?
    var NowPlayingItem: NowPlaying?
    var PlayState: PlayStateDto?
}

func playCount(_ id: String, session: JellyfinSession) async -> Int {
    let request = session.request(path: "Users/\(session.userID ?? "")/Items/\(id)")
    guard let (data, _) = try? await URLSessionTransport().send(request),
          let detail = try? JSONDecoder().decode(ItemDetail.self, from: data) else { return -1 }
    return detail.UserData?.PlayCount ?? 0
}

func ownSession(_ session: JellyfinSession) async -> SessionInfo? {
    guard let (data, _) = try? await URLSessionTransport().send(session.request(path: "Sessions")),
          let all = try? JSONDecoder().decode([SessionInfo].self, from: data) else { return nil }
    return all.first { $0.DeviceId == session.deviceID }
}

@MainActor func runAll() async {
    var session = JellyfinSession(serverURL: URL(string: "http://127.0.0.1:9")!, deviceID: "sim", accessToken: "x", userID: "u")
    var real: [Track] = []
    let live = ProcessInfo.processInfo.environment["JELLYFIN_TEST_URL"].flatMap(URL.init(string:))
    if let live {
        let fresh = JellyfinSession(serverURL: live, deviceID: "jellyamp-sim-\(UUID().uuidString)", deviceName: "Engine Sim")
        if let authenticated = try? await JellyfinAuthenticator().authenticateByName(session: fresh, username: "demo", password: "demo") {
            session = authenticated
            let library = MusicLibraryAPI(session: session)
            if let album = try? await library.albums(limit: 1).first {
                real = (try? await library.tracks(inAlbum: album.id)) ?? []
            }
            if let more = try? await library.albums(limit: 3) {
                for album in more.dropFirst() { real += (try? await library.tracks(inAlbum: album.id)) ?? [] }
            }
        }
    }
    let liveReports = real.count >= 4
    print(liveReports ? "live Jellyfin: \(real.count) real track IDs" : "no live Jellyfin — reports go nowhere")

    /// A track named `name` lasting `duration` seconds, each in its own album
    /// unless one is given (same album + consecutive index = gapless join).
    func track(_ name: String, _ duration: TimeInterval, album: String? = nil, index: Int? = nil, slot: Int = 0,
               codec: String = "mp3") -> Track {
        let id = liveReports ? real[slot % real.count].id : "id-\(name)"
        return Track(id: id, title: name, artistName: "Sim", albumName: album, albumID: album ?? "album-\(name)",
                     indexNumber: index, duration: duration, container: codec, codec: codec, bitrate: 192_000)
    }
    let A = { (d: TimeInterval) in track("A", d, slot: 0) }
    let B = { (d: TimeInterval) in track("B", d, slot: 1) }
    let C = { (d: TimeInterval) in track("C", d, slot: 2) }
    let D = { (d: TimeInterval) in track("D", d, slot: 3) }

    print("S1  plays through a queue and goes idle at the end")
    do {
        let rig = Rig(session: session)
        rig.player.load(queue: PlayQueue(tracks: [A(1.5), B(1.5)]))
        check(rig.model.isLoading, "loading is published before audio starts")
        await wait(0.5)
        check(rig.current == "A" && rig.model.isPlaying && !rig.model.isLoading, "A is playing")
        check(rig.time > 0.2 && rig.time < 0.8, "clock runs (\(rig.time))")
        check(rig.model.quality?.delivery == .direct, "quality badge: direct")
        await wait(1.5)
        check(rig.current == "B" && rig.model.isPlaying, "advanced to B when A ended")
        check(rig.model.history.map(\.title) == ["A"], "history holds A")
        await wait(1.6)
        check(rig.model.currentTrack == nil && !rig.model.isPlaying, "idle after the last track")
        check(rig.player.state == .idle, "state is .idle")
        rig.player.play()
        check(!rig.model.isPlaying, "play() with nothing queued does not claim to be playing")
        rig.player.enqueue([C(2)])
        await wait(0.4)
        check(rig.current == "C" && rig.model.isPlaying, "enqueue after the end starts the NEW track, not the old queue")
    }

    print("S2  pause keeps the clock; seek while paused stays paused")
    do {
        let rig = Rig(session: session)
        rig.player.load(queue: PlayQueue(tracks: [A(8)]))
        await wait(0.6)
        rig.player.pause()
        let pausedAt = rig.time
        await wait(0.5)
        check(!rig.model.isPlaying && abs(rig.time - pausedAt) < 0.15 && rig.time > 0.3, "paused clock holds at \(pausedAt), shows \(rig.time)")
        rig.player.seek(to: 4)
        check(abs(rig.time - 4) < 0.01, "seek target is shown immediately")
        await wait(0.4)
        check(!rig.model.isPlaying && rig.playingNodes == 0, "still paused after seeking")
        check(abs(rig.time - 4) < 0.15, "clock sits at the seek target (\(rig.time))")
        rig.player.play()
        await wait(0.5)
        check(rig.model.isPlaying && rig.time > 4.3 && rig.time < 4.9, "resumes from the seek target (\(rig.time))")
        rig.player.seek(to: 999)
        await wait(0.3)
        check(rig.current == "A" && rig.time <= 8, "seek past the end is clamped (\(rig.time))")
    }

    print("S3  skip while the old track runs out during the load does not skip twice")
    do {
        let rig = Rig(session: session)
        SimWorld.shared.loadDelay = 0.4
        rig.player.load(queue: PlayQueue(tracks: [A(1.2), B(3), C(3)]))
        await wait(1.4)   // A started at 0.4, is at ~1.0
        rig.player.skipToNext()
        check(rig.current == "B" && rig.model.isLoading, "B is loading")
        await wait(1.2)   // A ran out at ~1.6 while B was loading
        check(rig.current == "B" && rig.model.isPlaying, "B plays (not C)")
        check(rig.time > 0.3 && rig.time < 1.2, "B's own clock (\(rig.time))")
    }

    print("S4  crossfade overlaps both chains, then hands over")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 1))
        rig.player.load(queue: PlayQueue(tracks: [A(3), B(3)]))
        await wait(2.5)
        check(rig.playingNodes == 2, "both nodes sound during the overlap")
        check(rig.current == "A", "still showing A during the fade")
        let volumes = rig.engine.playerNodes.map(\.volume).sorted()
        check(volumes.first! > 0.05 && volumes.last! < 0.999, "equal-power ramps in progress \(volumes)")
        await wait(0.9)
        check(rig.current == "B" && rig.playingNodes == 1, "handed over to B")
        check(rig.time > 0.9 && rig.time < 2.0, "B's clock includes the overlap (\(rig.time))")
        check(rig.engine.playerNodes.filter(\.isPlaying).first?.volume == 1, "B at full level")
        check(rig.model.upNext.isEmpty && rig.model.history.map(\.title) == ["A"], "queue advanced once")
    }

    print("S5  consecutive album tracks join without crossfade")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 1))
        rig.player.load(queue: PlayQueue(tracks: [track("A", 2, album: "x", index: 1, slot: 0), track("B", 2, album: "x", index: 2, slot: 1)]))
        await wait(1.6)
        check(rig.playingNodes == 1 && rig.current == "A", "no overlap inside an album")
        await wait(0.8)
        check(rig.current == "B" && rig.model.isPlaying, "butt join into B")
    }

    print("S6  a broken track is skipped; a dead server stops after three")
    do {
        let rig = Rig(session: session)
        SimWorld.shared.failing = [B(1).id]
        rig.player.load(queue: PlayQueue(tracks: [A(1), B(1), C(3)]))
        await wait(1.6)
        check(rig.current == "C" && rig.model.isPlaying, "B failed → C plays")
        check(rig.model.errorMessage == nil, "no error left on screen")
        SimWorld.shared.failing = Set([A(1), B(1), C(1), D(1)].map(\.id))
        rig.player.load(queue: PlayQueue(tracks: [A(1), B(1), C(1), D(1)]))
        await wait(0.8)
        check(rig.current == "C" && !rig.model.isPlaying, "gave up on the third failure (at \(rig.current ?? "nil"))")
        check(rig.model.errorMessage != nil, "error is shown")
        check(rig.playingNodes == 0, "nothing sounds")
        SimWorld.shared.failing = []
        rig.player.play()
        await wait(0.4)
        check(rig.current == "C" && rig.model.isPlaying && rig.model.errorMessage == nil, "play() retries once the server is back")
    }

    print("S7  sleep timer: end of track, with crossfade on")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 1))
        rig.player.load(queue: PlayQueue(tracks: [A(2.5), B(3)]))
        await wait(0.4)
        rig.player.startSleepTimer(duration: nil)
        check(rig.model.sleepTimerActive, "timer armed")
        await wait(1.7)   // inside what would be the crossfade window
        check(rig.playingNodes == 1, "no crossfade into the next track")
        await wait(0.9)
        check(!rig.model.isPlaying && rig.playingNodes == 0, "stopped when A ended")
        check(rig.current == "B" && rig.time == 0, "parked on B at 0:00")
        check(!rig.model.sleepTimerActive, "timer cleared")
        rig.player.seek(to: 1)   // scrubbing the parked track must not start it
        await wait(0.3)
        check(!rig.model.isPlaying && rig.playingNodes == 0 && abs(rig.time - 1) < 0.1, "seek on the parked track stays paused")
        rig.player.play()
        await wait(0.5)
        check(rig.current == "B" && rig.model.isPlaying && rig.time > 1.2, "play() continues with B (\(rig.time))")
    }

    print("S8  sleep timer: timed, fades then pauses (resumable)")
    do {
        let rig = Rig(session: session, settings: settings(sleepFade: 1))
        rig.player.load(queue: PlayQueue(tracks: [A(10)]))
        await wait(0.3)
        rig.player.startSleepTimer(duration: 1.4)
        await wait(1.0)
        let fading = rig.engine.playerNodes.filter(\.isPlaying).first?.volume ?? -1
        check(fading > 0 && fading < 0.9, "fading out (\(fading))")
        await wait(0.8)
        check(!rig.model.isPlaying && rig.current == "A", "paused, track kept")
        check(rig.time > 1.2, "position kept (\(rig.time))")
        check(rig.engine.playerNodes.allSatisfy { $0.volume == 1 || $0.playedSeconds == 0 }, "level restored for the resume")
        let before = rig.time
        rig.player.play()
        await wait(0.5)
        check(rig.model.isPlaying && rig.time > before + 0.3, "resumes where it faded out (\(rig.time))")
    }

    print("S9  engine stopped by the system: route change while playing, interruption while paused")
    do {
        let rig = Rig(session: session)
        rig.player.load(queue: PlayQueue(tracks: [A(9)]))
        await wait(1.0)
        rig.engine.simulateConfigurationChange()
        await wait(0.6)
        check(rig.engine.isRunning && rig.model.isPlaying && rig.playingNodes == 1, "engine restarted and playing")
        check(rig.time > 1.2 && rig.time < 2.0, "continues where it was (\(rig.time))")
        check(SimWorld.shared.opened.last?.hasSuffix("@1") == true, "stream reopened at the old position \(SimWorld.shared.opened)")
        // Phone call: SystemMediaController pauses, the system stops the engine.
        rig.player.pause()
        rig.engine.simulateInterruption()
        let heldAt = rig.time
        await wait(0.5)
        check(abs(rig.time - heldAt) < 0.15, "clock holds through the interruption")
        rig.player.play()
        await wait(0.6)
        check(rig.engine.isRunning && rig.model.isPlaying && rig.playingNodes == 1, "resumes after the interruption")
        check(rig.time > heldAt + 0.2 && rig.time < heldAt + 1.0, "from the same position (\(rig.time) vs \(heldAt))")
    }

    print("S10 queue edits during a crossfade")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 1))
        rig.player.load(queue: PlayQueue(tracks: [A(3), B(3), C(3)]))
        await wait(2.4)
        check(rig.playingNodes == 2, "crossfading into B")
        rig.player.removeUpNext(at: 0)   // B is removed while it fades in
        await wait(1.5)
        check(rig.current == "C" && rig.model.isPlaying, "C plays — audio and queue agree (\(rig.current ?? "nil"))")
        check(rig.model.upNext.isEmpty && rig.model.history.map(\.title) == ["A"], "queue is A | C")
        check(rig.playingNodes == 1, "one node left")
    }

    print("S11 skip during a crossfade completes the handover; pause freezes it")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 1))
        rig.player.load(queue: PlayQueue(tracks: [A(3), B(4), C(3)]))
        await wait(2.4)
        rig.player.skipToNext()
        check(rig.current == "B" && rig.playingNodes == 1, "skip = finish the fade into B")
        await wait(0.3)
        check(rig.time > 0.4 && rig.time < 1.2, "B keeps its position, not restarted (\(rig.time))")

        let second = Rig(session: session, settings: settings(crossfade: 1))
        second.player.load(queue: PlayQueue(tracks: [A(3), B(4)]))
        await wait(2.4)
        second.player.pause()
        await wait(1.4)   // longer than the fade
        check(second.current == "A" && !second.model.isPlaying && second.playingNodes == 0, "paused mid-fade: nothing advances")
        second.player.play()
        check(second.playingNodes == 2, "both chains resume")
        await wait(1.0)
        check(second.current == "B" && second.model.isPlaying, "fade completes after resuming")
    }

    print("S12 previous: restart after 3 s, else previous track; repeat one")
    do {
        let rig = Rig(session: session)
        rig.player.load(queue: PlayQueue(tracks: [A(9), B(9)], startAt: 1))
        await wait(0.5)
        rig.player.skipToPrevious()
        await wait(0.3)
        check(rig.current == "A", "early press goes to the previous track")
        await wait(3.2)
        rig.player.skipToPrevious()
        await wait(0.3)
        check(rig.current == "A" && rig.time < 0.6 && rig.model.isPlaying, "late press restarts the track (\(rig.time))")
        rig.player.skipToPrevious()
        await wait(0.2)
        check(rig.current == "A", "first track: previous restarts")

        let repeatRig = Rig(session: session, settings: settings(crossfade: 1))
        repeatRig.player.load(queue: PlayQueue(tracks: [A(1.2), B(5)]))
        repeatRig.player.setRepeatMode(.one)
        check(repeatRig.model.repeatMode == .one, "repeat one published")
        await wait(1.9)
        check(repeatRig.current == "A" && repeatRig.model.isPlaying && repeatRig.time < 1.0, "A repeats (\(repeatRig.time))")
        repeatRig.player.setShuffle(true)
        check(repeatRig.model.isShuffled, "shuffle published")
    }

    print("S13 seek while a new track is still loading")
    do {
        let rig = Rig(session: session)
        rig.player.load(queue: PlayQueue(tracks: [A(9)]))
        await wait(0.6)
        SimWorld.shared.loadDelay = 0.4
        rig.player.load(queue: PlayQueue(tracks: [B(9)]))
        rig.player.seek(to: 5)
        await wait(1.0)
        check(rig.current == "B" && rig.model.isPlaying, "B plays")
        check(rig.time > 5.3 && rig.time < 6.0, "from the seek target (\(rig.time))")
        check(rig.playingNodes == 1, "A is gone")
    }

    print("S14 loudness: measured fallback, shared album gain, peak-safe boost")
    do {
        func playingVolume(_ rig: Rig) -> Float { rig.engine.playerNodes.first(where: \.isPlaying)?.volume ?? -1 }
        func boost(_ rig: Rig) -> Float { rig.engine.nodes.compactMap { ($0 as? AVAudioUnitEQ)?.globalGain }.max() ?? -1 }
        let loudA = A(1.2), quietB = B(4)
        // A: −8 LUFS → −10 dB. B: −12 LUFS → −6 dB.
        let lookup: @Sendable (String) async -> MeasuredLoudness? = { id in
            MeasuredLoudness(integratedLufs: id == loudA.id ? -8 : -12, truePeakDB: -1)
        }
        let rig = Rig(session: session)
        rig.player.loudnessLookup = lookup
        rig.player.load(queue: PlayQueue(tracks: [loudA, quietB]))
        await wait(0.5)
        check(abs(playingVolume(rig) - 0.316) < 0.01, "A levelled by −10 dB from its measured LUFS (\(playingVolume(rig)))")
        await wait(1.2)
        check(rig.current == "B" && abs(playingVolume(rig) - 0.501) < 0.01, "B, another album, gets its own −6 dB (\(playingVolume(rig)))")

        let album = Rig(session: session)
        album.player.loudnessLookup = lookup
        album.player.load(queue: PlayQueue(tracks: [track("A", 1.2, album: "x", index: 1, slot: 0), track("B", 4, album: "x", index: 2, slot: 1)]))
        await wait(0.5)
        check(abs(playingVolume(album) - 0.316) < 0.01, "album track 1 at the album's gain (\(playingVolume(album)))")
        await wait(1.2)
        check(album.current == "B" && abs(playingVolume(album) - 0.316) < 0.01, "album track 2 does not jump in level (\(playingVolume(album)))")

        let quiet = Rig(session: session)
        quiet.player.loudnessLookup = { _ in MeasuredLoudness(integratedLufs: -24, truePeakDB: -4) }
        quiet.player.load(queue: PlayQueue(tracks: [C(5)]))
        await wait(0.5)
        check(playingVolume(quiet) == 1 && abs(boost(quiet) - 4) < 0.01, "quiet track: +6 dB wanted, +4 dB granted by its −4 dBTP peak (\(boost(quiet)))")
        var off = AppSettings()
        off.loudnessLevelingEnabled = false
        quiet.player.updateSettings(off)
        check(boost(quiet) == 0 && playingVolume(quiet) == 1, "turning leveling off applies to the playing track")
    }

    print("S15 visualizer tap follows the engine")
    do {
        let rig = Rig(session: session)
        rig.player.retainSpectrum()   // before the engine runs: deferred
        rig.player.load(queue: PlayQueue(tracks: [A(5)]))
        await wait(0.4)
        rig.engine.simulateConfigurationChange()
        await wait(0.5)
        check(rig.engine.isRunning && rig.model.isPlaying, "recovered with a tap retained")
        rig.player.releaseSpectrum()
        rig.player.releaseSpectrum()   // unbalanced release is harmless
        rig.player.retainSpectrum()
        check(rig.model.isPlaying, "retain/release does not disturb playback")
    }

    print("S16 a codec the device cannot stream is transcoded progressively, seeks by time")
    do {
        let rig = Rig(session: session)
        let vorbis = track("V", 9, slot: 3, codec: "vorbis")
        rig.player.load(queue: PlayQueue(tracks: [vorbis]))
        await wait(0.4)
        check(rig.model.isPlaying && rig.model.quality?.delivery == .transcoded, "plays, badge says transcoded")
        check(rig.model.quality?.summary == "MP3 · 44.1 kHz · 320 kbps", "badge shows what is streamed (\(rig.model.quality?.summary ?? "nil"))")
        rig.player.seek(to: 5)
        await wait(0.5)
        check(SimWorld.shared.opened.last == "\(vorbis.id)@5", "seek asks the server to start at 5 s \(SimWorld.shared.opened)")
        check(rig.time > 5.2 && rig.time < 5.9 && rig.model.isPlaying, "clock continues from 5 s (\(rig.time))")
    }

    if liveReports {
        print("S17 reports reach Jellyfin: one play per track, seeks and pauses included")
        let rig = Rig(session: session)
        let a = A(2.5), b = B(1.5)
        let beforeA = await playCount(a.id, session: session)
        let beforeB = await playCount(b.id, session: session)
        rig.player.load(queue: PlayQueue(tracks: [a, b]))
        await wait(0.5)
        rig.player.seek(to: 1.0)
        await wait(0.3)
        rig.player.seek(to: 1.2)
        await wait(0.3)
        rig.player.pause()
        await wait(0.5)
        let paused = await ownSession(session)
        check(paused?.NowPlayingItem?.Id == a.id, "server shows A as now playing")
        check(paused?.PlayState?.IsPaused == true, "server shows it paused")
        check((paused?.PlayState?.PositionTicks ?? 0) > 10_000_000, "with the seeked position (\(paused?.PlayState?.PositionTicks ?? -1))")
        check(paused?.PlayState?.PlayMethod == "DirectPlay", "play method DirectPlay")
        rig.player.play()
        await wait(1.6)   // A ends → B
        check(rig.current == "B", "B playing")
        let mid = await ownSession(session)
        check(mid?.NowPlayingItem?.Id == b.id && mid?.PlayState?.IsPaused == false, "server shows B playing")
        await wait(1.8)   // B ends → idle
        await wait(0.5)
        let afterA = await playCount(a.id, session: session)
        let afterB = await playCount(b.id, session: session)
        check(afterA == beforeA + 1, "A counted exactly once despite two seeks and a pause (\(beforeA) → \(afterA))")
        check(afterB == beforeB + 1, "B counted once (\(beforeB) → \(afterB))")
        let ended = await ownSession(session)
        check(ended?.NowPlayingItem == nil, "session closed with a stop report")
    }

    print("S18 shutdown (sign-out, expired session) silences the engine at once")
    do {
        let rig = Rig(session: session, settings: settings(crossfade: 2))
        rig.player.load(queue: PlayQueue(tracks: [A(3), B(3), C(3)]))
        rig.player.startSleepTimer(duration: 600)
        await wait(1.4)   // inside the A → B crossfade: both nodes sound
        check(rig.playingNodes >= 1 && rig.model.currentTrack != nil, "playing before shutdown")
        rig.player.shutdown()
        check(rig.playingNodes == 0, "no node plays any more")
        check(rig.model.currentTrack == nil && !rig.model.isPlaying && !rig.model.isLoading, "published state is idle")
        check(rig.model.upNext.isEmpty && rig.model.history.isEmpty, "queue is gone")
        check(!rig.model.sleepTimerActive, "sleep timer cancelled")
        await wait(2.2)   // where B would have taken over
        check(rig.playingNodes == 0 && rig.model.currentTrack == nil, "nothing restarts afterwards")
        rig.player.play()
        await wait(0.3)
        check(rig.playingNodes == 0, "play after shutdown has nothing to play")
        if liveReports {
            await wait(0.5)
            let ended = await ownSession(session)
            check(ended?.NowPlayingItem == nil, "server session closed by the final stop report")
        }
    }

    print("\n\(checks - failures)/\(checks) checks passed")
}

Task { @MainActor in
    await runAll()
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
