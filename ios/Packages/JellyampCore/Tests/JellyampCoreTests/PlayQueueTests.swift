import XCTest
@testable import JellyampCore

private func track(_ id: Int, album: String? = "album", index: Int? = nil) -> Track {
    Track(
        id: "t\(id)",
        title: "Track \(id)",
        artistName: "Artist",
        albumID: album,
        indexNumber: index ?? id,
        duration: 180
    )
}

final class PlayQueueTests: XCTestCase {
    func testAdvanceStopsAtEndWithRepeatOff() {
        var queue = PlayQueue(tracks: [track(1), track(2)])
        XCTAssertEqual(queue.currentTrack?.id, "t1")
        XCTAssertEqual(queue.advance()?.id, "t2")
        XCTAssertNil(queue.advance())
        XCTAssertNil(queue.currentTrack)
    }

    func testRepeatAllWrapsAround() {
        var queue = PlayQueue(tracks: [track(1), track(2)], repeatMode: .all)
        queue.advance()
        XCTAssertEqual(queue.advance()?.id, "t1")
    }

    func testRepeatOnePinsAutoAdvanceButNotManualSkip() {
        var queue = PlayQueue(tracks: [track(1), track(2)], repeatMode: .one)
        XCTAssertEqual(queue.advance()?.id, "t1")
        XCTAssertEqual(queue.skipToNext()?.id, "t2")
    }

    func testInsertNextPlacesAfterCurrent() {
        var queue = PlayQueue(tracks: [track(1), track(2)])
        queue.insertNext([track(9)])
        XCTAssertEqual(queue.tracks.map(\.id), ["t1", "t9", "t2"])
        XCTAssertEqual(queue.upNext.map(\.id), ["t9", "t2"])
    }

    func testRemoveBeforeCurrentAdjustsIndex() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(3)], startAt: 1)
        queue.remove(at: 0)
        XCTAssertEqual(queue.currentTrack?.id, "t2")
        XCTAssertEqual(queue.tracks.count, 2)
    }

    func testRemoveCurrentIsIgnored() {
        var queue = PlayQueue(tracks: [track(1), track(2)])
        queue.remove(at: 0)
        XCTAssertEqual(queue.tracks.count, 2)
    }

    func testMoveKeepsCurrentTrackCurrent() {
        var queue = PlayQueue(tracks: [track(1), track(2), track(3)], startAt: 1)
        queue.move(from: 2, to: 0)
        XCTAssertEqual(queue.currentTrack?.id, "t2")
        XCTAssertEqual(queue.tracks.map(\.id), ["t3", "t1", "t2"])
    }

    func testShuffleKeepsCurrentFirstAndIsSeedStable() {
        var first = PlayQueue(tracks: (1...10).map { track($0) }, startAt: 4)
        var second = first
        first.shuffle(seed: 42)
        second.shuffle(seed: 42)
        XCTAssertEqual(first.currentTrack?.id, "t5")
        XCTAssertEqual(first.currentIndex, 0)
        XCTAssertEqual(first.tracks, second.tracks)
        XCTAssertEqual(Set(first.tracks.map(\.id)).count, 10)
    }

    func testUnshuffleRestoresOrderAndCurrent() {
        var queue = PlayQueue(tracks: (1...10).map { track($0) }, startAt: 2)
        let original = queue.tracks
        queue.shuffle(seed: 7)
        queue.advance()
        let current = queue.currentTrack
        queue.unshuffle()
        XCTAssertEqual(queue.tracks, original)
        XCTAssertEqual(queue.currentTrack, current)
        XCTAssertFalse(queue.isShuffled)
    }

    func testSkipToPreviousAtStartWithRepeatAllWraps() {
        var queue = PlayQueue(tracks: [track(1), track(2)], repeatMode: .all)
        XCTAssertEqual(queue.skipToPrevious()?.id, "t2")
    }
}

final class RadioQueueFeederTests: XCTestCase {
    func testNeedsRefillBelowThreshold() {
        let feeder = RadioQueueFeeder(refillThreshold: 5, batchSize: 10, dedupeWindow: 3)
        XCTAssertTrue(feeder.needsRefill(remaining: 4))
        XCTAssertFalse(feeder.needsRefill(remaining: 5))
    }

    func testSelectTracksDedupesAgainstQueueAndRecentHistory() {
        let feeder = RadioQueueFeeder(refillThreshold: 5, batchSize: 10, dedupeWindow: 2)
        let candidates = (1...6).map { track($0) }
        // t1 is queued; history is [t2, t3, t4] but window 2 only blocks t3, t4.
        let picked = feeder.selectTracks(
            from: candidates,
            queuedIDs: ["t1"],
            historyIDs: ["t2", "t3", "t4"]
        )
        XCTAssertEqual(picked.map(\.id), ["t2", "t5", "t6"])
    }

    func testSelectTracksHonorsBatchSize() {
        let feeder = RadioQueueFeeder(refillThreshold: 5, batchSize: 2, dedupeWindow: 10)
        let picked = feeder.selectTracks(from: (1...5).map { track($0) }, queuedIDs: [], historyIDs: [])
        XCTAssertEqual(picked.count, 2)
    }
}
