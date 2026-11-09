import XCTest
@testable import JellyampCore

private func track(_ id: String, artist: String = "", album: String? = nil, year: Int? = nil) -> Track {
    Track(
        id: id,
        title: "Title \(id)",
        artistName: artist.isEmpty ? "Artist \(id)" : artist,
        artistID: artist.isEmpty ? "artist-\(id)" : "id-\(artist)",
        albumName: album.map { "Album \($0)" },
        albumID: album,
        duration: 180,
        productionYear: year
    )
}

final class DecadeTests: XCTestCase {
    func testDecadeContainingYear() {
        XCTAssertEqual(Decade(containing: 1987).startYear, 1980)
        XCTAssertEqual(Decade(containing: 1990).startYear, 1990)
        XCTAssertEqual(Decade(containing: 2009).yearRange, 2000...2009)
    }

    func testSeedMatchesSonicContractAndFallbackParsing() {
        let decade = Decade(containing: 1994)
        XCTAssertEqual(decade.seed, "1990s")
        // JellyfinFallbackSonicProvider parses the first four characters.
        XCTAssertEqual(Int(decade.seed.prefix(4)), 1990)
        XCTAssertEqual(decade.shortTitle, "90s")
        XCTAssertEqual(Decade(containing: 2003).shortTitle, "00s")
    }

    func testDecadesFromYearsAreDistinctNewestFirst() {
        // The dev library's real year set.
        let years = [1959, 1962, 1978, 1985, 1994, 2003, 2010, 2016, 2021, 2024]
        XCTAssertEqual(
            Decade.decades(fromYears: years).map(\.startYear),
            [2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950]
        )
    }

    func testImplausibleYearsAreIgnored() {
        XCTAssertEqual(Decade.decades(fromYears: [0, 1, 9999, 1999, -5]).map(\.startYear), [1990])
        XCTAssertTrue(Decade.decades(fromYears: []).isEmpty)
    }
}

final class StationCatalogTests: XCTestCase {
    private let genres = [Genre(id: "g1", name: "Jazz"), Genre(id: "g2", name: "Rock")]

    func testEmptyLibraryHasNoStations() {
        let shelves = StationCatalog.shelves(hasTracks: false, genres: genres, years: [1999], recentTracks: [])
        XCTAssertTrue(shelves.stations.isEmpty)
        XCTAssertTrue(shelves.timeTravel.isEmpty)
    }

    func testLibraryRadioComesFirstThenArtistRadiosThenGenres() {
        let recent = [
            track("1", artist: "Slowdive"),
            track("2", artist: "Slowdive"),
            track("3", artist: "Ride"),
            track("4", artist: "Lush"),
        ]
        let shelves = StationCatalog.shelves(hasTracks: true, genres: genres, years: [1991, 1994, 2020], recentTracks: recent)
        XCTAssertEqual(shelves.stations.map(\.title), ["Library Radio", "Slowdive", "Ride", "Jazz", "Rock"])
        XCTAssertEqual(shelves.stations[1].seed, .artist(id: "id-Slowdive"))
        XCTAssertEqual(shelves.stations[3].seed, .genre(name: "Jazz"))
        XCTAssertEqual(shelves.timeTravel.map(\.title), ["2020s", "1990s"])
        XCTAssertEqual(shelves.timeTravel[1].seed, .decade(Decade(containing: 1990)))
    }

    func testRecentTracksWithoutArtistIDAreSkippedForArtistRadio() {
        var anonymous = track("1", artist: "Nobody")
        anonymous.artistID = nil
        let shelves = StationCatalog.shelves(hasTracks: true, genres: [], years: [], recentTracks: [anonymous])
        XCTAssertEqual(shelves.stations, [.libraryRadio])
    }

    func testGenresAreDedupedCaseInsensitivelyAndBlankOnesDropped() {
        let messy = [Genre(id: "1", name: "Rock"), Genre(id: "2", name: "rock "), Genre(id: "3", name: "  ")]
        let shelves = StationCatalog.shelves(hasTracks: true, genres: messy, years: [], recentTracks: [])
        XCTAssertEqual(shelves.stations.map(\.title), ["Library Radio", "Rock"])
    }

    func testStationIDsAreUnique() {
        let shelves = StationCatalog.shelves(
            hasTracks: true,
            genres: genres,
            years: [1980, 1990],
            recentTracks: [track("1", artist: "A"), track("2", artist: "B")]
        )
        let ids = (shelves.stations + shelves.timeTravel).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

final class ArtistSpacerTests: XCTestCase {
    func testSameArtistIsSpreadOut() {
        let tracks = [
            track("a1", artist: "A"), track("a2", artist: "A"), track("a3", artist: "A"),
            track("b1", artist: "B"), track("c1", artist: "C"), track("d1", artist: "D"),
        ]
        let spaced = ArtistSpacer.spaced(tracks, minimumGap: 2)
        XCTAssertEqual(Set(spaced.map(\.id)), Set(tracks.map(\.id)), "spacing never drops tracks")
        for index in 1..<spaced.count where index < 5 {
            XCTAssertNotEqual(spaced[index].artistName, spaced[index - 1].artistName)
        }
        XCTAssertEqual(spaced.first?.id, "a1", "keeps candidate order when no conflict")
    }

    func testRespectsTailOfQueue() {
        let queued = [track("q", artist: "A")]
        let spaced = ArtistSpacer.spaced([track("a1", artist: "A"), track("b1", artist: "B")], after: queued, minimumGap: 2)
        XCTAssertEqual(spaced.map(\.id), ["b1", "a1"])
    }

    func testSingleArtistStationStillReturnsEverything() {
        let tracks = (1...5).map { track("t\($0)", artist: "Solo") }
        XCTAssertEqual(ArtistSpacer.spaced(tracks, minimumGap: 3).map(\.id), tracks.map(\.id))
    }

    func testZeroGapIsIdentity() {
        let tracks = [track("a1", artist: "A"), track("a2", artist: "A")]
        XCTAssertEqual(ArtistSpacer.spaced(tracks, minimumGap: 0), tracks)
    }
}

final class StationSessionTests: XCTestCase {
    private func session(batch: Int = 3, threshold: Int = 2, window: Int = 50, spacing: Int = 0) -> StationSession {
        StationSession(
            station: .libraryRadio,
            feeder: RadioQueueFeeder(refillThreshold: threshold, batchSize: batch, dedupeWindow: window),
            artistSpacing: spacing
        )
    }

    func testInitialBatchIsCappedAndRecorded() {
        var session = session()
        let batch = session.initialBatch(from: (1...10).map { track("t\($0)") })
        XCTAssertEqual(batch.map(\.id), ["t1", "t2", "t3"])
        XCTAssertTrue(session.owns(trackID: "t2"))
        XCTAssertFalse(session.owns(trackID: "t4"))
    }

    func testRefillThresholdFollowsFeeder() {
        let session = session(threshold: 2)
        XCTAssertTrue(session.needsRefill(remaining: 1))
        XCTAssertFalse(session.needsRefill(remaining: 2))
    }

    func testRefillSkipsQueuedAndRecentlyPlayed() {
        var session = session()
        let all = (1...10).map { track("t\($0)") }
        let first = session.initialBatch(from: all)
        session.notePlayed(trackID: "t1")
        session.notePlayed(trackID: "t2")
        // t3 is current; nothing else queued.
        let refill = session.nextBatch(from: all, queued: [first[2]])
        XCTAssertEqual(refill.map(\.id), ["t4", "t5", "t6"])
    }

    func testFetchCountGrowsWithIssuedTracksUpToMaximum() {
        var session = StationSession(
            station: .libraryRadio,
            feeder: RadioQueueFeeder(refillThreshold: 2, batchSize: 5, dedupeWindow: 50),
            maxFetchCount: 18
        )
        XCTAssertEqual(session.fetchCount, 10)
        let first = session.initialBatch(from: (1...20).map { track("t\($0)") })
        XCTAssertEqual(session.fetchCount, 15)
        _ = session.nextBatch(from: (1...20).map { track("t\($0)") }, queued: first)
        XCTAssertEqual(session.fetchCount, 18)
    }

    func testSmallPoolLoopsByRelaxingHistoryWindowButNeverRepeatsQueue() {
        var session = session(batch: 2, window: 50)
        let pool = (1...4).map { track("t\($0)") }
        _ = session.initialBatch(from: pool)                       // t1 t2
        session.notePlayed(trackID: "t1")
        session.notePlayed(trackID: "t2")
        let second = session.nextBatch(from: pool, queued: [pool[1]])   // t3 t4
        XCTAssertEqual(second.map(\.id), ["t3", "t4"])
        session.notePlayed(trackID: "t3")
        session.notePlayed(trackID: "t4")
        // Everything was played within the window; t4 is current.
        let third = session.nextBatch(from: pool, queued: [pool[3]])
        XCTAssertFalse(third.isEmpty, "station must keep going on a tiny pool")
        XCTAssertFalse(third.contains { $0.id == "t4" }, "never re-queue what is queued")
        // Oldest plays come back first.
        XCTAssertEqual(third.first?.id, "t1")
    }

    func testEmptyCandidatesYieldNothing() {
        var session = session()
        XCTAssertTrue(session.nextBatch(from: [], queued: []).isEmpty)
    }

    func testArtistSpacingAppliedBeforeCuttingBatch() {
        var session = session(batch: 3, spacing: 2)
        let candidates = [
            track("a1", artist: "A"), track("a2", artist: "A"), track("a3", artist: "A"),
            track("b1", artist: "B"), track("c1", artist: "C"),
        ]
        XCTAssertEqual(session.initialBatch(from: candidates).map(\.id), ["a1", "b1", "c1"])
    }

    func testStationEndsWhenQueueWasReplaced() {
        var session = session()
        _ = session.initialBatch(from: (1...3).map { track("t\($0)") })
        XCTAssertTrue(session.isStillPlaying(currentTrackID: "t1", upNextIDs: ["t2", "t3"]))
        // User inserted a foreign track via Play Next: station tracks still follow.
        XCTAssertTrue(session.isStillPlaying(currentTrackID: "x", upNextIDs: ["t2"]))
        // User played an album instead.
        XCTAssertFalse(session.isStillPlaying(currentTrackID: "x", upNextIDs: ["y", "z"]))
        XCTAssertFalse(session.isStillPlaying(currentTrackID: nil, upNextIDs: []))
    }

    func testHistoryIgnoresImmediateRepeatsAndIsBounded() {
        var session = session(window: 10)
        session.notePlayed(trackID: "a")
        session.notePlayed(trackID: "a")
        XCTAssertEqual(session.history, ["a"])
        for index in 0..<500 { session.notePlayed(trackID: "t\(index)") }
        XCTAssertEqual(session.history.count, 200)
        XCTAssertEqual(session.history.last, "t499")
    }
}

final class RadioBlendTests: XCTestCase {
    func testInterleavesTwoToOneAndDropsDuplicates() {
        let similar = ["s1", "s2", "s3", "own1", "s4"].map { track($0) }
        let own = ["own1", "own2"].map { track($0) }
        XCTAssertEqual(
            RadioBlend.interleave(primary: similar, secondary: own).map(\.id),
            ["s1", "s2", "own1", "s3", "own2", "s4"]
        )
    }

    func testFallsBackToWhicheverSideHasTracks() {
        let own = ["o1", "o2"].map { track($0) }
        XCTAssertEqual(RadioBlend.interleave(primary: [], secondary: own).map(\.id), ["o1", "o2"])
        XCTAssertEqual(RadioBlend.interleave(primary: own, secondary: []).map(\.id), ["o1", "o2"])
        XCTAssertTrue(RadioBlend.interleave(primary: [], secondary: []).isEmpty)
    }
}

final class StationRefillTests: XCTestCase {
    /// Records requested counts; serves a ranked (deterministic) list like
    /// jellyamp-server's stations endpoint does.
    private final class RankedSource: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int] = []
        let pool: [Track]

        init(pool: [Track]) { self.pool = pool }

        var requestedCounts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }

        private func record(_ count: Int) {
            lock.lock()
            counts.append(count)
            lock.unlock()
        }

        var source: RadioSource {
            RadioSource { [self] request in
                record(request.count)
                return Array(pool.prefix(request.count))
            }
        }
    }

    func testRefillFetchesSelectsAndRecords() async throws {
        let ranked = RankedSource(pool: (1...40).map { track("t\($0)") })
        var session = StationSession(
            station: .genre("Jazz"),
            feeder: RadioQueueFeeder(refillThreshold: 2, batchSize: 4, dedupeWindow: 50),
            artistSpacing: 0
        )
        let first = try await StationRefill.nextTracks(session: &session, source: ranked.source, queued: [], currentTrackID: nil)
        XCTAssertEqual(first.map(\.id), ["t1", "t2", "t3", "t4"])
        first.forEach { session.notePlayed(trackID: $0.id) }

        let second = try await StationRefill.nextTracks(
            session: &session,
            source: ranked.source,
            queued: [first[3]],
            currentTrackID: "t4"
        )
        XCTAssertEqual(second.map(\.id), ["t5", "t6", "t7", "t8"])
        XCTAssertEqual(ranked.requestedCounts, [8, 12], "asks deeper as more tracks were issued")
    }

    func testRetriesWithMaximumWhenFirstFetchHasNothingFresh() async throws {
        let ranked = RankedSource(pool: (1...30).map { track("t\($0)") })
        var session = StationSession(
            station: .libraryRadio,
            feeder: RadioQueueFeeder(refillThreshold: 2, batchSize: 2, dedupeWindow: 0),
            artistSpacing: 0,
            maxFetchCount: 30
        )
        // The first four ranked tracks are already sitting in the queue
        // (e.g. queued by hand): the normal-depth fetch has nothing new.
        let queued = (1...4).map { track("t\($0)") }
        let batch = try await StationRefill.nextTracks(session: &session, source: ranked.source, queued: queued, currentTrackID: "t1")
        XCTAssertEqual(batch.map(\.id), ["t5", "t6"])
        XCTAssertEqual(ranked.requestedCounts, [4, 30])
    }

    func testSourceErrorLeavesSessionUntouched() async {
        struct Offline: Error {}
        var session = StationSession(station: .libraryRadio)
        let failing = RadioSource { _ in throw Offline() }
        do {
            _ = try await StationRefill.nextTracks(session: &session, source: failing, queued: [], currentTrackID: nil)
            XCTFail("expected the source error to propagate")
        } catch {
            XCTAssertTrue(session.issuedIDs.isEmpty)
        }
    }

    func testCurrentTrackIsPassedToDriftingSources() async throws {
        let seen = Box()
        let source = RadioSource { request in
            seen.set(request.currentTrackID)
            return [track("n1")]
        }
        var session = StationSession(station: .trackRadio(for: track("seed")))
        _ = try await StationRefill.nextTracks(session: &session, source: source, queued: [], currentTrackID: "now")
        XCTAssertEqual(seen.value, "now")
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ value: String?) {
            lock.lock()
            stored = value
            lock.unlock()
        }
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
