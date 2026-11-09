import XCTest
@testable import JellyampCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func track(
    _ id: String,
    title: String? = nil,
    artist: String = "Artist",
    artistID: String? = "ar1",
    album: String? = "Album",
    albumID: String? = "al1",
    index: Int? = nil,
    disc: Int? = nil,
    container: String? = "flac",
    genres: [String] = [],
    year: Int? = nil,
    favorite: Bool = false
) -> Track {
    Track(
        id: id, title: title ?? id, artistName: artist, artistID: artistID, albumName: album, albumID: albumID,
        indexNumber: index, discNumber: disc, duration: 180, container: container, bitrate: 320_000,
        isFavorite: favorite, genres: genres, productionYear: year
    )
}

private func trackPin(_ t: Track) -> DownloadPin { DownloadPin.track(t, now: t0) }

final class DownloadFileNamingTests: XCTestCase {
    func testPlainContainerIsTheExtension() {
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: "flac", codec: "flac"), "flac")
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: "OGG", codec: "vorbis"), "ogg")
    }

    func testFFProbeFormatListPicksM4A() {
        // What Jellyfin reports on the item (not the media source) for .m4a files.
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: "mov,mp4,m4a,3gp,3g2,mj2", codec: "aac"), "m4a")
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: "matroska,webm", codec: "opus"), "webm")
    }

    func testMissingContainerFallsBackToCodecThenMP3() {
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: nil, codec: "ALAC"), "m4a")
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: nil, codec: nil), "mp3")
    }

    func testUnsafeValuesNeverReachTheFileName() {
        XCTAssertEqual(DownloadFileNaming.fileExtension(container: "../../x", codec: nil), "mp3")
        XCTAssertEqual(DownloadFileNaming.fileName(for: track("a/../b", container: "mp3")), "a____b.mp3")
    }

    func testCanonicalNameMatchesLegacyNameForOrdinaryTracks() {
        let t = track("0123abcd", container: "m4a")
        XCTAssertEqual(DownloadFileNaming.fileName(for: t), DownloadFileNaming.legacyFileName(for: t))
    }

    func testStorageEstimateAndFreeSpaceCheck() {
        // 320 kbit/s × 180 s = 7.2 MB
        XCTAssertEqual(DownloadStorage.estimatedBytes(for: track("a")), 7_200_000)
        XCTAssertGreaterThan(DownloadStorage.estimatedBytes(for: Track(id: "x", title: "x", artistName: "", duration: 0)), 0)
        XCTAssertTrue(DownloadStorage.canStart(expectedBytes: 100, freeBytes: nil))
        XCTAssertTrue(DownloadStorage.canStart(expectedBytes: 100, freeBytes: 1_100, reserveBytes: 1_000))
        XCTAssertFalse(DownloadStorage.canStart(expectedBytes: 101, freeBytes: 1_100, reserveBytes: 1_000))
    }
}

final class DownloadIndexTests: XCTestCase {
    func testLegacyTrackArrayMigratesToCompleteTrackPins() throws {
        let legacy = [track("a", container: "mp3"), track("b", container: nil), track("a", container: "mp3")]
        let data = try JSONEncoder().encode(legacy)
        let index = try DownloadIndex.decode(from: data, now: t0)

        XCTAssertEqual(index.schemaVersion, DownloadIndex.currentSchemaVersion)
        XCTAssertEqual(index.completeEntries.map(\.id), ["a", "b"])
        XCTAssertEqual(index.entry(for: "b")?.fileName, "b.mp3", "legacy files keep their old names")
        XCTAssertEqual(index.pins.map(\.id), ["track:a", "track:b"])
        XCTAssertEqual(index.manuallyPinnedTrackIDs, ["a", "b"])
    }

    func testRoundTripAndFutureVersionIsRejected() throws {
        var index = DownloadIndex()
        index.setPin(.album(Album(id: "al1", title: "Album", artistName: "Artist"), now: t0), tracks: [track("a"), track("b")], now: t0)
        let data = try index.encoded()
        XCTAssertEqual(try DownloadIndex.decode(from: data), index)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try DownloadIndex.decode(from: future)) { error in
            XCTAssertEqual(error as? DownloadIndexError, .unsupportedSchemaVersion(99))
        }
    }

    func testPinningQueuesOnlyNewTracksAndDeduplicates() {
        var index = DownloadIndex()
        let first = index.setPin(trackPin(track("a")), tracks: [track("a")], now: t0)
        XCTAssertEqual(first.queued, ["a"])
        let album = DownloadPin.album(Album(id: "al1", title: "Album", artistName: "Artist"), now: t0)
        let second = index.setPin(album, tracks: [track("a"), track("b"), track("b")], now: t0)
        XCTAssertEqual(second.queued, ["b"])
        XCTAssertEqual(index.pin(id: "album:al1")?.trackIDs, ["a", "b"])
        XCTAssertEqual(index.orderedEntries.map(\.id), ["a", "b"])
    }

    func testRemovingAlbumKeepsTracksAnotherPinNeeds() {
        var index = DownloadIndex()
        let a = track("a"), b = track("b")
        index.setPin(.album(Album(id: "al1", title: "Album", artistName: "Artist"), now: t0), tracks: [a, b], now: t0)
        index.setPin(.playlist(Playlist(id: "pl1", name: "Mix"), now: t0), tracks: [b], now: t0)
        index.setPin(trackPin(a), tracks: [a], now: t0)

        let change = index.removeAlbum(id: "al1")
        XCTAssertEqual(change.removed.map(\.id), ["a"], "a's own track pin goes with the album; b stays for the playlist")
        XCTAssertNotNil(index.entry(for: "b"))
        XCTAssertEqual(index.pins.map(\.id), ["playlist:pl1"])
    }

    func testResyncingPlaylistAddsAndDropsTracks() {
        var index = DownloadIndex()
        let pin = DownloadPin.playlist(Playlist(id: "pl1", name: "Mix"), now: t0)
        index.setPin(pin, tracks: [track("a"), track("b")], now: t0)
        index.markCompleted(id: "a", bytes: 10, now: t0)

        var renamed = pin
        renamed.title = "Mix v2"
        let change = index.setPin(renamed, tracks: [track("c"), track("a", favorite: true)], now: t0.addingTimeInterval(60))
        XCTAssertEqual(change.queued, ["c"])
        XCTAssertEqual(change.removed.map(\.id), ["b"])
        XCTAssertEqual(index.pin(id: pin.id)?.trackIDs, ["c", "a"], "playlist order follows the server")
        XCTAssertEqual(index.pin(id: pin.id)?.title, "Mix v2")
        XCTAssertEqual(index.pin(id: pin.id)?.addedAt, t0)
        XCTAssertEqual(index.entry(for: "a")?.phase, .complete, "already downloaded tracks are not fetched again")
        XCTAssertEqual(index.entry(for: "a")?.track.isFavorite, true, "metadata is refreshed")
    }

    func testPlaylistEntryIDIsNotStoredOnSharedEntries() {
        var index = DownloadIndex()
        var t = track("a")
        t.playlistEntryID = "entry-1"
        index.setPin(.playlist(Playlist(id: "pl1", name: "Mix"), now: t0), tracks: [t], now: t0)
        XCTAssertNil(index.entry(for: "a")?.track.playlistEntryID)
    }

    func testRemoveTrackTakesItOutOfEveryPin() {
        var index = DownloadIndex()
        let a = track("a"), b = track("b")
        index.setPin(.playlist(Playlist(id: "pl1", name: "Mix"), now: t0), tracks: [a, b], now: t0)
        index.setPin(trackPin(a), tracks: [a], now: t0)
        let change = index.removeTrack(id: "a")
        XCTAssertEqual(change.removed.map(\.id), ["a"])
        XCTAssertEqual(index.pins.map(\.id), ["playlist:pl1"], "the emptied track pin is gone")
        XCTAssertEqual(index.pin(id: "playlist:pl1")?.trackIDs, ["b"])
    }

    func testSmartSyncTracksAreNotManuallyPinned() {
        var index = DownloadIndex()
        index.setPin(.smartSync(now: t0), tracks: [track("a"), track("b")], now: t0)
        index.setPin(trackPin(track("b")), tracks: [track("b")], now: t0)
        XCTAssertEqual(index.manuallyPinnedTrackIDs, ["b"])
        XCTAssertEqual(index.smartSyncTrackIDs, ["a", "b"])
        // Emptying the smart-sync pin evicts only what nothing else pins.
        let change = index.setPin(.smartSync(now: t0), tracks: [], now: t0)
        XCTAssertEqual(change.removed.map(\.id), ["a"])
    }

    func testStorageAccountingCountsCompleteFilesOnly() {
        var index = DownloadIndex()
        index.setPin(.album(Album(id: "al1", title: "Album", artistName: "Artist"), now: t0), tracks: [track("a"), track("b")], now: t0)
        index.markCompleted(id: "a", bytes: 1_000, now: t0)
        XCTAssertEqual(index.totalBytes, 1_000)
        let progress = index.progress(forPin: "album:al1")
        XCTAssertEqual(progress.complete, 1)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.bytes, 1_000)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(index.removeAll().removed.count, 2)
        XCTAssertEqual(index.totalBytes, 0)
    }

    func testArtworkReferences() {
        var index = DownloadIndex()
        index.setPin(.playlist(Playlist(id: "pl1", name: "Mix"), now: t0), tracks: [track("a"), track("s", artistID: nil, albumID: nil)], now: t0)
        XCTAssertEqual(index.referencedArtworkItemIDs, ["al1", "ar1", "s", "pl1"])
    }

    func testSingleAlbumInference() {
        XCTAssertEqual(DownloadPinInference.singleAlbum(in: [track("a"), track("b")])?.id, "al1")
        XCTAssertNil(DownloadPinInference.singleAlbum(in: [track("a")]), "one track is just a track")
        XCTAssertNil(DownloadPinInference.singleAlbum(in: [track("a"), track("b", albumID: "al2")]))
    }
}

final class DownloadQueueTests: XCTestCase {
    private func queued(_ ids: [String]) -> DownloadIndex {
        var index = DownloadIndex()
        index.setPin(.smartSync(now: t0), tracks: ids.map { track($0) }, now: t0)
        return index
    }

    func testStartsOldestFirstUpToConcurrencyLimit() {
        var index = queued(["a", "b", "c", "d"])
        let policy = DownloadQueuePolicy(maxConcurrent: 2)
        XCTAssertEqual(index.startNext(now: t0, policy: policy).map(\.id), ["a", "b"])
        XCTAssertTrue(index.startNext(now: t0, policy: policy).isEmpty, "no free slot")
        index.markCompleted(id: "a", bytes: 5, now: t0)
        XCTAssertEqual(index.startNext(now: t0, policy: policy).map(\.id), ["c"])
        XCTAssertEqual(index.entry(for: "c")?.attempts, 1)
    }

    func testBackoffGrowsAndIsCapped() {
        let policy = DownloadRetryPolicy(maxAttempts: 10, baseDelay: 5, maxDelay: 60)
        XCTAssertEqual(policy.delay(afterAttempt: 1), 5)
        XCTAssertEqual(policy.delay(afterAttempt: 2), 10)
        XCTAssertEqual(policy.delay(afterAttempt: 3), 20)
        XCTAssertEqual(policy.delay(afterAttempt: 9), 60)
    }

    func testTransientFailureIsRetriedAfterDelayThenGivesUp() {
        var index = queued(["a"])
        let retry = DownloadRetryPolicy(maxAttempts: 2, baseDelay: 5)
        let policy = DownloadQueuePolicy(maxConcurrent: 1, retry: retry)
        _ = index.startNext(now: t0, policy: policy)
        XCTAssertEqual(index.markFailed(id: "a", failure: .network, now: t0, policy: retry), .retry(after: 5))
        XCTAssertEqual(index.entry(for: "a")?.phase, .waitingToRetry)
        XCTAssertEqual(index.nextRetryDate, t0.addingTimeInterval(5))
        XCTAssertTrue(index.startNext(now: t0.addingTimeInterval(4), policy: policy).isEmpty, "not due yet")
        XCTAssertEqual(index.startNext(now: t0.addingTimeInterval(5), policy: policy).map(\.id), ["a"])
        XCTAssertEqual(index.markFailed(id: "a", failure: .network, now: t0, policy: retry), .giveUp)
        XCTAssertEqual(index.entry(for: "a")?.phase, .failed)
        XCTAssertNil(index.nextRetryDate)

        index.retry(id: "a")
        XCTAssertEqual(index.entry(for: "a")?.phase, .queued)
        XCTAssertEqual(index.entry(for: "a")?.attempts, 0, "manual retry gets a fresh budget")
    }

    func testPermanentFailuresAreNotRetried() {
        for failure in [DownloadFailure.forbidden, .unauthorized, .notFound, .insufficientStorage] {
            var index = queued(["a"])
            _ = index.startNext(now: t0)
            XCTAssertEqual(index.markFailed(id: "a", failure: failure, now: t0), .giveUp)
            XCTAssertEqual(index.entry(for: "a")?.failure, failure)
        }
    }

    func testHTTPStatusClassification() {
        XCTAssertNil(DownloadFailure.from(httpStatus: 200))
        XCTAssertNil(DownloadFailure.from(httpStatus: 206))
        XCTAssertEqual(DownloadFailure.from(httpStatus: 401), .unauthorized)
        XCTAssertEqual(DownloadFailure.from(httpStatus: 403), .forbidden)
        XCTAssertEqual(DownloadFailure.from(httpStatus: 404), .notFound)
        XCTAssertEqual(DownloadFailure.from(httpStatus: 429), .rateLimited)
        XCTAssertEqual(DownloadFailure.from(httpStatus: 503), .serverError)
        XCTAssertEqual(DownloadFailure.from(httpStatus: 400), .badResponse)
        XCTAssertTrue(DownloadFailure.serverError.isTransient)
        XCTAssertFalse(DownloadFailure.badResponse.isTransient)
    }

    func testPauseResumeAndLateCancellationReport() {
        var index = queued(["a", "b"])
        let policy = DownloadQueuePolicy(maxConcurrent: 1)
        _ = index.startNext(now: t0, policy: policy)
        XCTAssertTrue(index.pause(id: "a"), "a running transfer must be stopped")
        XCTAssertFalse(index.pause(id: "b"), "b was only queued")
        // URLSession reports the cancellation after the pause: must stay paused.
        index.markFailed(id: "a", failure: .network, now: t0)
        XCTAssertEqual(index.entry(for: "a")?.phase, .paused)
        XCTAssertTrue(index.startNext(now: t0, policy: policy).isEmpty)
        index.resume(id: "b")
        XCTAssertEqual(index.startNext(now: t0, policy: policy).map(\.id), ["b"])
    }

    func testPauseAllAndResumeAll() {
        var index = queued(["a", "b", "c"])
        _ = index.startNext(now: t0, policy: DownloadQueuePolicy(maxConcurrent: 1))
        XCTAssertEqual(index.pauseAll(), ["a"])
        XCTAssertTrue(index.pendingEntries.allSatisfy { $0.phase == .paused })
        index.resumeAll()
        XCTAssertTrue(index.pendingEntries.allSatisfy { $0.phase == .queued })
    }

    func testRequeueDoesNotConsumeAnAttempt() {
        var index = queued(["a"])
        _ = index.startNext(now: t0)
        index.requeue(id: "a")
        XCTAssertEqual(index.entry(for: "a")?.phase, .queued)
        XCTAssertEqual(index.entry(for: "a")?.attempts, 0)
    }

    func testReconcileAfterRelaunch() {
        var index = queued(["done", "lost", "live", "gone", "paused"])
        _ = index.startNext(now: t0, policy: DownloadQueuePolicy(maxConcurrent: 3))  // done, lost, live downloading
        index.markCompleted(id: "gone", bytes: 9, now: t0)
        index.pause(id: "paused")

        let result = index.reconcile(
            liveTaskIDs: ["live", "paused", "stranger"],
            files: ["done.flac": 42, "junk.flac": 1],
            now: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(index.entry(for: "done")?.phase, .complete, "finished in the background")
        XCTAssertEqual(index.entry(for: "done")?.bytes, 42)
        XCTAssertEqual(index.entry(for: "lost")?.phase, .queued, "transfer died with the app")
        XCTAssertEqual(index.entry(for: "lost")?.attempts, 0)
        XCTAssertEqual(index.entry(for: "live")?.phase, .downloading)
        XCTAssertEqual(index.entry(for: "gone")?.phase, .queued, "file was deleted behind our back")
        XCTAssertEqual(result.orphanFiles, ["junk.flac"])
        XCTAssertEqual(result.strayTaskIDs, ["paused", "stranger"])
        XCTAssertTrue(result.changed)

        let again = index.reconcile(liveTaskIDs: ["live"], files: ["done.flac": 42], now: t0)
        XCTAssertFalse(again.changed)
    }

    func testReconcileAdoptsLegacyFileNamesAndFillsSizes() {
        // Migrated entries have unknown sizes and legacy names.
        var index = DownloadIndex.migrated(fromLegacyTracks: [track("a", container: nil)], now: t0)
        let result = index.reconcile(liveTaskIDs: [], files: ["a.mp3": 77], now: t0)
        XCTAssertEqual(index.entry(for: "a")?.bytes, 77)
        XCTAssertEqual(index.entry(for: "a")?.phase, .complete)
        XCTAssertTrue(result.orphanFiles.isEmpty)
        XCTAssertEqual(index.totalBytes, 77)
    }
}

final class OfflineCatalogTests: XCTestCase {
    private func makeCatalog() -> OfflineCatalog {
        var index = DownloadIndex()
        let quarry = [
            track("q2", title: "Hard Hat Blues", artist: "The Granite Saints", artistID: "gs", album: "Quarry Songs",
                  albumID: "quarry", index: 2, genres: ["Rock"], year: 1978),
            track("q1", title: "Dust", artist: "The Granite Saints", artistID: "gs", album: "Quarry Songs",
                  albumID: "quarry", index: 1, genres: ["Rock", "Blues"], year: 1978, favorite: true),
            track("q3", title: "Second Disc", artist: "The Granite Saints", artistID: "gs", album: "Quarry Songs",
                  albumID: "quarry", index: 1, disc: 2, genres: ["Rock"], year: 1978),
        ]
        let after = [
            track("n1", title: "Phosphor", artist: "Neon Circuit", artistID: "nc", album: "Afterimage",
                  albumID: "after", index: 1, genres: ["Electronic"], year: 2021),
            track("n2", title: "Café Étoile", artist: "Guest", artistID: "guest", album: "Afterimage",
                  albumID: "after", index: 2, genres: ["electronic"], year: 2021),
        ]
        let pending = track("x", title: "Not Finished", artist: "Nobody", artistID: "nb", album: "Never", albumID: "never")
        let afterAlbum = Album(
            id: "after", title: "Afterimage", artistName: "Neon Circuit", artistID: "nc", productionYear: 2021,
            trackCount: 9, isFavorite: true, imageTag: "tag"
        )
        index.setPin(.album(afterAlbum, now: t0), tracks: after, now: t0)
        index.setPin(.playlist(Playlist(id: "pl", name: "Road Trip"), now: t0), tracks: [quarry[0], after[0], pending, quarry[1]], now: t0)
        index.setPin(.smartSync(now: t0), tracks: quarry, now: t0)
        var offset: TimeInterval = 0
        for id in ["n1", "n2", "q1", "q2", "q3"] {
            offset += 10
            index.markCompleted(id: id, bytes: 100, now: t0.addingTimeInterval(offset))
        }
        return OfflineCatalog(index: index, genreNamesByID: ["guid-rock": "Rock"])
    }

    func testOnlyCompleteTracksAreListed() {
        let catalog = makeCatalog()
        XCTAssertEqual(Set(catalog.tracks.map(\.id)), ["q1", "q2", "q3", "n1", "n2"])
        XCTAssertNil(catalog.album(id: "never"))
        XCTAssertEqual(catalog.tracks(byIDs: ["n2", "x", "q1"]).map(\.id), ["n2", "q1"])
    }

    func testAlbumReconstruction() {
        let catalog = makeCatalog()
        let quarry = try? XCTUnwrap(catalog.album(id: "quarry"))
        XCTAssertEqual(quarry?.title, "Quarry Songs")
        XCTAssertEqual(quarry?.artistName, "The Granite Saints")
        XCTAssertEqual(quarry?.artistID, "gs")
        XCTAssertEqual(quarry?.productionYear, 1978)
        XCTAssertEqual(quarry?.trackCount, 3)
        XCTAssertEqual(quarry?.duration, 540)
        XCTAssertEqual(quarry?.genres, ["Rock", "Blues"])

        // Pinned albums keep server metadata but count what is on the device.
        let after = catalog.album(id: "after")
        XCTAssertEqual(after?.artistName, "Neon Circuit")
        XCTAssertEqual(after?.imageTag, "tag")
        XCTAssertEqual(after?.trackCount, 2)
        XCTAssertEqual(after?.isFavorite, true)
    }

    func testAlbumTracksAreInDiscAndTrackOrder() {
        XCTAssertEqual(makeCatalog().tracks(inAlbum: "quarry").map(\.id), ["q1", "q2", "q3"])
    }

    func testAlbumSortingAndPaging() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.albums().map(\.id), ["after", "quarry"])
        XCTAssertEqual(catalog.albums(sortBy: "ProductionYear", sortOrder: "Descending").map(\.id), ["after", "quarry"])
        XCTAssertEqual(catalog.albums(sortBy: "ProductionYear,SortName", sortOrder: "Ascending").map(\.id), ["quarry", "after"])
        // "The Granite Saints" sorts under G, before "Neon Circuit".
        XCTAssertEqual(catalog.albums(sortBy: "AlbumArtist,SortName", sortOrder: "Ascending").map(\.id), ["quarry", "after"])
        XCTAssertEqual(catalog.recentlyAddedAlbums(limit: 1).map(\.id), ["quarry"])
        XCTAssertEqual(catalog.albums(startIndex: 1, limit: 5).map(\.id), ["quarry"])
        XCTAssertTrue(catalog.albums(startIndex: 2, limit: 5).isEmpty)
        XCTAssertEqual(Set(catalog.albums(sortBy: "Random").map(\.id)), ["after", "quarry"])
        XCTAssertEqual(catalog.favoriteAlbums(limit: 10).map(\.id), ["after"])
    }

    func testArtistReconstruction() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.artists().map(\.name), ["The Granite Saints", "Guest", "Neon Circuit"])
        XCTAssertEqual(catalog.artist(id: "gs")?.genres, ["Rock", "Blues"])
        XCTAssertEqual(catalog.albums(byArtist: "nc").map(\.id), ["after"])
        XCTAssertTrue(catalog.albums(byArtist: "guest").isEmpty)
        XCTAssertEqual(catalog.appearsOnAlbums(artistID: "guest").map(\.id), ["after"])
        XCTAssertEqual(catalog.tracks(byArtist: "gs").map(\.id), ["q1", "q2", "q3"])
    }

    func testGenresAreGroupedCaseInsensitively() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.genres().map(\.name), ["Blues", "Electronic", "Rock"])
        let electronic = catalog.genres()[1]
        XCTAssertTrue(electronic.id.hasPrefix(OfflineCatalog.genreIDPrefix))
        XCTAssertEqual(Set(catalog.tracks(inGenre: electronic.id).map(\.id)), ["n1", "n2"])
        XCTAssertEqual(catalog.tracks(inGenre: "guid-rock").count, 3, "server genre ids resolve through the learned names")
        XCTAssertTrue(catalog.tracks(inGenre: "unknown-guid").isEmpty)
    }

    func testPlaylistsKeepOrderAndSkipUnfinishedTracks() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.playlists().map(\.name), ["Road Trip"])
        XCTAssertEqual(catalog.playlists().first?.trackCount, 3)
        XCTAssertEqual(catalog.tracks(inPlaylist: "pl").map(\.id), ["q2", "n1", "q1"])
    }

    func testSearch() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.search(query: "cafe etoile", limit: 10).tracks.map(\.id), ["n2"], "diacritics and case are ignored")
        XCTAssertEqual(catalog.search(query: "granite dust", limit: 10).tracks.map(\.id), ["q1"], "words may match artist and title")
        let quarry = catalog.search(query: "QUARRY", limit: 10)
        XCTAssertEqual(quarry.albums.map(\.id), ["quarry"])
        XCTAssertEqual(quarry.tracks.count, 3, "tracks match on their album name")
        XCTAssertEqual(catalog.search(query: "neon", limit: 10).artists.map(\.id), ["nc"])
        XCTAssertEqual(catalog.search(query: "road", limit: 10).playlists.map(\.id), ["pl"])
        XCTAssertEqual(catalog.search(query: "s", limit: 1).tracks.map(\.id), ["q3"], "title prefix ranks first; limit applies")
        XCTAssertTrue(catalog.search(query: "   ", limit: 10).tracks.isEmpty)
    }

    func testFavorites() {
        XCTAssertEqual(makeCatalog().favoriteTracks(limit: 10).map(\.id), ["q1"])
    }
}

final class OfflineStateTrackerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var date = t0
    }

    func testReasonPrecedence() {
        let tracker = OfflineStateTracker()
        XCTAssertFalse(tracker.isOffline)
        tracker.recordConnectivityFailure()
        XCTAssertEqual(tracker.snapshot.reason, .serverUnreachable)
        tracker.setNetworkPath(isSatisfied: false, isExpensive: false)
        XCTAssertEqual(tracker.snapshot.reason, .noNetwork)
        tracker.setUserEnabled(true)
        XCTAssertEqual(tracker.snapshot.reason, .userEnabled)
        XCTAssertEqual(tracker.route(), .offline)
    }

    func testFailureOpensCircuitAndProbesAfterInterval() {
        let clock = Clock()
        let tracker = OfflineStateTracker(retryInterval: 20, now: { clock.date })
        XCTAssertEqual(tracker.route(), .online)
        tracker.recordConnectivityFailure()
        XCTAssertEqual(tracker.route(), .offline)
        clock.date = t0.addingTimeInterval(21)
        XCTAssertEqual(tracker.route(), .probe)
        XCTAssertEqual(tracker.route(), .offline, "only one request probes")
        tracker.recordRequestSuccess()
        XCTAssertEqual(tracker.route(), .online)
        XCTAssertFalse(tracker.isOffline)
    }

    func testNetworkComingBackClearsUnreachable() {
        let tracker = OfflineStateTracker()
        tracker.setNetworkPath(isSatisfied: false, isExpensive: false)
        tracker.recordConnectivityFailure()
        tracker.setNetworkPath(isSatisfied: true, isExpensive: true)
        XCTAssertEqual(tracker.route(), .online)
        XCTAssertEqual(tracker.snapshot, OfflineStateTracker.Snapshot(reason: nil, isExpensive: true))
    }

    func testObserversFireOnlyOnChange() {
        final class Box: @unchecked Sendable { var seen: [OfflineReason?] = [] }
        let box = Box()
        let tracker = OfflineStateTracker()
        tracker.observe { box.seen.append($0.reason) }
        tracker.setUserEnabled(true)
        tracker.setUserEnabled(true)
        tracker.recordConnectivityFailure()  // hidden behind the user's choice
        tracker.setUserEnabled(false)
        XCTAssertEqual(box.seen, [.userEnabled, .serverUnreachable])
    }
}

final class SmartSyncStorageTests: XCTestCase {
    func testOldRulesPayloadDecodesWithNewDefaults() throws {
        let old = #"{"autoDownloadFavorites":true,"keepLatestMixes":2}"#
        let rules = try JSONDecoder().decode(SmartSyncRules.self, from: Data(old.utf8))
        XCTAssertEqual(rules, SmartSyncRules(autoDownloadFavorites: true, keepLatestMixes: 2))
        XCTAssertTrue(rules.isEnabled)
        XCTAssertNil(rules.maxStorageBytes)
        XCTAssertFalse(SmartSyncRules().isEnabled)
    }

    func testFavoriteAlbumsAreCoveredAfterFavoriteTracks() {
        let planner = SmartSyncPlanner(rules: SmartSyncRules(autoDownloadFavorites: true, autoDownloadFavoriteAlbums: true))
        let plan = planner.plan(
            favoriteIDs: ["f"], favoriteAlbumTrackIDs: ["a1", "f", "a2"], mixes: [], downloadedIDs: ["a1", "old"], pinnedIDs: []
        )
        XCTAssertEqual(plan.desired, ["f", "a1", "a2"])
        XCTAssertEqual(plan.download, ["f", "a2"])
        XCTAssertEqual(plan.evict, ["old"])
    }

    func testStorageCapCutsOffByPriorityAndPinnedTracksAreFree() {
        let rules = SmartSyncRules(autoDownloadFavorites: true, keepLatestMixes: 1, maxStorageMB: 2)
        let mb: Int64 = 1_048_576
        let plan = SmartSyncPlanner(rules: rules).plan(
            favoriteIDs: ["f1", "pinned", "f2"],
            mixes: [MixDescriptor(id: "m", title: "m", itemIDs: ["m1", "tiny"])],
            downloadedIDs: ["m1", "pinned"],
            pinnedIDs: ["pinned"],
            estimatedBytes: ["f1": mb, "pinned": 50 * mb, "f2": mb, "m1": mb, "tiny": 1]
        )
        XCTAssertEqual(plan.desired, ["f1", "pinned", "f2"])
        XCTAssertEqual(plan.skippedForStorage, ["m1", "tiny"], "no first-fit past the cut-off")
        XCTAssertEqual(plan.download, ["f1", "f2"])
        XCTAssertEqual(plan.evict, ["m1"], "an auto-synced track that no longer fits is released")
    }
}
