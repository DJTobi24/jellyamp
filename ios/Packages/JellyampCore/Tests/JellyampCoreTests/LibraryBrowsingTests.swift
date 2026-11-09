import XCTest
@testable import JellyampCore

private func track(
    _ id: String,
    title: String? = nil,
    artist: String = "Artist",
    album: String? = nil,
    index: Int? = nil,
    disc: Int? = nil,
    duration: TimeInterval = 180,
    entry: String? = nil
) -> Track {
    Track(
        id: id, title: title ?? id, artistName: artist, albumName: album, indexNumber: index, discNumber: disc,
        duration: duration, playlistEntryID: entry
    )
}

private func albums(_ range: Range<Int>) -> [Album] {
    range.map { Album(id: "a\($0)", title: "Album \($0)", artistName: "X") }
}

// MARK: - Paging

final class PagedListStateTests: XCTestCase {
    func testFirstPageThenNextPagesUntilTotalIsReached() {
        var state = PagedListState<Album>(pageSize: 2)
        XCTAssertTrue(state.isInitialLoading)
        let first = state.beginReload()
        XCTAssertEqual(first.startIndex, 0)
        XCTAssertEqual(state.phase, .loadingFirstPage)
        XCTAssertNil(state.beginNextPage(), "no next page while the first one is in flight")

        XCTAssertTrue(state.receive(Page(items: albums(0..<2), totalCount: 5), for: first))
        XCTAssertEqual(state.items.count, 2)
        XCTAssertFalse(state.reachedEnd)

        let second = state.beginNextPage()!
        XCTAssertEqual(second.startIndex, 2)
        XCTAssertTrue(state.isLoadingMore)
        XCTAssertNil(state.beginNextPage(), "only one request in flight")
        state.receive(Page(items: albums(2..<4), totalCount: 5), for: second)

        let third = state.beginNextPage()!
        state.receive(Page(items: albums(4..<5), totalCount: 5), for: third)
        XCTAssertTrue(state.reachedEnd)
        XCTAssertNil(state.beginNextPage())
        XCTAssertEqual(state.items.map(\.id), ["a0", "a1", "a2", "a3", "a4"])
    }

    func testShortPageEndsListWhenServerGivesNoTotal() {
        var state = PagedListState<Album>(pageSize: 3)
        let request = state.beginReload()
        state.receive(Page(items: albums(0..<2)), for: request)
        XCTAssertTrue(state.reachedEnd)
    }

    func testEmptyAnswerIsEmptyStateNotLoading() {
        var state = PagedListState<Album>(pageSize: 3)
        let request = state.beginReload()
        state.receive(Page(items: [], totalCount: 0), for: request)
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.isInitialLoading)
        XCTAssertTrue(state.reachedEnd)
    }

    func testAnswerToSupersededRequestIsDropped() {
        var state = PagedListState<Album>(pageSize: 2)
        let stale = state.beginReload()
        let current = state.beginReload(keepingItems: false)
        XCTAssertFalse(state.receive(Page(items: albums(10..<12), totalCount: 50), for: stale))
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.fail("boom", for: stale))
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.receive(Page(items: albums(0..<2), totalCount: 2), for: current))
        XCTAssertEqual(state.items.map(\.id), ["a0", "a1"])
    }

    func testNextPageAnswerArrivingAfterReloadIsDropped() {
        var state = PagedListState<Album>(pageSize: 2)
        let first = state.beginReload()
        state.receive(Page(items: albums(0..<2), totalCount: 6), for: first)
        let next = state.beginNextPage()!
        let reload = state.beginReload(keepingItems: false) // sort changed mid-flight
        XCTAssertFalse(state.receive(Page(items: albums(2..<4), totalCount: 6), for: next))
        state.receive(Page(items: albums(20..<22), totalCount: 6), for: reload)
        XCTAssertEqual(state.items.map(\.id), ["a20", "a21"])
    }

    func testDuplicatesAcrossPagesAreDroppedAndOffsetFollowsTheServer() {
        var state = PagedListState<Album>(pageSize: 3)
        let first = state.beginReload()
        state.receive(Page(items: albums(0..<3), totalCount: 7), for: first)
        // An album was added on the server: the next page repeats "a2".
        let second = state.beginNextPage()!
        state.receive(Page(items: albums(2..<5), totalCount: 7), for: second)
        XCTAssertEqual(state.items.map(\.id), ["a0", "a1", "a2", "a3", "a4"])
        // Paging continues from the server offset (6), not from items.count (5).
        XCTAssertEqual(state.beginNextPage()?.startIndex, 6)
    }

    func testDuplicatesInsideOnePageAreDropped() {
        var state = PagedListState<Album>(pageSize: 4)
        let request = state.beginReload()
        state.receive(Page(items: albums(0..<2) + albums(0..<2), totalCount: 4), for: request)
        XCTAssertEqual(state.items.count, 2)
        XCTAssertTrue(state.reachedEnd)
    }

    func testFailedNextPageKeepsRowsAndCanBeRetried() {
        var state = PagedListState<Album>(pageSize: 2)
        let first = state.beginReload()
        state.receive(Page(items: albums(0..<2), totalCount: 4), for: first)
        let second = state.beginNextPage()!
        state.fail("offline", for: second)
        XCTAssertEqual(state.failure, .nextPage("offline"))
        XCTAssertNil(state.blockingError)
        XCTAssertEqual(state.items.count, 2)
        XCTAssertFalse(state.shouldLoadMore(whenShowing: "a1"), "no automatic retry loop while failed")
        let retry = state.beginNextPage()!
        XCTAssertEqual(retry.startIndex, 2)
        state.receive(Page(items: albums(2..<4), totalCount: 4), for: retry)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.items.count, 4)
    }

    func testFailedFirstPageIsBlockingOnlyWithoutRows() {
        var state = PagedListState<Album>(pageSize: 2)
        let request = state.beginReload()
        state.fail("no network", for: request)
        XCTAssertEqual(state.blockingError, "no network")
        XCTAssertFalse(state.isInitialLoading)
        XCTAssertFalse(state.isEmpty)

        var cached = PagedListState<Album>(pageSize: 2)
        cached.seed(albums(0..<2))
        XCTAssertTrue(cached.isShowingCachedItems)
        XCTAssertFalse(cached.isInitialLoading)
        let reload = cached.beginReload()
        XCTAssertEqual(cached.phase, .refreshing)
        cached.fail("no network", for: reload)
        XCTAssertNil(cached.blockingError, "cached rows stay; the error is a banner")
        XCTAssertEqual(cached.failure, .reload("no network"))
        XCTAssertNil(cached.beginNextPage(), "cached rows are not a paging position")
    }

    func testServerAnswerReplacesCachedRows() {
        var state = PagedListState<Album>(pageSize: 2)
        state.seed(albums(5..<7))
        let request = state.beginReload()
        state.receive(Page(items: albums(0..<2), totalCount: 9), for: request)
        XCTAssertFalse(state.isShowingCachedItems)
        XCTAssertEqual(state.items.map(\.id), ["a0", "a1"])
        state.seed(albums(5..<7))
        XCTAssertEqual(state.items.map(\.id), ["a0", "a1"], "seeding never overwrites server rows")
    }

    func testReloadFromOffsetForAlphabetJump() {
        var state = PagedListState<Album>(pageSize: 2)
        let request = state.beginReload(fromOffset: 40, keepingItems: false)
        XCTAssertEqual(request.startIndex, 40)
        state.receive(Page(items: albums(40..<42), totalCount: 43), for: request)
        XCTAssertEqual(state.baseOffset, 40)
        XCTAssertEqual(state.beginNextPage()?.startIndex, 42)
    }

    func testShouldLoadMoreOnlyNearTheEnd() {
        var state = PagedListState<Album>(pageSize: 50)
        let request = state.beginReload()
        state.receive(Page(items: albums(0..<50), totalCount: 500), for: request)
        XCTAssertFalse(state.shouldLoadMore(whenShowing: "a0", threshold: 10))
        XCTAssertFalse(state.shouldLoadMore(whenShowing: "a39", threshold: 10))
        XCTAssertTrue(state.shouldLoadMore(whenShowing: "a40", threshold: 10))
        XCTAssertTrue(state.shouldLoadMore(whenShowing: "a49", threshold: 10))
        _ = state.beginNextPage()
        XCTAssertFalse(state.shouldLoadMore(whenShowing: "a49", threshold: 10), "already loading")
    }

    func testRemoveKeepsPagingAligned() {
        var state = PagedListState<Album>(pageSize: 3)
        let request = state.beginReload()
        state.receive(Page(items: albums(0..<3), totalCount: 6), for: request)
        state.remove(id: "a1") // un-favorited: the server list shrank too
        XCTAssertEqual(state.items.map(\.id), ["a0", "a2"])
        XCTAssertEqual(state.totalCount, 5)
        XCTAssertEqual(state.beginNextPage()?.startIndex, 2)
    }

    func testCancelReturnsToRest() {
        var state = PagedListState<Album>(pageSize: 3)
        let request = state.beginReload()
        state.cancel(request)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.failure)
    }
}

// MARK: - Sorting

final class LibrarySortTests: XCTestCase {
    func testAlbumQueriesPairDirectionsWithKeys() {
        XCTAssertEqual(AlbumSortOption.name.query(), LibrarySortQuery(sortBy: "SortName", sortOrder: "Ascending"))
        XCTAssertEqual(
            AlbumSortOption.year.query(),
            LibrarySortQuery(sortBy: "ProductionYear,SortName", sortOrder: "Descending,Ascending")
        )
        XCTAssertEqual(
            AlbumSortOption.artist.query(direction: .descending),
            LibrarySortQuery(sortBy: "AlbumArtist,ProductionYear,SortName", sortOrder: "Descending,Ascending,Ascending")
        )
        XCTAssertEqual(AlbumSortOption.random.query(direction: .descending).sortBy, "Random")
        XCTAssertFalse(AlbumSortOption.random.supportsDirection)
    }

    func testSongsSortByNameNotSortName() {
        // Jellyfin's SortName for audio is "0001 - Title".
        XCTAssertEqual(TrackSortOption.title.query().sortBy, "Name")
        XCTAssertEqual(TrackSortOption.album.query().sortBy, "Album,SortName")
        XCTAssertEqual(TrackSortOption.mostPlayed.query().sortOrder, "Descending,Ascending")
        XCTAssertEqual(TrackSortOption.recentlyAdded.query().sortBy, "DateCreated,Album,SortName")
    }

    func testEveryOptionProducesAQuery() {
        for option in TrackSortOption.allCases { XCTAssertFalse(option.query().sortBy.isEmpty) }
        for option in AlbumSortOption.allCases { XCTAssertFalse(option.query().sortBy.isEmpty) }
        for option in ArtistSortOption.allCases { XCTAssertFalse(option.query().sortBy.isEmpty) }
        for option in PlaylistSortOption.allCases { XCTAssertFalse(option.query().sortBy.isEmpty) }
    }

    func testAlphabetIndexOnlyForAscendingNameSort() {
        var selection = SortSelection(AlbumSortOption.name)
        XCTAssertTrue(selection.showsAlphabetIndex)
        selection.select(.name) // same option again flips direction
        XCTAssertEqual(selection.direction, .descending)
        XCTAssertFalse(selection.showsAlphabetIndex)
        selection.select(.year)
        XCTAssertEqual(selection.direction, .descending)
        XCTAssertFalse(selection.showsAlphabetIndex)
        selection.select(.random)
        selection.select(.random)
        XCTAssertEqual(selection.direction, .ascending, "random has no direction to flip")
    }
}

// MARK: - Album presentation

final class AlbumPresentationTests: XCTestCase {
    func testSingleDiscOrdersByTrackNumberWithoutHeaders() {
        let tracks = [track("c", index: 3), track("a", index: 1), track("x"), track("b", index: 2)]
        let sections = AlbumPresentation.discSections(tracks)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].tracks.map(\.id), ["a", "b", "c", "x"])
        XCTAssertFalse(AlbumPresentation.showsDiscHeaders(sections))
    }

    func testMultiDiscGroupsAndTreatsMissingDiscAsOne() {
        let tracks = [
            track("d2t1", index: 1, disc: 2), track("d1t2", index: 2, disc: 1),
            track("nodisc", index: 1), track("d2t2", index: 2, disc: 2),
        ]
        let sections = AlbumPresentation.discSections(tracks)
        XCTAssertEqual(sections.map(\.disc), [1, 2])
        XCTAssertEqual(sections[0].tracks.map(\.id), ["nodisc", "d1t2"])
        XCTAssertEqual(sections[1].tracks.map(\.id), ["d2t1", "d2t2"])
        XCTAssertTrue(AlbumPresentation.showsDiscHeaders(sections))
        XCTAssertEqual(AlbumPresentation.playbackOrder(sections).map(\.id), ["nodisc", "d1t2", "d2t1", "d2t2"])
    }

    func testDuplicateTrackNumbersKeepServerOrder() {
        let sections = AlbumPresentation.discSections([track("first", index: 1), track("second", index: 1)])
        XCTAssertEqual(sections[0].tracks.map(\.id), ["first", "second"])
    }

    func testTrackNumberFallsBackToPosition() {
        XCTAssertEqual(AlbumPresentation.trackNumber(for: track("a", index: 7), positionInDisc: 0), 7)
        XCTAssertEqual(AlbumPresentation.trackNumber(for: track("a"), positionInDisc: 2), 3)
        XCTAssertEqual(AlbumPresentation.trackNumber(for: track("a", index: 0), positionInDisc: 0), 1)
    }

    func testCompilationShowsTrackArtists() {
        // The test library's "Jellyamp Sampler": album artist Various Artists.
        let sampler = [track("1", artist: "Aurora Drift"), track("2", artist: "Neon Circuit")]
        XCTAssertTrue(AlbumPresentation.showsTrackArtists(tracks: sampler, albumArtist: "Various Artists"))
        let plain = [track("1", artist: "Neon Circuit"), track("2", artist: " neon circuit ")]
        XCTAssertFalse(AlbumPresentation.showsTrackArtists(tracks: plain, albumArtist: "Neon Circuit"))
        let guest = [track("1", artist: "Neon Circuit"), track("2", artist: "Neon Circuit feat. X")]
        XCTAssertTrue(AlbumPresentation.showsTrackArtists(tracks: guest, albumArtist: "Neon Circuit"))
        XCTAssertFalse(AlbumPresentation.showsTrackArtists(tracks: [track("1", artist: "")], albumArtist: "A"))
    }

    func testMetadataLineSkipsUnknownParts() {
        XCTAssertEqual(
            AlbumPresentation.metadataLine(year: 2021, genres: ["Electronic", "Pop"], trackCount: 3, duration: 900),
            "2021 · Electronic · 3 songs · 15 min"
        )
        XCTAssertEqual(AlbumPresentation.metadataLine(year: nil, genres: [], trackCount: 1, duration: nil), "1 song")
        XCTAssertEqual(AlbumPresentation.metadataLine(year: 0, genres: [" "], trackCount: 0, duration: 0), "")
    }

    func testTotalDurationIgnoresBrokenValues() {
        let tracks = [track("a", duration: 100), track("b", duration: .nan), track("c", duration: -5), track("d", duration: 20)]
        XCTAssertEqual(AlbumPresentation.totalDuration(tracks), 120)
    }

    func testDiscographySplitsAndSortsByYear() {
        let releases = [
            Album(id: "old", title: "Old", artistName: "X", productionYear: 1994, trackCount: 10),
            Album(id: "single", title: "Single", artistName: "X", productionYear: 2020, trackCount: 2),
            Album(id: "new", title: "New", artistName: "X", productionYear: 2021, trackCount: 9),
            Album(id: "unknownCount", title: "Unknown", artistName: "X", productionYear: 2000),
            Album(id: "noYear", title: "No Year", artistName: "X", trackCount: 8),
            Album(id: "sameYearB", title: "B", artistName: "X", productionYear: 2021, trackCount: 5),
        ]
        let discography = Discography(releases: releases)
        XCTAssertEqual(discography.albums.map(\.id), ["sameYearB", "new", "unknownCount", "old", "noYear"])
        XCTAssertEqual(discography.singlesAndEPs.map(\.id), ["single"])
        XCTAssertEqual(
            Discography.sortedByYear(releases, newestFirst: false).map(\.id).first, "old"
        )
    }
}

// MARK: - Durations

final class DurationTextTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(DurationText.clock(0), "0:00")
        XCTAssertEqual(DurationText.clock(5), "0:05")
        XCTAssertEqual(DurationText.clock(185), "3:05")
        XCTAssertEqual(DurationText.clock(59.6), "1:00")
        XCTAssertEqual(DurationText.clock(3723), "1:02:03")
        XCTAssertEqual(DurationText.clock(-3), "0:00")
        XCTAssertEqual(DurationText.clock(.nan), "0:00")
        XCTAssertEqual(DurationText.clock(.infinity), "0:00")
    }

    func testApproximate() {
        XCTAssertEqual(DurationText.approximate(45), "45 sec")
        XCTAssertEqual(DurationText.approximate(900), "15 min")
        XCTAssertEqual(DurationText.approximate(3580), "1 hr")
        XCTAssertEqual(DurationText.approximate(4320), "1 hr 12 min")
    }

    func testSpoken() {
        XCTAssertEqual(DurationText.spoken(185), "3 minutes, 5 seconds")
        XCTAssertEqual(DurationText.spoken(61), "1 minute, 1 second")
        XCTAssertEqual(DurationText.spoken(3600), "1 hour")
        XCTAssertEqual(DurationText.spoken(0), "0 seconds")
    }
}

// MARK: - A–Z index

final class AlphabetIndexTests: XCTestCase {
    func testLetters() {
        XCTAssertEqual(AlphabetIndex.letters.count, 27)
        XCTAssertEqual(AlphabetIndex.letters.first, "#")
        XCTAssertEqual(AlphabetIndex.letters.last, "Z")
    }

    func testSortKeyDropsLeadingArticleLikeJellyfin() {
        XCTAssertEqual(AlphabetIndex.sortKey(for: "The Granite Saints"), "granite saints")
        XCTAssertEqual(AlphabetIndex.sortKey(for: "A Perfect Circle"), "perfect circle")
        XCTAssertEqual(AlphabetIndex.sortKey(for: "The "), "the")
        XCTAssertEqual(AlphabetIndex.sortKey(for: "Theory"), "theory")
    }

    func testOffsetLookup() {
        XCTAssertEqual(AlphabetIndex.offsetLookup(forLetter: "#"), .start)
        XCTAssertEqual(AlphabetIndex.offsetLookup(forLetter: "L"), .countBelow("L"))
    }

    func testBinaryPrecedesMatchesServerCollation() {
        // Observed on Jellyfin 10.10.7 with sortBy=Name: "ZZ-Banana" < "zz-apple".
        XCTAssertTrue(AlphabetIndex.binaryPrecedes("ZZ-Banana", "zz-apple"))
        XCTAssertTrue(AlphabetIndex.binaryPrecedes("Adagio", "S"))
        XCTAssertFalse(AlphabetIndex.binaryPrecedes("Sampler Intro", "S"))
        XCTAssertFalse(AlphabetIndex.binaryPrecedes("apple", "S"), "lower case sorts after every capital")
    }

    func testFirstIndexBinarySearch() async {
        // The 34 song titles of the test library in server order.
        let titles = [
            "Adagio", "Allegro in D", "Arc Flash", "Blast Line", "Clock In", "Dead Reckoning", "Dust and Diesel",
            "Encore", "Finale", "Gravel Road", "Gridlock", "Harbour Lights", "Hard Hat Blues", "Last Bus Home",
            "Last Call", "Meridian", "Morning Fog", "Overclock", "Overtime", "Persistence", "Phosphor", "Polaris",
            "Power On", "Rain on Ninth", "Sampler Intro", "Sampler Outro", "Scanline", "Scherzo", "Set One",
            "Set Two", "Slow Train", "Slow Water", "Standby", "Tidal Sleep",
        ]
        var probes = 0
        func offset(of letter: String) async -> Int {
            await AlphabetIndex.firstIndex(count: titles.count) { index in
                probes += 1
                return AlphabetIndex.binaryPrecedes(titles[index], letter)
            }
        }
        let s = await offset(of: "S")
        XCTAssertEqual(s, 24)
        XCTAssertLessThanOrEqual(probes, 6, "log2(34) probes")
        let a = await offset(of: "A")
        XCTAssertEqual(a, 0)
        let n = await offset(of: "N") // no title starts with N → first one after it
        XCTAssertEqual(titles[n], "Overclock")
        let z = await offset(of: "Z")
        XCTAssertEqual(z, titles.count)
        let empty = await AlphabetIndex.firstIndex(count: 0) { _ in true }
        XCTAssertEqual(empty, 0)
    }
}

// MARK: - Search

final class SearchRankingTests: XCTestCase {
    func testMatchLevels() {
        XCTAssertEqual(SearchRanker.match(name: "Neon Circuit", query: "neon circuit"), .exact)
        XCTAssertEqual(SearchRanker.match(name: "The Granite Saints", query: "granite saints"), .exact)
        XCTAssertEqual(SearchRanker.match(name: "The Granite Saints", query: "gran"), .prefix)
        XCTAssertEqual(SearchRanker.match(name: "The Granite Saints", query: "the gr"), .prefix)
        XCTAssertEqual(SearchRanker.match(name: "The Granite Saints", query: "sai"), .wordPrefix)
        XCTAssertEqual(SearchRanker.match(name: "Overclock", query: "clock"), .contains)
        XCTAssertEqual(SearchRanker.match(name: "Rain on Ninth", query: "ninth rain"), .allWords)
        XCTAssertEqual(SearchRanker.match(name: "Édith", query: "edith"), .exact)
        XCTAssertEqual(SearchRanker.match(name: "Adagio", query: "xyz"), .none)
        XCTAssertEqual(SearchRanker.match(name: "Adagio", query: "  "), .none)
    }

    func testGroupsAreRankedButKeepServerOrderAmongEquals() {
        let tracks = [
            track("1", title: "Overclock"), track("2", title: "Clock In"), track("3", title: "Slow Clock"),
            track("4", title: "Unrelated", artist: "Clock DVA"),
        ]
        let results = SearchRanker.group(query: "clock", tracks: tracks, albums: [], artists: [], playlists: [])
        XCTAssertEqual(results.tracks.map(\.id), ["2", "3", "1", "4"])
        XCTAssertEqual(results.topResult, .track(tracks[1]))
    }

    func testTopResultPrefersArtistOnEqualMatch() {
        let artist = Artist(id: "ar", name: "Voltage")
        let album = Album(id: "al", title: "Voltage", artistName: "Neon Circuit")
        let song = track("t", title: "Voltage")
        let results = SearchRanker.group(query: "voltage", tracks: [song], albums: [album], artists: [artist], playlists: [])
        XCTAssertEqual(results.topResult, .artist(artist))
    }

    func testBetterMatchBeatsKindPriority() {
        let artist = Artist(id: "ar", name: "The Low Tide Band")
        let album = Album(id: "al", title: "Low Tide", artistName: "Aurora Drift")
        let results = SearchRanker.group(query: "low tide", tracks: [], albums: [album], artists: [artist], playlists: [])
        XCTAssertEqual(results.topResult, .album(album))
    }

    func testEmptyResults() {
        let results = SearchRanker.group(query: "x", tracks: [], albums: [], artists: [], playlists: [])
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(results.topResult)
    }

    func testQueryPolicy() {
        XCTAssertNil(SearchQueryPolicy.effectiveQuery("   "))
        XCTAssertEqual(SearchQueryPolicy.effectiveQuery("  neon "), "neon")
    }

    func testRecentSearches() {
        var recents = RecentSearchList(limit: 3)
        recents.add("neon")
        recents.add("a") // too short
        recents.add("Granite")
        recents.add("NEON") // moves to front, replaces casing
        XCTAssertEqual(recents.terms, ["NEON", "Granite"])
        recents.add("one")
        recents.add("two")
        XCTAssertEqual(recents.terms, ["two", "one", "NEON"])
        recents.remove("One")
        XCTAssertEqual(recents.terms, ["two", "NEON"])
        recents.clear()
        XCTAssertTrue(recents.isEmpty)
    }

    func testRecentSearchesSanitizePersistedTerms() {
        let recents = RecentSearchList(terms: ["b2", "B2", " ", "a1", "x", "c3", "d4"], limit: 3)
        XCTAssertEqual(recents.terms, ["b2", "a1", "c3"])
    }
}

// MARK: - Playlist editing

final class PlaylistEditingTests: XCTestCase {
    func testRowIDsStayUniqueForRepeatedTracks() {
        let tracks = [
            track("t1", entry: "e1"), track("t1", entry: "e2"), // same track twice, distinct entries
            track("t2"), track("t2"), // no entry ids at all
            track("t3", entry: "e1"), // a repeated entry id must not collide either
        ]
        let rows = PlaylistEditing.rows(for: tracks)
        XCTAssertEqual(rows.map(\.id), ["e1", "e2", "t2#0", "t2#1", "t3#0"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testRemoving() {
        let tracks = [track("a", entry: "ea"), track("b"), track("c", entry: "ec")]
        let result = PlaylistEditing.removing(IndexSet([0, 1, 9]), from: tracks)
        XCTAssertEqual(result.remaining.map(\.id), ["c"])
        XCTAssertEqual(result.entryIDs, ["ea"])
    }

    func testMovingUsesOnMoveConvention() {
        let tracks = ["a", "b", "c", "d"].map { track($0) }
        XCTAssertEqual(PlaylistEditing.moving(tracks, from: 0, toOffset: 3)?.result.map(\.id), ["b", "c", "a", "d"])
        XCTAssertEqual(PlaylistEditing.moving(tracks, from: 0, toOffset: 3)?.finalIndex, 2)
        XCTAssertEqual(PlaylistEditing.moving(tracks, from: 3, toOffset: 0)?.result.map(\.id), ["d", "a", "b", "c"])
        XCTAssertEqual(PlaylistEditing.moving(tracks, from: 1, toOffset: 4)?.finalIndex, 3)
        XCTAssertNil(PlaylistEditing.moving(tracks, from: 1, toOffset: 1))
        XCTAssertNil(PlaylistEditing.moving(tracks, from: 1, toOffset: 2), "dropping a row onto itself")
        XCTAssertNil(PlaylistEditing.moving(tracks, from: 7, toOffset: 0))
    }

    func testSingleMoveDetection() {
        let current = ["a", "b", "c", "d", "e"]
        let down = PlaylistEditing.singleMove(from: current, to: ["a", "c", "d", "b", "e"])
        XCTAssertEqual(down?.id, "b")
        XCTAssertEqual(down?.from, 1)
        XCTAssertEqual(down?.to, 3)
        let up = PlaylistEditing.singleMove(from: current, to: ["e", "a", "b", "c", "d"])
        XCTAssertEqual(up?.id, "e")
        XCTAssertEqual(up?.to, 0)
        XCTAssertNil(PlaylistEditing.singleMove(from: current, to: current))
        XCTAssertNil(PlaylistEditing.singleMove(from: current, to: ["e", "d", "c", "b", "a"]))
        XCTAssertNil(PlaylistEditing.singleMove(from: current, to: ["a", "b"]))
    }

    func testLegacySimulationMatchesObservedServerBehaviour() {
        // Recorded against Jellyfin 10.10.7 (POST /Playlists/{id}/Items/{entry}/Move/{n}).
        let sim = PlaylistEditing.simulateLegacyServerMove
        XCTAssertEqual(sim(["Adagio", "Allegro", "Arc", "Blast"], "Blast", 0), ["Adagio", "Blast", "Allegro", "Arc"])
        XCTAssertEqual(sim(["Adagio", "Blast", "Allegro", "Arc"], "Adagio", 3), ["Blast", "Allegro", "Arc", "Adagio"])
        XCTAssertEqual(sim(["Blast", "Allegro", "Arc", "Adagio"], "Adagio", 2), ["Blast", "Allegro", "Adagio", "Arc"])
        XCTAssertEqual(sim(["Blast", "Allegro", "Adagio", "Arc"], "Adagio", 1), ["Blast", "Adagio", "Allegro", "Arc"])
        XCTAssertEqual(sim(["Adagio", "Allegro", "Arc", "Blast"], "Arc", 0), ["Adagio", "Arc", "Allegro", "Blast"])
        XCTAssertEqual(sim(["Adagio", "Arc", "Allegro", "Blast"], "Adagio", 1), ["Arc", "Allegro", "Adagio", "Blast"])
        XCTAssertEqual(sim(["Arc", "Adagio", "Allegro", "Blast"], "Adagio", 0), ["Arc", "Adagio", "Allegro", "Blast"])
        // Requesting the current index is a no-op (the live reorder test
        // showed that "first row to index 0" does not swap the first two).
        XCTAssertEqual(sim(["Adagio", "Arc", "Allegro"], "Adagio", 0), ["Adagio", "Arc", "Allegro"])
        XCTAssertEqual(sim(["Adagio", "Arc", "Allegro"], "Adagio", 9), ["Arc", "Allegro", "Adagio"])
        XCTAssertEqual(sim(["Adagio", "Arc"], "missing", 1), ["Adagio", "Arc"])
    }

    func testNaturalRequestPlusCorrectionConvergesOnTheQuirkyServer() {
        // The app's flow: send Move/{finalIndex}, compare, then correct.
        for count in 2...7 {
            let start = (0..<count).map { "e\($0)" }
            for from in 0..<count {
                for to in 0..<count where to != from {
                    var desired = start
                    let moved = desired.remove(at: from)
                    desired.insert(moved, at: to)
                    var server = PlaylistEditing.simulateLegacyServerMove(start, id: moved, requestedIndex: to)
                    guard let corrections = PlaylistEditing.legacyMoveOperations(current: server, desired: desired) else {
                        return XCTFail("no correction for \(count) rows, \(from) → \(to)")
                    }
                    XCTAssertLessThanOrEqual(corrections.count, 2)
                    for operation in corrections {
                        server = PlaylistEditing.simulateLegacyServerMove(server, id: operation.entryID, requestedIndex: operation.index)
                    }
                    XCTAssertEqual(server, desired, "\(count) rows, \(from) → \(to)")
                }
            }
        }
    }

    func testLegacyOperationsReachEveryTargetOnTheQuirkyServer() {
        for count in 2...7 {
            let current = (0..<count).map { "e\($0)" }
            for from in 0..<count {
                for to in 0..<count where to != from {
                    var desired = current
                    let moved = desired.remove(at: from)
                    desired.insert(moved, at: to)
                    guard let operations = PlaylistEditing.legacyMoveOperations(current: current, desired: desired) else {
                        return XCTFail("no plan for \(count) rows, \(from) → \(to)")
                    }
                    XCTAssertLessThanOrEqual(operations.count, 3)
                    var server = current
                    for operation in operations {
                        server = PlaylistEditing.simulateLegacyServerMove(server, id: operation.entryID, requestedIndex: operation.index)
                    }
                    XCTAssertEqual(server, desired, "\(count) rows, \(from) → \(to), ops \(operations)")
                }
            }
        }
    }

    func testLegacyOperationsForIdenticalOrUnrelatedOrders() {
        XCTAssertEqual(PlaylistEditing.legacyMoveOperations(current: ["a", "b"], desired: ["a", "b"]), [])
        XCTAssertNil(PlaylistEditing.legacyMoveOperations(current: ["a", "b", "c", "d"], desired: ["d", "c", "b", "a"]))
    }
}

// MARK: - Favorites, grid, accessibility

final class BrowseSupportTests: XCTestCase {
    func testFavoriteOverridesLayerOverServerValues() {
        var overrides = FavoriteOverrides()
        XCTAssertTrue(overrides.isFavorite("x", serverValue: true))
        overrides.set("x", isFavorite: false)
        XCTAssertFalse(overrides.isFavorite("x", serverValue: true))
        XCTAssertEqual(overrides.revision, 1)
        overrides.restore("x", previous: nil) // the server call failed
        XCTAssertTrue(overrides.isFavorite("x", serverValue: true))
        overrides.set("y", isFavorite: true)
        overrides.restore("y", previous: false)
        XCTAssertFalse(overrides.isFavorite("y", serverValue: true))
        overrides.reset()
        XCTAssertTrue(overrides.values.isEmpty)
    }

    func testGridMinimumItemWidthGrowsAtAccessibilitySizes() {
        XCTAssertEqual(AdaptiveGrid.minimumItemWidth(isAccessibilitySize: false), 150)
        XCTAssertEqual(AdaptiveGrid.minimumItemWidth(isAccessibilitySize: true), 270)
        XCTAssertEqual(AdaptiveGrid.minimumItemWidth(base: 100, isAccessibilitySize: true), 180)
        XCTAssertEqual(AdaptiveGrid.readableContentWidth, 720)
    }

    func testAccessibilitySummaries() {
        let song = track("1", title: "Phosphor", artist: "Neon Circuit", album: "Afterimage", duration: 300)
        XCTAssertEqual(AccessibilityText.trackRow(song), "Phosphor, Neon Circuit, 5 minutes")
        XCTAssertEqual(
            AccessibilityText.trackRow(song, showsArtist: false, showsAlbum: true, trackNumber: 1),
            "Track 1, Phosphor, Afterimage, 5 minutes"
        )
        XCTAssertEqual(AccessibilityText.trackRow(song, detail: "Neon Circuit · Afterimage"), "Phosphor, Neon Circuit · Afterimage, 5 minutes")
        XCTAssertEqual(AccessibilityText.trackRow(song, detail: ""), "Phosphor, 5 minutes")
        let album = Album(id: "a", title: "Afterimage", artistName: "Neon Circuit", productionYear: 2021)
        XCTAssertEqual(AccessibilityText.album(album), "Afterimage, Neon Circuit, 2021")
        XCTAssertEqual(AccessibilityText.playlist(Playlist(id: "p", name: "Mix", trackCount: 1)), "Mix, 1 song")
    }

    func testPlayQueueWindow() {
        let small = PlayQueueWindow.around(index: 3, count: 10)
        XCTAssertEqual(small.range, 0..<10)
        XCTAssertEqual(small.startAt, 3)
        let middle = PlayQueueWindow.around(index: 5_000, count: 50_000)
        XCTAssertEqual(middle.range, 4_900..<5_401)
        XCTAssertEqual(middle.startAt, 100)
        let end = PlayQueueWindow.around(index: 49_999, count: 50_000)
        XCTAssertEqual(end.range, 49_899..<50_000)
        XCTAssertEqual(end.startAt, 100)
        XCTAssertEqual(PlayQueueWindow.around(index: 99, count: 0).range, 0..<0)
        XCTAssertEqual(PlayQueueWindow.around(index: 99, count: 5).startAt, 4, "out-of-range index is clamped")

        let tracks = (0..<1_000).map { track("t\($0)") }
        let queue = PlayQueueWindow.queue(from: tracks, tappedIndex: 700)
        XCTAssertEqual(queue?.currentTrack?.id, "t700")
        XCTAssertNil(PlayQueueWindow.queue(from: [], tappedIndex: 0))
    }

    func testStableHueIsDeterministicAndInRange() {
        XCTAssertEqual(StableColor.hue(for: "Ambient"), StableColor.hue(for: "ambient"))
        XCTAssertNotEqual(StableColor.hue(for: "Ambient"), StableColor.hue(for: "Rock"))
        for name in ["", "Jazz", "Électronique", "ロック"] {
            let hue = StableColor.hue(for: name)
            XCTAssertTrue(hue >= 0 && hue < 1)
        }
        // Pinned so a refactor cannot silently recolor every genre tile.
        XCTAssertEqual(StableColor.hue(for: "Jazz"), Double(fnv("jazz") % 360) / 360)
    }

    private func fnv(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}
