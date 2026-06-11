import XCTest
@testable import JellyampCore

final class PlaybackProfileTests: XCTestCase {
    private func track(codec: String?, bitrate: Int?) -> Track {
        Track(id: "t", title: "t", artistName: "a", duration: 100, codec: codec, bitrate: bitrate)
    }

    func testFlacOnWifiDirectPlays() {
        let profile = PlaybackProfile()
        XCTAssertEqual(profile.request(for: track(codec: "flac", bitrate: 1_000_000), network: .wifi), .directPlay)
    }

    func testFlacOverCellularCapTranscodes() {
        let profile = PlaybackProfile(maxBitrateCellular: 320_000)
        let request = profile.request(for: track(codec: "flac", bitrate: 1_000_000), network: .cellular)
        XCTAssertEqual(request, .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000))
    }

    func testUnsupportedCodecTranscodes() {
        let profile = PlaybackProfile()
        let request = profile.request(for: track(codec: "wma", bitrate: 128_000), network: .wifi)
        XCTAssertEqual(request, .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000))
    }

    func testForceTranscodeOnCellular() {
        let profile = PlaybackProfile(forceTranscodeOnCellular: true)
        let request = profile.request(for: track(codec: "mp3", bitrate: 128_000), network: .cellular)
        XCTAssertEqual(request, .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000))
        XCTAssertEqual(profile.request(for: track(codec: "mp3", bitrate: 128_000), network: .wifi), .directPlay)
    }

    func testUnknownCodecIsConservativelyTranscoded() {
        let profile = PlaybackProfile()
        let request = profile.request(for: track(codec: nil, bitrate: nil), network: .wifi)
        XCTAssertEqual(request, .transcode(codec: "aac", container: "m4a", maxBitrate: 320_000))
    }
}

final class PlaybackReporterTests: XCTestCase {
    func testStartStopSequence() {
        var reporter = PlaybackReporter()
        let start = reporter.trackStarted(id: "t1", at: 0)
        XCTAssertEqual(start, [.started(trackID: "t1", positionTicks: 0)])
        let stop = reporter.stopped(at: 30)
        XCTAssertEqual(stop, [.stopped(trackID: "t1", positionTicks: 300_000_000)])
        XCTAssertTrue(reporter.stopped(at: 30).isEmpty, "double stop must not re-report")
    }

    func testTrackChangeStopsPreviousFirst() {
        var reporter = PlaybackReporter()
        _ = reporter.trackStarted(id: "t1", at: 0)
        let reports = reporter.trackStarted(id: "t2", at: 0, previousPosition: 180)
        XCTAssertEqual(reports, [
            .stopped(trackID: "t1", positionTicks: PlaybackReporter.ticks(from: 180)),
            .started(trackID: "t2", positionTicks: 0),
        ])
    }

    func testProgressIsThrottled() {
        var reporter = PlaybackReporter(progressInterval: 10)
        _ = reporter.trackStarted(id: "t1", at: 0)
        XCTAssertEqual(reporter.playbackTick(position: 1, isPaused: false, now: 1).count, 1)
        XCTAssertTrue(reporter.playbackTick(position: 5, isPaused: false, now: 5).isEmpty)
        XCTAssertEqual(reporter.playbackTick(position: 12, isPaused: false, now: 12).count, 1)
    }

    func testStateChangeBypassesThrottle() {
        var reporter = PlaybackReporter(progressInterval: 10)
        _ = reporter.trackStarted(id: "t1", at: 0)
        _ = reporter.playbackTick(position: 1, isPaused: false, now: 1)
        let pause = reporter.stateChanged(position: 2, isPaused: true, now: 2)
        XCTAssertEqual(pause, [.progress(trackID: "t1", positionTicks: PlaybackReporter.ticks(from: 2), isPaused: true)])
    }

    func testNoReportsWithoutActiveTrack() {
        var reporter = PlaybackReporter()
        XCTAssertTrue(reporter.playbackTick(position: 0, isPaused: false, now: 0).isEmpty)
        XCTAssertTrue(reporter.stateChanged(position: 0, isPaused: true, now: 0).isEmpty)
    }
}

final class LyricsTests: XCTestCase {
    func testParsesSyncedLrc() {
        let lrc = "[ar:Someone]\n[00:01.00]first line\n[00:05.50]second line\n"
        let lines = LyricsParser.parse(lrc: lrc)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].start ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(lines[1].start ?? -1, 5.5, accuracy: 1e-9)
        XCTAssertEqual(lines[0].text, "first line")
    }

    func testRepeatedTimestampsExpand() {
        let lines = LyricsParser.parse(lrc: "[00:10.00][01:10.00]chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["chorus", "chorus"])
        XCTAssertEqual(lines[1].start ?? -1, 70.0, accuracy: 1e-9)
    }

    func testTimelineBinarySearch() {
        let timeline = LyricsTimeline(lines: [
            LyricLine(start: 1, text: "a"),
            LyricLine(start: 5, text: "b"),
            LyricLine(start: 9, text: "c"),
        ])
        XCTAssertNil(timeline.activeLineIndex(at: 0.5))
        XCTAssertEqual(timeline.activeLineIndex(at: 1), 0)
        XCTAssertEqual(timeline.activeLineIndex(at: 6.2), 1)
        XCTAssertEqual(timeline.activeLineIndex(at: 100), 2)
    }

    func testUnsyncedTimelineHasNoActiveLine() {
        let timeline = LyricsTimeline(lines: [LyricLine(text: "just text")])
        XCTAssertFalse(timeline.isSynced)
        XCTAssertNil(timeline.activeLineIndex(at: 10))
    }
}
