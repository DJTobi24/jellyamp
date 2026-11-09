import XCTest
@testable import JellyampCore

private func track(_ id: Int, album: String? = "album", gain: Double? = nil) -> Track {
    Track(id: "t\(id)", title: "Track \(id)", artistName: "Artist", albumID: album, indexNumber: id, duration: 180, normalizationGainDB: gain)
}

final class QueueSheetTests: XCTestCase {
    func testHistoryIsEverythingBeforeTheCurrentTrack() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(3)])
        XCTAssertEqual(queue.history, [])
        queue.advance()
        queue.advance()
        XCTAssertEqual(queue.history.map(\.id), ["t1", "t2"])
        XCTAssertEqual(queue.upNext, [])
    }

    func testClearUpNextKeepsHistoryAndCurrent() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(3), track(4)], startAt: 1)
        queue.clearUpNext()
        XCTAssertEqual(queue.tracks.map(\.id), ["t1", "t2"])
        XCTAssertEqual(queue.currentTrack?.id, "t2")
        XCTAssertNil(queue.nextTrack)
    }

    func testClearUpNextWhileShuffledKeepsUnshuffleConsistent() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(3), track(4)], startAt: 2)
        queue.shuffle(seed: 7)
        queue.clearUpNext()
        XCTAssertEqual(queue.tracks.map(\.id), ["t3"])
        queue.unshuffle()
        XCTAssertEqual(queue.tracks.map(\.id), ["t3"])
        XCTAssertEqual(queue.currentTrack?.id, "t3")
    }

    func testAppendingToAnExhaustedQueueStartsAtTheNewTrack() {
        var queue = PlayQueue(tracks: [track(1), track(2)])
        queue.advance()
        XCTAssertNil(queue.advance())
        queue.append([track(3), track(4)])
        XCTAssertEqual(queue.currentTrack?.id, "t3")
        XCTAssertEqual(queue.upNext.map(\.id), ["t4"])
    }

    func testAppendingToAnEmptyQueueStartsAtTheFirstTrack() {
        var queue = PlayQueue()
        queue.append([track(1), track(2)])
        XCTAssertEqual(queue.currentTrack?.id, "t1")
    }

    func testRemovingOneDuplicateKeepsTheOtherWhenUnshuffling() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(2), track(3)])
        queue.shuffle(seed: 3)
        let duplicate = queue.tracks.lastIndex { $0.id == "t2" }!
        queue.remove(at: duplicate)
        queue.unshuffle()
        XCTAssertEqual(queue.tracks.map(\.id), ["t1", "t2", "t3"])
    }

    func testUpdateTracksReachesEveryCopyIncludingTheUnshuffledOrder() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(1)])
        queue.shuffle(seed: 1)
        queue.updateTracks(id: "t1") { $0.isFavorite = true }
        XCTAssertEqual(queue.tracks.filter(\.isFavorite).count, 2)
        queue.unshuffle()
        XCTAssertEqual(queue.tracks.map(\.isFavorite), [true, false, true])
    }

    func testAbsoluteIndexForUpNextRejectsOutOfRangeOffsets() {
        let queue = PlayQueue(tracks: [track(1), track(2), track(3)], startAt: 1)
        XCTAssertEqual(queue.absoluteIndex(forUpNext: 0), 2)
        XCTAssertNil(queue.absoluteIndex(forUpNext: 1))
        XCTAssertNil(queue.absoluteIndex(forUpNext: -1))
    }

    func testHasPrevious() {
        var queue = PlayQueue(tracks: [track(1), track(2)])
        XCTAssertFalse(queue.hasPrevious)
        queue.setRepeatMode(.all)
        XCTAssertTrue(queue.hasPrevious)
        queue.setRepeatMode(.off)
        queue.advance()
        XCTAssertTrue(queue.hasPrevious)
        var single = PlayQueue(tracks: [track(1)], repeatMode: .all)
        XCTAssertFalse(single.hasPrevious)
        single.setRepeatMode(.one)
        XCTAssertFalse(single.hasPrevious)
    }
}

final class TransportPolicyTests: XCTestCase {
    func testPreviousRestartsAfterThreshold() {
        let policy = TransportPolicy()
        XCTAssertEqual(policy.previousAction(position: 1, hasPrevious: true), .previousTrack)
        XCTAssertEqual(policy.previousAction(position: 3.5, hasPrevious: true), .restartCurrent)
        XCTAssertEqual(policy.previousAction(position: 0.5, hasPrevious: false), .restartCurrent)
    }

    func testSeekTargetIsClampedIntoTheTrack() {
        let policy = TransportPolicy()
        XCTAssertEqual(policy.clampedSeekTarget(-4, duration: 100), 0)
        XCTAssertEqual(policy.clampedSeekTarget(250, duration: 100), 99.5)
        XCTAssertEqual(policy.clampedSeekTarget(42, duration: 100), 42)
        XCTAssertEqual(policy.clampedSeekTarget(.nan, duration: 100), 0)
        // Unknown duration: only the lower bound applies.
        XCTAssertEqual(policy.clampedSeekTarget(42, duration: 0), 42)
    }

    func testFailurePolicySkipsThenGivesUp() {
        var policy = TrackFailurePolicy(maxConsecutiveFailures: 3)
        XCTAssertEqual(policy.recordFailure(), .skipToNext)
        XCTAssertEqual(policy.recordFailure(), .skipToNext)
        XCTAssertEqual(policy.recordFailure(), .giveUp)
        // After giving up the count starts over.
        XCTAssertEqual(policy.recordFailure(), .skipToNext)
        policy.recordSuccess()
        XCTAssertEqual(policy.consecutiveFailures, 0)
    }

    func testNetworkClassification() {
        XCTAssertEqual(NetworkType.classify(isSatisfied: false, usesCellular: true, isExpensive: true), .offline)
        XCTAssertEqual(NetworkType.classify(isSatisfied: true, usesCellular: false, isExpensive: false), .wifi)
        XCTAssertEqual(NetworkType.classify(isSatisfied: true, usesCellular: true, isExpensive: true), .cellular)
        // Personal hotspot: Wi-Fi interface, but metered.
        XCTAssertEqual(NetworkType.classify(isSatisfied: true, usesCellular: false, isExpensive: true), .cellular)
    }

    func testSleepTimerEndOfTrackFlag() {
        var timer = SleepTimer()
        XCTAssertFalse(timer.stopsAtEndOfTrack)
        timer.startEndOfTrack()
        XCTAssertTrue(timer.stopsAtEndOfTrack)
        timer.start(duration: 60, now: 0)
        XCTAssertFalse(timer.stopsAtEndOfTrack)
    }

    func testPlaySessionLedgerKeepsOneIDPerPlayThrough() {
        var ledger = PlaySessionLedger()
        var counter = 0
        let make: () -> String = { counter += 1; return "s\(counter)" }
        XCTAssertEqual(ledger.sessionID(for: .started(trackID: "a", positionTicks: 0), makeID: make), "s1")
        XCTAssertEqual(ledger.sessionID(for: .progress(trackID: "a", positionTicks: 5, isPaused: false), makeID: make), "s1")
        XCTAssertEqual(ledger.sessionID(for: .stopped(trackID: "a", positionTicks: 9), makeID: make), "s1")
        // Repeat-one: the same track started again is a new session.
        XCTAssertEqual(ledger.sessionID(for: .started(trackID: "a", positionTicks: 0), makeID: make), "s2")
        // A stop nobody started still gets an ID rather than crashing.
        XCTAssertEqual(ledger.sessionID(for: .stopped(trackID: "zz", positionTicks: 0), makeID: make), "s3")
    }

    func testReporterSequenceForStartSeekPauseAndStop() {
        var reporter = PlaybackReporter(progressInterval: 10)
        XCTAssertEqual(reporter.trackStarted(id: "a", at: 0), [.started(trackID: "a", positionTicks: 0)])
        XCTAssertEqual(reporter.playbackTick(position: 1, isPaused: false, now: 100).count, 1)
        XCTAssertEqual(reporter.playbackTick(position: 5, isPaused: false, now: 104), [])
        // A seek is a progress report for the same session, never a new start.
        XCTAssertEqual(
            reporter.stateChanged(position: 60, isPaused: false, now: 105),
            [.progress(trackID: "a", positionTicks: 600_000_000, isPaused: false)]
        )
        XCTAssertEqual(
            reporter.stateChanged(position: 61, isPaused: true, now: 106),
            [.progress(trackID: "a", positionTicks: 610_000_000, isPaused: true)]
        )
        XCTAssertEqual(
            reporter.trackStarted(id: "b", at: 0, previousPosition: 180),
            [.stopped(trackID: "a", positionTicks: 1_800_000_000), .started(trackID: "b", positionTicks: 0)]
        )
        XCTAssertEqual(reporter.stopped(at: 12), [.stopped(trackID: "b", positionTicks: 120_000_000)])
        XCTAssertEqual(reporter.stopped(at: 12), [])
    }
}

final class LoudnessLevelerTests: XCTestCase {
    private let leveler = LoudnessLeveler()

    func testTagWinsOverMeasurement() {
        let gain = leveler.trackGain(for: track(1, gain: -6), measured: MeasuredLoudness(integratedLufs: -9, truePeakDB: -1))
        XCTAssertEqual(gain, LevelingGain(gainDB: -6, truePeakDB: -1, source: .trackTag))
    }

    func testMeasuredLufsBecomesGainTowardsReference() {
        let gain = leveler.trackGain(for: track(1), measured: MeasuredLoudness(integratedLufs: -9.4, truePeakDB: -0.3))
        XCTAssertEqual(gain?.source, .measured)
        XCTAssertEqual(gain?.gainDB ?? 0, -8.6, accuracy: 0.0001)
        XCTAssertNil(leveler.trackGain(for: track(1), measured: nil))
    }

    func testAlbumRunCoversContiguousSameAlbumTracksOnly() {
        let tracks = [track(1, album: "x"), track(2, album: "a"), track(3, album: "a"), track(4, album: "a"), track(5, album: "y"), track(6, album: "a")]
        XCTAssertEqual(leveler.albumRun(in: tracks, around: 2), 1..<4)
        XCTAssertEqual(leveler.albumRun(in: tracks, around: 0), 0..<1)
        XCTAssertEqual(leveler.albumRun(in: tracks, around: 5), 5..<6)
        XCTAssertEqual(leveler.albumRun(in: [track(1, album: nil), track(2, album: nil)], around: 0), 0..<1)
    }

    func testConsecutiveAlbumTracksShareTheLowestTrackGain() {
        let tracks = [track(1, album: "a", gain: -4), track(2, album: "a", gain: -9), track(3, album: "a", gain: -6)]
        for index in tracks.indices {
            let gain = leveler.gain(at: index, in: tracks, measured: { _ in nil }, albumGainDB: { _ in nil })
            XCTAssertEqual(gain, LevelingGain(gainDB: -9, truePeakDB: nil, source: .album))
        }
    }

    func testKnownAlbumGainIsPreferred() {
        let tracks = [track(1, album: "a", gain: -4), track(2, album: "a", gain: -9)]
        let gain = leveler.gain(at: 0, in: tracks, measured: { _ in nil }, albumGainDB: { $0 == "a" ? -7.5 : nil })
        XCTAssertEqual(gain, LevelingGain(gainDB: -7.5, truePeakDB: nil, source: .album))
    }

    func testShuffledNeighboursUseTrackGain() {
        let tracks = [track(1, album: "a", gain: -4), track(2, album: "b", gain: -9), track(3, album: "a", gain: -6)]
        let gain = leveler.gain(at: 0, in: tracks, measured: { _ in nil }, albumGainDB: { _ in -1 })
        XCTAssertEqual(gain, LevelingGain(gainDB: -4, truePeakDB: nil, source: .trackTag))
    }

    func testAlbumRunMixesTagsAndMeasurementsAndSharesAPeakOnlyWhenAllAreKnown() {
        let tracks = [track(1, album: "a", gain: -4), track(2, album: "a")]
        let measured: (String) -> MeasuredLoudness? = { id in
            id == "t2" ? MeasuredLoudness(integratedLufs: -8, truePeakDB: -0.5) : nil
        }
        let partial = leveler.gain(at: 0, in: tracks, measured: measured, albumGainDB: { _ in nil })
        XCTAssertEqual(partial, LevelingGain(gainDB: -10, truePeakDB: nil, source: .album))
        let both: (String) -> MeasuredLoudness? = { id in
            MeasuredLoudness(integratedLufs: id == "t2" ? -8 : -14, truePeakDB: id == "t2" ? -0.5 : -3)
        }
        let full = leveler.gain(at: 1, in: tracks, measured: both, albumGainDB: { _ in nil })
        XCTAssertEqual(full?.truePeakDB, -0.5)
    }

    func testAlbumRunWithNoLoudnessDataHasNoGain() {
        let tracks = [track(1, album: "a"), track(2, album: "a")]
        XCTAssertNil(leveler.gain(at: 0, in: tracks, measured: { _ in nil }, albumGainDB: { _ in nil }))
        XCTAssertNil(leveler.gain(at: 9, in: tracks, measured: { _ in nil }, albumGainDB: { _ in nil }))
    }

    func testAttenuationGoesToNodeVolume() {
        let stage = leveler.stage(for: LevelingGain(gainDB: -6, source: .trackTag), preampDB: 0)
        XCTAssertEqual(stage.volume, 0.5012, accuracy: 0.001)
        XCTAssertEqual(stage.boostDB, 0)
    }

    func testBoostNeedsKnownHeadroom() {
        // Quiet track, peak unknown: no blind boost.
        XCTAssertEqual(leveler.stage(for: LevelingGain(gainDB: 5, source: .trackTag), preampDB: 0), .unity)
        // Peak at −3 dBTP: at most 3 dB of the requested 5.
        let limited = leveler.stage(for: LevelingGain(gainDB: 5, truePeakDB: -3, source: .measured), preampDB: 0)
        XCTAssertEqual(limited, GainStage(volume: 1, boostDB: 3))
        // Plenty of headroom: full request, capped by maxBoostDB.
        let capped = LoudnessLeveler(maxBoostDB: 6).stage(for: LevelingGain(gainDB: 9, truePeakDB: -20, source: .measured), preampDB: 0)
        XCTAssertEqual(capped.boostDB, 6)
        // Peak already over full scale: nothing.
        XCTAssertEqual(leveler.stage(for: LevelingGain(gainDB: 2, truePeakDB: 0.4, source: .measured), preampDB: 0).boostDB, 0)
    }

    func testPreampAddsToGainAndAppliesWithoutLeveling() {
        let stage = leveler.stage(for: LevelingGain(gainDB: -6, source: .trackTag), preampDB: 3)
        XCTAssertEqual(stage.volume, LoudnessMath.linearGain(fromDB: -3), accuracy: 0.0001)
        XCTAssertEqual(leveler.stage(for: nil, preampDB: -4).volume, LoudnessMath.linearGain(fromDB: -4), accuracy: 0.0001)
        XCTAssertEqual(leveler.stage(for: nil, preampDB: 4), .unity)
    }

    func testCachePersistsAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loudness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/loudness.json")
        let cache = LoudnessCache(fileURL: file)
        XCTAssertNil(cache.value(for: "a"))
        cache.store(MeasuredLoudness(integratedLufs: -9.4, truePeakDB: -0.3), for: "a")
        cache.store(["b": MeasuredLoudness(integratedLufs: -14)])
        let reopened = LoudnessCache(fileURL: file)
        XCTAssertEqual(reopened.value(for: "a"), MeasuredLoudness(integratedLufs: -9.4, truePeakDB: -0.3))
        XCTAssertEqual(reopened.value(for: "b")?.truePeakDB, nil)
        XCTAssertEqual(reopened.count, 2)
        reopened.removeAll()
        XCTAssertEqual(LoudnessCache(fileURL: file).count, 0)
    }

    func testCacheIsBoundedAndSurvivesACorruptFile() throws {
        let cache = LoudnessCache(fileURL: nil, maxEntries: 3)
        for index in 0..<10 {
            cache.store(MeasuredLoudness(integratedLufs: Double(-index)), for: "t\(index)")
        }
        XCTAssertLessThanOrEqual(cache.count, 3)
        XCTAssertNotNil(cache.value(for: "t9"))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(LoudnessCache(fileURL: file).count, 0)
    }
}

final class SilenceGateTests: XCTestCase {
    private let buffer = 0.2

    func testAudibleBuffersAlwaysPass() {
        var gate = SilenceGate()
        for _ in 0..<100 {
            XCTAssertTrue(gate.shouldSchedule(peak: 0.3, duration: buffer))
        }
        XCTAssertEqual(gate.skippedDuration, 0)
    }

    func testLeadingSilenceIsTrimmedToTheAllowance() {
        var gate = SilenceGate(maxLeadingSilence: 0.5, maxSilence: 2)
        let decisions = (0..<10).map { _ in gate.shouldSchedule(peak: 0, duration: buffer) }
        XCTAssertEqual(decisions.filter { $0 }.count, 2)   // 0.4 s kept, the rest dropped
        XCTAssertEqual(gate.skippedDuration, 1.6, accuracy: 0.0001)
        XCTAssertTrue(gate.shouldSchedule(peak: 0.5, duration: buffer))
    }

    func testShortPausesInsideATrackAreKept() {
        var gate = SilenceGate()
        XCTAssertTrue(gate.shouldSchedule(peak: 0.5, duration: buffer))
        for _ in 0..<9 {   // 1.8 s pause
            XCTAssertTrue(gate.shouldSchedule(peak: 0.0001, duration: buffer))
        }
        XCTAssertTrue(gate.shouldSchedule(peak: 0.5, duration: buffer))
        XCTAssertEqual(gate.skippedDuration, 0)
    }

    func testLongSilenceIsCompressedToTheAllowanceAndTheRunResets() {
        var gate = SilenceGate(maxLeadingSilence: 0.5, maxSilence: 2)
        _ = gate.shouldSchedule(peak: 0.5, duration: buffer)
        let first = (0..<50).map { _ in gate.shouldSchedule(peak: 0, duration: buffer) }   // 10 s
        XCTAssertEqual(first.filter { $0 }.count, 10)
        XCTAssertEqual(gate.skippedDuration, 8, accuracy: 0.0001)
        XCTAssertTrue(gate.shouldSchedule(peak: 0.5, duration: buffer))
        // A second long silence gets its own allowance.
        let second = (0..<20).map { _ in gate.shouldSchedule(peak: 0, duration: buffer) }
        XCTAssertEqual(second.filter { $0 }.count, 10)
        XCTAssertEqual(gate.skippedDuration, 10, accuracy: 0.0001)
    }
}

final class SpectrumTests: XCTestCase {
    func testBandsAreContiguousNonEmptyAndInRange() {
        let bands = SpectrumBands(bandCount: 32, binCount: 1024, sampleRate: 44_100)
        XCTAssertEqual(bands.bandCount, 32)
        var previousEnd = 1
        for range in bands.binRanges {
            XCTAssertFalse(range.isEmpty)
            XCTAssertGreaterThanOrEqual(range.lowerBound, previousEnd)
            XCTAssertLessThanOrEqual(range.upperBound, 1024)
            previousEnd = range.upperBound
        }
        XCTAssertEqual(bands.centerFrequencies, bands.centerFrequencies.sorted())
    }

    func testDegenerateLayoutsDoNotCrash() {
        XCTAssertEqual(SpectrumBands(bandCount: 0, binCount: 1024, sampleRate: 44_100).bandCount, 0)
        XCTAssertEqual(SpectrumBands(bandCount: 8, binCount: 0, sampleRate: 44_100).bandCount, 0)
        XCTAssertEqual(SpectrumBands(bandCount: 8, binCount: 512, sampleRate: 0).bandCount, 0)
        // More bands than bins: still one valid bin each.
        let crowded = SpectrumBands(bandCount: 64, binCount: 16, sampleRate: 8_000)
        XCTAssertEqual(crowded.bandCount, 64)
        XCTAssertTrue(crowded.binRanges.allSatisfy { !$0.isEmpty && $0.upperBound <= 16 })
        XCTAssertEqual(crowded.levels(fromPower: [Float](repeating: 1, count: 16)).count, 64)
    }

    func testASineLightsUpItsBandOnly() {
        let bands = SpectrumBands(bandCount: 16, binCount: 1024, sampleRate: 44_100, tiltDBPerOctave: 0)
        var power = [Float](repeating: 0, count: 1024)
        let bin = Int(1000 / (22_050.0 / 1024))   // 1 kHz
        power[bin] = 1   // full scale
        let levels = bands.levels(fromPower: power)
        let lit = levels.indices.filter { levels[$0] > 0 }
        XCTAssertEqual(lit.count, 1)
        XCTAssertTrue(bands.binRanges[lit[0]].contains(bin))
        XCTAssertEqual(levels[lit[0]], 1)
    }

    func testLevelsAreScaledBetweenFloorAndCeiling() {
        let bands = SpectrumBands(bandCount: 1, binCount: 8, sampleRate: 16_000, minFrequency: 1000, maxFrequency: 8000,
                                  floorDB: -60, ceilingDB: 0, tiltDBPerOctave: 0)
        func level(_ power: Float) -> Float { bands.levels(fromPower: [Float](repeating: power, count: 8))[0] }
        XCTAssertEqual(level(1), 1)
        XCTAssertEqual(level(0.001), 0.5, accuracy: 0.001)   // −30 dB
        XCTAssertEqual(level(1e-9), 0)
        XCTAssertEqual(level(0), 0)
        XCTAssertEqual(level(100), 1)
        // A short power array is tolerated.
        XCTAssertEqual(bands.levels(fromPower: []), [0])
    }

    func testTiltLiftsTrebleAndLowersBass() {
        let flat = SpectrumBands(bandCount: 8, binCount: 1024, sampleRate: 44_100, tiltDBPerOctave: 0)
        let tilted = SpectrumBands(bandCount: 8, binCount: 1024, sampleRate: 44_100, tiltDBPerOctave: 3)
        let power = [Float](repeating: 0.001, count: 1024)
        let a = flat.levels(fromPower: power)
        let b = tilted.levels(fromPower: power)
        XCTAssertLessThan(b[0], a[0])
        XCTAssertGreaterThan(b[7], a[7])
    }

    func testSmootherRisesFastAndFallsAtTheDecayRate() {
        var smoother = SpectrumSmoother(attackTime: 0.03, decayPerSecond: 2, peakHoldTime: 0.5, peakFallPerSecond: 1)
        smoother.update(target: [1], dt: 1.0 / 30)
        XCTAssertGreaterThan(smoother.levels[0], 0.6)
        for _ in 0..<5 { smoother.update(target: [1], dt: 1.0 / 30) }
        XCTAssertEqual(smoother.levels[0], 1, accuracy: 0.01)
        let top = smoother.levels[0]
        smoother.update(target: [0], dt: 0.1)
        XCTAssertEqual(smoother.levels[0], top - 0.2, accuracy: 0.001)
        // Never undershoots the target.
        smoother.update(target: [0.7], dt: 0.2)
        XCTAssertEqual(smoother.levels[0], 0.7, accuracy: 0.001)
    }

    func testPeaksHoldThenFall() {
        var smoother = SpectrumSmoother(attackTime: 0, decayPerSecond: 10, peakHoldTime: 0.5, peakFallPerSecond: 1)
        smoother.update(target: [0.8], dt: 0.05)
        XCTAssertEqual(smoother.peaks[0], 0.8, accuracy: 0.0001)
        smoother.update(target: [0], dt: 0.2)
        smoother.update(target: [0], dt: 0.2)
        XCTAssertEqual(smoother.levels[0], 0)
        XCTAssertEqual(smoother.peaks[0], 0.8, accuracy: 0.0001)   // still held
        smoother.update(target: [0], dt: 0.2)   // past the hold → falls 0.2
        XCTAssertEqual(smoother.peaks[0], 0.6, accuracy: 0.0001)
        // A new louder level takes the cap with it.
        smoother.update(target: [0.9], dt: 0.05)
        XCTAssertEqual(smoother.peaks[0], 0.9, accuracy: 0.0001)
        XCTAssertFalse(smoother.isAtRest)
    }

    func testSmootherSettlesAdaptsToBandCountAndClampsInput() {
        var smoother = SpectrumSmoother()
        XCTAssertTrue(smoother.isAtRest)
        smoother.update(target: [3, -1], dt: 0.05)
        XCTAssertLessThanOrEqual(smoother.levels[0], 1)
        XCTAssertEqual(smoother.levels[1], 0)
        smoother.update(target: [0.5, 0.5, 0.5], dt: 0.05)
        XCTAssertEqual(smoother.levels.count, 3)
        for _ in 0..<200 { smoother.update(target: [0, 0, 0], dt: 0.05) }
        XCTAssertTrue(smoother.isAtRest)
        // A long stall is treated as a bounded step, and a negative dt as zero.
        smoother.update(target: [1, 1, 1], dt: 0.05)
        let before = smoother.levels
        smoother.update(target: [0, 0, 0], dt: -5)
        XCTAssertEqual(smoother.levels, before)
        smoother.reset()
        XCTAssertEqual(smoother.levels, [])
    }

    func testWaveformReductionKeepsExtremesAndSign() {
        let samples: [Float] = [0, 0.2, -0.9, 0.1, 0.4, 0.3, 0, -0.1]
        XCTAssertEqual(WaveformReducer.reduce(samples, points: 4), [0.2, -0.9, 0.4, -0.1])
        XCTAssertEqual(WaveformReducer.reduce([], points: 3), [0, 0, 0])
        XCTAssertEqual(WaveformReducer.reduce(samples, points: 0), [])
        XCTAssertEqual(WaveformReducer.reduce([2, -3], points: 2), [1, -1])
        // More points than samples: every point still reads a valid sample.
        XCTAssertEqual(WaveformReducer.reduce([0.5], points: 3), [0.5, 0.5, 0.5])
    }
}

final class DominantColorTests: XCTestCase {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8, Int)]) -> [UInt8] {
        colors.flatMap { r, g, b, count in (0..<count).flatMap { _ in [r, g, b, 255] } }
    }

    func testPicksTheSaturatedColourOverALargerDullArea() {
        let rgba = pixels([(20, 20, 20, 600), (230, 230, 230, 200), (220, 30, 40, 150)])
        let color = DominantColor.dominant(rgba: rgba)!
        XCTAssertGreaterThan(color.red, 0.8)
        XCTAssertLessThan(color.green, 0.2)
    }

    func testMostCommonHueWins() {
        let rgba = pixels([(30, 60, 220, 300), (220, 200, 30, 80)])
        let color = DominantColor.dominant(rgba: rgba)!
        XCTAssertGreaterThan(color.blue, color.red)
    }

    func testMonochromeArtFallsBackToItsAverage() {
        let color = DominantColor.dominant(rgba: pixels([(100, 100, 100, 10), (200, 200, 200, 10)]))!
        XCTAssertEqual(color.red, 150.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.red, color.blue, accuracy: 0.0001)
    }

    func testEmptyAndTransparentImagesHaveNoColour() {
        XCTAssertNil(DominantColor.dominant(rgba: []))
        XCTAssertNil(DominantColor.dominant(rgba: [255, 0, 0, 0, 0, 255, 0, 10]))
        XCTAssertNil(DominantColor.dominant(rgba: [1, 2, 3]))   // truncated pixel
    }

    func testHSBRoundTrip() {
        for color in [RGBColor(red: 0.9, green: 0.2, blue: 0.1), RGBColor(red: 0.1, green: 0.5, blue: 0.9),
                      RGBColor(red: 0.3, green: 0.8, blue: 0.4), RGBColor(red: 0.5, green: 0.5, blue: 0.5)] {
            let (h, s, b) = color.hsb
            let back = RGBColor(hue: h, saturation: s, brightness: b)
            XCTAssertEqual(back.red, color.red, accuracy: 0.0001)
            XCTAssertEqual(back.green, color.green, accuracy: 0.0001)
            XCTAssertEqual(back.blue, color.blue, accuracy: 0.0001)
        }
    }

    func testVividLiftsDarkColoursButKeepsGreysGrey() {
        let navy = DominantColor.vivid(RGBColor(red: 0.05, green: 0.05, blue: 0.3))
        XCTAssertGreaterThanOrEqual(navy.hsb.brightness, 0.8 - 0.0001)
        XCTAssertGreaterThan(navy.blue, navy.red)
        let grey = DominantColor.vivid(RGBColor(red: 0.2, green: 0.2, blue: 0.2))
        XCTAssertEqual(grey.red, grey.green, accuracy: 0.0001)
        XCTAssertEqual(grey.red, 0.8, accuracy: 0.0001)
    }
}

final class AudioQualityTests: XCTestCase {
    private func track(codec: String?, depth: Int? = nil, rate: Int? = nil, bitrate: Int? = nil) -> Track {
        Track(id: "t", title: "t", artistName: "a", duration: 100, codec: codec, bitrate: bitrate, sampleRate: rate, bitDepth: depth)
    }

    func testContainerNormalisation() {
        XCTAssertEqual(AudioContainer.canonical("mov,mp4,m4a,3gp,3g2,mj2"), "m4a")
        XCTAssertEqual(AudioContainer.canonical("FLAC"), "flac")
        XCTAssertEqual(AudioContainer.canonical("mp3"), "mp3")
        XCTAssertEqual(AudioContainer.canonical("ogg, oga"), "ogg")
        XCTAssertNil(AudioContainer.canonical(nil))
        XCTAssertNil(AudioContainer.canonical(""))
    }

    func testHiResFlacDirect() {
        let info = AudioQualityInfo(track: track(codec: "flac", depth: 24, rate: 96_000, bitrate: 2_304_000), request: .directPlay, isDownloaded: false)
        XCTAssertEqual(info.delivery, .direct)
        XCTAssertTrue(info.isLossless)
        XCTAssertTrue(info.isHiRes)
        XCTAssertEqual(info.summary, "FLAC · 24-bit / 96 kHz · 2304 kbps")
    }

    func testCDQualityIsLosslessButNotHiRes() {
        let info = AudioQualityInfo(track: track(codec: "flac", depth: 16, rate: 44_100, bitrate: 900_000), request: .directPlay, isDownloaded: false)
        XCTAssertTrue(info.isLossless)
        XCTAssertFalse(info.isHiRes)
        XCTAssertEqual(info.resolutionLabel, "16-bit / 44.1 kHz")
    }

    func testLossyShowsSampleRateOnly() {
        let info = AudioQualityInfo(track: track(codec: "mp3", depth: 16, rate: 44_100, bitrate: 192_215), request: .directPlay, isDownloaded: false)
        XCTAssertFalse(info.isLossless)
        XCTAssertEqual(info.summary, "MP3 · 44.1 kHz · 192 kbps")
    }

    func testTranscodeReportsWhatIsStreamedNotTheSource() {
        let request = StreamRequest.transcode(codec: "aac", container: "ts", maxBitrate: 320_000)
        let info = AudioQualityInfo(track: track(codec: "flac", depth: 24, rate: 96_000, bitrate: 2_304_000), request: request, isDownloaded: false)
        XCTAssertEqual(info.delivery, .transcoded)
        XCTAssertFalse(info.isLossless)
        XCTAssertEqual(info.summary, "MP3 · 44.1 kHz · 320 kbps")
    }

    func testDownloadWinsOverTheStreamDecision() {
        let request = StreamRequest.transcode(codec: "aac", container: "ts", maxBitrate: 128_000)
        let info = AudioQualityInfo(track: track(codec: "vorbis", rate: 48_000, bitrate: 160_000), request: request, isDownloaded: true)
        XCTAssertEqual(info.delivery, .downloaded)
        XCTAssertEqual(info.summary, "Vorbis · 48 kHz · 160 kbps")
    }

    func testUnknownMetadataDegradesGracefully() {
        let info = AudioQualityInfo(track: track(codec: nil), request: .directPlay, isDownloaded: false)
        XCTAssertEqual(info.summary, "Audio")
        XCTAssertNil(info.resolutionLabel)
        XCTAssertNil(info.bitrateLabel)
        XCTAssertEqual(AudioQualityInfo(codec: "pcm_s16le", bitDepth: 16, sampleRate: 48_000, bitrate: 0, delivery: .direct).summary, "PCM · 16-bit / 48 kHz")
    }
}

final class LyricsBehaviourTests: XCTestCase {
    func testHourTimestampsParse() {
        let lines = LyricsParser.parse(lrc: "[01:02:03.5]late\n[00:01.00]early")
        XCTAssertEqual(lines.map(\.text), ["early", "late"])
        XCTAssertEqual(lines[1].start ?? 0, 3723.5, accuracy: 0.0001)
    }

    func testSeekTimeForLine() {
        let timeline = LyricsTimeline(lines: [LyricLine(start: 1, text: "a"), LyricLine(start: 5, text: "b")])
        XCTAssertEqual(timeline.seekTime(forLine: 1), 5)
        XCTAssertNil(timeline.seekTime(forLine: 2))
        XCTAssertNil(LyricsTimeline(lines: [LyricLine(text: "plain")]).seekTime(forLine: 0))
    }

    func testActiveLineAcrossTheWholeTimeline() {
        let timeline = LyricsTimeline(lines: [LyricLine(start: 2, text: "a"), LyricLine(start: 4, text: "b"), LyricLine(start: 9, text: "c")])
        XCTAssertNil(timeline.activeLineIndex(at: 0))
        XCTAssertEqual(timeline.activeLineIndex(at: 2), 0)
        XCTAssertEqual(timeline.activeLineIndex(at: 8.9), 1)
        XCTAssertEqual(timeline.activeLineIndex(at: 500), 2)
        XCTAssertNil(LyricsTimeline(lines: []).activeLineIndex(at: 3))
    }

    func testAutoScrollPausesAfterManualScrollAndResumes() {
        var scroll = LyricsAutoScroll(resumeDelay: 4)
        XCTAssertTrue(scroll.shouldFollow(now: 0))
        scroll.userScrolled(now: 10)
        XCTAssertFalse(scroll.shouldFollow(now: 12))
        scroll.userScrolled(now: 13)   // still reading
        XCTAssertFalse(scroll.shouldFollow(now: 16))
        XCTAssertTrue(scroll.shouldFollow(now: 17))
        scroll.userScrolled(now: 20)
        scroll.resume()
        XCTAssertTrue(scroll.shouldFollow(now: 20))
    }
}
