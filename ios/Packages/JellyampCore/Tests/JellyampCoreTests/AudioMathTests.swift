import XCTest
@testable import JellyampCore

final class CrossfadeCurveTests: XCTestCase {
    func testEqualPowerSumIsConstant() {
        for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
            let out = CrossfadeCurve.fadeOutGain(progress: progress)
            let inn = CrossfadeCurve.fadeInGain(progress: progress)
            XCTAssertEqual(out * out + inn * inn, 1.0, accuracy: 1e-9, "power must stay constant at \(progress)")
        }
    }

    func testEndpoints() {
        XCTAssertEqual(CrossfadeCurve.fadeOutGain(progress: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(CrossfadeCurve.fadeOutGain(progress: 1), 0.0, accuracy: 1e-12)
        XCTAssertEqual(CrossfadeCurve.fadeInGain(progress: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(CrossfadeCurve.fadeInGain(progress: 1), 1.0, accuracy: 1e-12)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(CrossfadeCurve.fadeInGain(progress: 2), 1.0, accuracy: 1e-12)
        XCTAssertEqual(CrossfadeCurve.fadeOutGain(progress: -1), 1.0, accuracy: 1e-12)
    }
}

final class SweetFadePlannerTests: XCTestCase {
    private func track(_ id: String, album: String?, index: Int?, disc: Int? = 1, duration: TimeInterval = 240) -> Track {
        Track(id: id, title: id, artistName: "A", albumID: album, indexNumber: index, discNumber: disc, duration: duration)
    }

    func testConsecutiveAlbumTracksEndingHotJoinGapless() {
        let planner = SweetFadePlanner(fadeDuration: 4)
        let decision = planner.decision(
            outgoing: track("a", album: "x", index: 3),
            incoming: track("b", album: "x", index: 4),
            trailingSilence: 0.05,
            isManualSkip: false
        )
        XCTAssertTrue(decision.isGaplessJoin)
        XCTAssertEqual(decision.overlap, 0)
    }

    func testManualSkipFadesEvenOnGaplessAlbum() {
        let planner = SweetFadePlanner(fadeDuration: 4)
        let decision = planner.decision(
            outgoing: track("a", album: "x", index: 3),
            incoming: track("b", album: "x", index: 4),
            trailingSilence: 0.05,
            isManualSkip: true
        )
        XCTAssertFalse(decision.isGaplessJoin)
        XCTAssertEqual(decision.overlap, 4)
    }

    func testColdEndingShortensFade() {
        let planner = SweetFadePlanner(fadeDuration: 6)
        let decision = planner.decision(
            outgoing: track("a", album: "x", index: 1),
            incoming: track("b", album: "y", index: 1),
            trailingSilence: 3.5,
            isManualSkip: false
        )
        XCTAssertEqual(decision.overlap, 3)
    }

    func testZeroFadeDurationDisablesFades() {
        let planner = SweetFadePlanner(fadeDuration: 0)
        let decision = planner.decision(
            outgoing: track("a", album: "x", index: 1),
            incoming: track("b", album: "y", index: 1),
            trailingSilence: 1,
            isManualSkip: false
        )
        XCTAssertEqual(decision.overlap, 0)
        XCTAssertFalse(decision.isGaplessJoin)
    }

    func testOverlapCappedAtHalfShortestTrack() {
        let planner = SweetFadePlanner(fadeDuration: 30)
        let decision = planner.decision(
            outgoing: track("a", album: "x", index: 1, duration: 20),
            incoming: track("b", album: "y", index: 1, duration: 300),
            trailingSilence: 0.5,
            isManualSkip: false
        )
        XCTAssertEqual(decision.overlap, 10)
    }
}

final class LoudnessMathTests: XCTestCase {
    func testDbRoundTrip() {
        XCTAssertEqual(LoudnessMath.linearGain(fromDB: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(LoudnessMath.linearGain(fromDB: -6.0), 0.5012, accuracy: 1e-3)
        XCTAssertEqual(LoudnessMath.db(fromLinearGain: LoudnessMath.linearGain(fromDB: -4.2)), -4.2, accuracy: 1e-9)
    }

    func testGainFromLufs() {
        XCTAssertEqual(LoudnessMath.gainDB(integratedLufs: -9.0), -9.0, accuracy: 1e-12)
        XCTAssertEqual(LoudnessMath.gainDB(integratedLufs: -23.0), 5.0, accuracy: 1e-12)
    }

    func testPlaybackGainClampsAtTruePeak() {
        // +6 dB requested but peak at -2 dBTP: only +2 dB headroom.
        let gain = LoudnessMath.playbackGain(normalizationGainDB: 6, truePeakDB: -2)
        XCTAssertEqual(LoudnessMath.db(fromLinearGain: gain), 2.0, accuracy: 1e-9)
    }

    func testMissingMetadataIsUnityPlusPreamp() {
        XCTAssertEqual(LoudnessMath.playbackGain(normalizationGainDB: nil), 1.0, accuracy: 1e-12)
        let withPreamp = LoudnessMath.playbackGain(normalizationGainDB: nil, preampDB: -3)
        XCTAssertEqual(LoudnessMath.db(fromLinearGain: withPreamp), -3.0, accuracy: 1e-9)
    }
}

final class SilenceTrimmerTests: XCTestCase {
    func testTrimsLeadingAndTrailingSilence() {
        let trimmer = SilenceTrimmer(threshold: 0.01)
        let samples: [Float] = [0, 0, 0, 0.5, 0.4, 0.3, 0, 0]
        let result = trimmer.audibleRange(of: samples)
        XCTAssertEqual(result, SilenceTrimmer.Result(startFrame: 3, endFrame: 6))
        XCTAssertEqual(result?.audibleFrameCount, 3)
    }

    func testAllSilentReturnsNil() {
        let trimmer = SilenceTrimmer(threshold: 0.01)
        XCTAssertNil(trimmer.audibleRange(of: [0, 0.001, -0.001, 0]))
    }

    func testFindsMidTrackSilentStretches() {
        let trimmer = SilenceTrimmer(threshold: 0.01)
        let samples: [Float] = [0.5, 0, 0, 0, 0.5, 0, 0.5, 0, 0, 0]
        let stretches = trimmer.silentStretches(in: samples, minimumFrames: 3)
        XCTAssertEqual(stretches, [1..<4, 7..<10])
    }
}

final class GaplessPlanTests: XCTestCase {
    func testHandoffFrameAccountsForOverlap() {
        let plan = GaplessPlan(trackID: "t", sampleRate: 44_100, startFrame: 0, endFrame: 441_000, fadeOutOverlap: 2)
        XCTAssertEqual(plan.handoffFrame, 441_000 - 88_200)
        XCTAssertEqual(plan.playableDuration, 10, accuracy: 1e-9)
    }

    func testButtJoinHandsOffAtEnd() {
        let plan = GaplessPlan(trackID: "t", sampleRate: 48_000, startFrame: 100, endFrame: 48_100)
        XCTAssertEqual(plan.handoffFrame, 48_100)
    }
}
