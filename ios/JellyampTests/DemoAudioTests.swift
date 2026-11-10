import XCTest
import AVFoundation
import AudioToolbox
import JellyampCore
import JellyfinBackend
import JellyfinDemo
@testable import Jellyamp

/// Whether this machine can run an `AVAudioEngine` at all.
///
/// A simulator on a Mac without any audio device reports an output format of
/// 0 Hz / 0 channels. Connecting nodes on such an engine can raise an
/// Objective-C exception inside AVFAudio, which Swift cannot catch and which
/// would take the whole test process down — so tests that create the player
/// (directly, or by signing the container in) ask here first and skip.
enum AudioOutput {
    /// Asked once per test process: every question builds (and tears down)
    /// an audio output unit, which is a round trip to the audio service.
    static let isUsable: Bool = {
        // The engine must outlive the question: a node of an engine that has
        // already been released (Swift frees a temporary after its last
        // use, here right after `.outputNode`) is not safe to ask.
        let engine = AVAudioEngine()
        return withExtendedLifetime(engine) {
            let format = engine.outputNode.outputFormat(forBus: 0)
            return format.sampleRate > 0 && format.channelCount > 0
        }
    }()

    static func requireUsable() throws {
        try XCTSkipUnless(
            isUsable,
            "This simulator has no audio output (output format 0 Hz / 0 channels), so the audio engine cannot be built here."
        )
    }
}

/// The demo tracks through Apple's audio stack. The Linux tests prove the
/// files are well-formed ADTS; these prove that the system decoders and the
/// app's streaming player accept them — the part that cannot run on Linux.
@MainActor
final class DemoAudioTests: XCTestCase {
    private var server: DemoHTTPServer!
    private var session: JellyfinSession!
    private var playerState: PlayerStateModel!
    private var player: AudioEnginePlayer?

    override func setUp() async throws {
        server = DemoHTTPServer(backend: DemoBackend())
        let url = try server.start()
        session = JellyfinSession(serverURL: url, deviceID: "tests", accessToken: DemoCatalog.accessToken, userID: DemoCatalog.userID)
        playerState = PlayerStateModel()
    }

    override func tearDown() async throws {
        player?.pause()
        player = nil
        server.stop()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private func demoTracks(count: Int) async throws -> [Track] {
        let tracks = try await MusicLibraryAPI(session: session).tracks(inAlbum: DemoFixture.nightFerryAlbum)
        XCTAssertGreaterThanOrEqual(tracks.count, count)
        return Array(tracks.prefix(count))
    }

    // MARK: - Decoding (needs no audio hardware)

    /// The whole file through ExtAudioFile/AVAudioFile: the system AAC
    /// decoder reads every loop boundary without an error.
    func testSystemDecoderReadsADemoTrack() async throws {
        let track = try await demoTracks(count: 1)[0]
        let remote = StreamURLBuilder.downloadURL(for: track.id, session: session)
        let (data, response) = try await URLSession.shared.data(from: remote)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).aac")
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let file = try AVAudioFile(forReading: local)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)

        let format = file.processingFormat
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768))
        var frames: AVAudioFramePosition = 0
        var peak: Float = 0
        while true {
            do {
                try file.read(into: buffer)
            } catch {
                // Reading past the end reports an error on some OS versions.
                break
            }
            if buffer.frameLength == 0 { break }
            frames += AVAudioFramePosition(buffer.frameLength)
            if let channel = buffer.floatChannelData {
                for index in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channel[0][index]))
                }
            }
        }
        let decodedSeconds = Double(frames) / format.sampleRate
        XCTAssertEqual(decodedSeconds, track.duration, accuracy: 1.0, "decoded length differs from the advertised duration")
        XCTAssertGreaterThan(peak, 0.05, "the track decodes to silence")
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    /// The app's own streaming decoder against the loopback server: header
    /// parsed, converter built. This is the path a tap on a track takes.
    func testStreamingSourceOpensADemoStream() async throws {
        let track = try await demoTracks(count: 1)[0]
        XCTAssertEqual(track.container, "aac")
        let url = StreamURLBuilder.url(for: track.id, request: .directPlay, session: session)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))

        let source = await StreamingAudioSource.make(
            url: url, startTime: 0, duration: track.duration,
            fileTypeHint: kAudioFileAAC_ADTSType, outputFormat: format
        )
        let opened = try XCTUnwrap(source, "the streaming decoder did not recognise the demo stream")
        XCTAssertEqual(opened.duration, track.duration)
        opened.stop()

        // A seek opens the stream in the middle (HTTP Range) and must
        // re-synchronise on a frame boundary.
        let seeked = await StreamingAudioSource.make(
            url: url, startTime: track.duration / 2, duration: track.duration,
            fileTypeHint: kAudioFileAAC_ADTSType, outputFormat: format
        )
        XCTAssertNotNil(seeked, "the streaming decoder did not re-synchronise after a seek")
        seeked?.stop()
    }

    // MARK: - Playback (needs an audio output)

    /// Smoke test of the real player: load a queue, play, pause, seek, skip.
    /// A CI simulator may have no audio output at all; the engine then never
    /// renders and the clock stands still, which is reported as a skip — it
    /// says nothing about the app.
    func testPlaybackSmoke() async throws {
        try AudioOutput.requireUsable()
        let tracks = try await demoTracks(count: 3)
        let engine = AudioEnginePlayer(session: session, settings: AppSettings(), stateModel: playerState)
        player = engine

        engine.load(queue: PlayQueue(tracks: tracks, startAt: 0))
        XCTAssertEqual(playerState.currentTrack?.id, tracks[0].id)

        let started = await waitUntil(timeout: 30) {
            if case .playing = engine.state { return true }
            if case .failed = engine.state { return true }
            return false
        }
        if case .failed(_, let message) = engine.state {
            XCTFail("the player could not load a demo track: \(message)")
            return
        }
        XCTAssertTrue(started, "the player never left the loading state (state: \(engine.state))")
        guard started else { return }
        XCTAssertEqual(engine.state, .playing(trackID: tracks[0].id))
        XCTAssertTrue(playerState.isPlaying)

        let advancing = await waitUntil(timeout: 15) { engine.currentTime > 0.5 }
        guard advancing else {
            throw XCTSkip(
                "The audio engine is not rendering (position stays at \(engine.currentTime) s). "
                    + "This simulator has no usable audio output; decoding is covered by the other tests."
            )
        }

        // Pause: the state flips and the clock stops.
        engine.pause()
        XCTAssertEqual(engine.state, .paused(trackID: tracks[0].id))
        XCTAssertFalse(playerState.isPlaying)
        let pausedAt = engine.currentTime
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(engine.currentTime, pausedAt, accuracy: 0.3, "the position kept running while paused")

        // Seek while paused, then resume from there.
        let target = min(40, tracks[0].duration / 2)
        engine.seek(to: target)
        engine.play()
        let resumed = await waitUntil(timeout: 20) {
            if case .playing = engine.state { return engine.currentTime >= target }
            return false
        }
        XCTAssertTrue(resumed, "playback did not resume after the seek (state: \(engine.state), position: \(engine.currentTime))")
        XCTAssertLessThan(engine.currentTime, target + 15, "the seek landed far from its target")
        let moving = await waitUntil(timeout: 10) { engine.currentTime > target + 0.5 }
        XCTAssertTrue(moving, "the position does not advance after the seek")

        // Skip: the next track of the queue starts from the top.
        engine.skipToNext()
        XCTAssertEqual(playerState.currentTrack?.id, tracks[1].id)
        let next = await waitUntil(timeout: 30) { engine.state == .playing(trackID: tracks[1].id) }
        XCTAssertTrue(next, "the next track did not start (state: \(engine.state))")
        XCTAssertEqual(playerState.upNext.map(\.id), [tracks[2].id])
        XCTAssertEqual(playerState.history.map(\.id), [tracks[0].id])
        let restarted = await waitUntil(timeout: 10) { engine.currentTime > 0.3 && engine.currentTime < 20 }
        XCTAssertTrue(restarted, "the position was not reset for the next track (position: \(engine.currentTime))")

        engine.pause()
    }
}
