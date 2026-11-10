import XCTest
@testable import JellyampCore

final class CarPlayListBuilderTests: XCTestCase {
    private func track(
        _ id: String,
        title: String? = nil,
        artist: String = "Artist",
        album: String? = "Album",
        albumID: String? = "album-1",
        index: Int? = nil,
        disc: Int? = nil,
        duration: TimeInterval = 187
    ) -> Track {
        Track(
            id: id,
            title: title ?? "Track \(id)",
            artistName: artist,
            albumName: album,
            albumID: albumID,
            indexNumber: index,
            discNumber: disc,
            duration: duration
        )
    }

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { track("t\($0)") }
    }

    private func allItems(_ model: CarPlayListModel) -> [CarPlayItem] {
        model.sections.flatMap(\.items)
    }

    // MARK: Home

    func testHomeSectionsFollowAvailableContent() {
        let builder = CarPlayListBuilder()
        let mix = MixDescriptor(id: "m1", title: "Daily Mix", itemIDs: ["a", "b"])
        let album = Album(id: "al1", title: "Blue", artistName: "Joni Mitchell", productionYear: 1971, imageTag: "tag")

        let full = builder.home(mixes: [mix], recentAlbums: [album], recentTracks: tracks(2))
        XCTAssertEqual(full.sections.map(\.header), ["Quick Play", "Mixes for You", "Recently Added", "Recently Played"])
        XCTAssertEqual(full.sections[1].items[0].action, .playMix(id: "m1"))
        XCTAssertEqual(full.sections[1].items[0].subtitle, "2 songs")
        XCTAssertEqual(full.sections[2].items[0].subtitle, "Joni Mitchell · 1971")
        XCTAssertEqual(full.sections[2].items[0].artwork, CarPlayArtworkRef(itemID: "al1", imageTag: "tag"))
        XCTAssertEqual(full.sections[2].items[0].action, .browse(.album(id: "al1", title: "Blue")))
        XCTAssertTrue(full.sections[2].items[0].showsDisclosure)
        XCTAssertEqual(full.sections[3].items[1].action, .playTrack(index: 1))
        XCTAssertEqual(full.sections[3].items[1].trackID, "t1")

        // No mixes capability → no mixes section.
        let plain = builder.home(mixes: [], recentAlbums: [album], recentTracks: [])
        XCTAssertEqual(plain.sections.map(\.header), ["Quick Play", "Recently Added"])
    }

    func testHomeWithoutContentShowsHintInsteadOfLonelyButton() {
        let model = CarPlayListBuilder().home(mixes: [], recentAlbums: [], recentTracks: [])
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyTitle, "Nothing Here Yet")
        XCTAssertNotNil(model.emptySubtitle)
    }

    // MARK: Library

    func testLibraryRootListsAllBranches() {
        let model = CarPlayListBuilder().libraryRoot()
        XCTAssertEqual(allItems(model).map(\.action), [
            .browse(.artists), .browse(.albums), .browse(.playlists), .browse(.likedSongs), .browse(.genres),
        ])
        XCTAssertTrue(allItems(model).allSatisfy(\.showsDisclosure))
    }

    func testShortArtistListIsFlatAndSortedIgnoringArticles() {
        let artists = ["The Beatles", "ABBA", "Zappa", "Björk"].map { Artist(id: $0, name: $0) }
        let model = CarPlayListBuilder().artists(artists)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertNil(model.sections[0].indexTitle)
        XCTAssertEqual(allItems(model).map(\.title), ["ABBA", "The Beatles", "Björk", "Zappa"])
        XCTAssertFalse(model.isTruncated)
    }

    func testLongArtistListGetsLetterSections() {
        var artists: [Artist] = []
        for letter in ["A", "B", "C", "D"] {
            for index in 0..<12 {
                artists.append(Artist(id: "\(letter)\(index)", name: "\(letter)lpha Band \(index)"))
            }
        }
        artists.append(Artist(id: "num", name: "2Pac"))
        artists.append(Artist(id: "the", name: "The Cure"))
        let limits = CarPlayLimits(maximumItemCount: 500, maximumSectionCount: 30)
        let model = CarPlayListBuilder(limits: limits).artists(artists.shuffled())
        XCTAssertEqual(model.sections.map(\.indexTitle), ["#", "A", "B", "C", "D"])
        XCTAssertEqual(model.sections[0].items.map(\.title), ["2Pac"])
        // "The Cure" files under C.
        XCTAssertTrue(model.sections[3].items.contains { $0.title == "The Cure" })
        XCTAssertEqual(model.itemCount, artists.count)
    }

    func testAlphabeticalListFallsBackToFlatWhenSectionsExceedLimit() {
        let names = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { "\($0)x Artist" } + (0..<20).map { "Ax Group \($0)" }
        let artists = names.map { Artist(id: $0, name: $0) }
        let limits = CarPlayLimits(maximumItemCount: 500, maximumSectionCount: 10)
        let model = CarPlayListBuilder(limits: limits).artists(artists)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertEqual(model.itemCount, artists.count)
    }

    func testAlphabeticalListIsCutToItemLimit() {
        let albums = (0..<150).map { Album(id: "a\($0)", title: String(format: "Album %03d", $0), artistName: "X") }
        let limits = CarPlayLimits(maximumItemCount: 100, maximumSectionCount: 30)
        let model = CarPlayListBuilder(limits: limits).albums(albums)
        XCTAssertEqual(model.itemCount, 100)
        XCTAssertTrue(model.isTruncated)
        XCTAssertEqual(allItems(model).first?.title, "Album 000")
        XCTAssertEqual(allItems(model).last?.title, "Album 099")
    }

    func testArtistDetailSortsAlbumsNewestFirst() {
        let albums = [
            Album(id: "1", title: "First", artistName: "X", productionYear: 1990),
            Album(id: "2", title: "Undated", artistName: "X"),
            Album(id: "3", title: "Latest", artistName: "X", productionYear: 2020),
        ]
        let model = CarPlayListBuilder().artistDetail(name: "X", albums: albums)
        XCTAssertEqual(model.title, "X")
        XCTAssertEqual(model.sections[0].items.map(\.action), [.shuffleAll, .startRadio])
        XCTAssertEqual(model.sections[1].items.map(\.title), ["Latest", "First", "Undated"])
        XCTAssertEqual(model.sections[1].items.map(\.subtitle), ["2020", "1990", nil])
    }

    func testPlaylistsAndGenres() {
        let builder = CarPlayListBuilder()
        let playlists = builder.playlists([
            Playlist(id: "p2", name: "Workout", trackCount: 1),
            Playlist(id: "p1", name: "chill", trackCount: 12),
            Playlist(id: "p3", name: "Mystery"),
        ])
        XCTAssertEqual(allItems(playlists).map(\.title), ["chill", "Mystery", "Workout"])
        XCTAssertEqual(allItems(playlists).map(\.subtitle), ["12 songs", nil, "1 song"])

        let genres = builder.genres([Genre(id: "g1", name: "Rock"), Genre(id: "g0", name: ""), Genre(id: "g2", name: "Ambient")])
        XCTAssertEqual(allItems(genres).map(\.title), ["Ambient", "Rock"])
        XCTAssertEqual(allItems(genres)[1].action, .browse(.genre(id: "g1", name: "Rock")))
    }

    // MARK: Track lists

    func testTrackListStylesAndActions() {
        let builder = CarPlayListBuilder()
        let list = [track("a", artist: "Miles Davis", album: "Kind of Blue", duration: 545), track("b", artist: "", album: nil)]

        let album = builder.trackList(title: "Kind of Blue", tracks: list, style: .album)
        XCTAssertEqual(album.sections[0].items.map(\.action), [.playAll, .shuffleAll])
        XCTAssertEqual(album.sections[1].header, "2 songs")
        XCTAssertEqual(album.sections[1].items[0].subtitle, "Miles Davis · 9:05")
        XCTAssertEqual(album.sections[1].items[1].subtitle, "3:07")
        XCTAssertEqual(album.sections[1].items[1].action, .playTrack(index: 1))

        let mixed = builder.trackList(title: "Rock", tracks: list, style: .mixed, includeRadio: true)
        XCTAssertEqual(mixed.sections[0].items.map(\.action), [.playAll, .shuffleAll, .startRadio])
        XCTAssertEqual(mixed.sections[1].items[0].subtitle, "Miles Davis — Kind of Blue")
        XCTAssertNil(mixed.sections[1].items[1].subtitle)
    }

    func testEmptyTrackListHasNoActionRows() {
        let model = CarPlayListBuilder().trackList(title: "Liked Songs", tracks: [], style: .mixed, emptyTitle: "No Liked Songs")
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyTitle, "No Liked Songs")
    }

    func testTrackListTruncationKeepsActionsAndIndexes() {
        let limits = CarPlayLimits(maximumItemCount: 10, maximumSectionCount: 5)
        let model = CarPlayListBuilder(limits: limits).trackList(title: "Big", tracks: tracks(50), style: .mixed)
        XCTAssertEqual(model.itemCount, 10)
        XCTAssertTrue(model.isTruncated)
        XCTAssertEqual(model.sections[0].items.count, 2)
        XCTAssertEqual(model.sections[1].items.count, 8)
        // Header still tells the real size; indexes address the full list.
        XCTAssertEqual(model.sections[1].header, "50 songs")
        XCTAssertEqual(model.sections[1].items.last?.action, .playTrack(index: 7))
    }

    func testDuplicateTracksGetUniqueRowIDs() {
        let same = track("dup")
        let model = CarPlayListBuilder().trackList(title: "Playlist", tracks: [same, same], style: .mixed)
        let ids = allItems(model).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testSectionLimitDropsTrailingSections() {
        let limits = CarPlayLimits(maximumItemCount: 100, maximumSectionCount: 2)
        let album = Album(id: "al", title: "A", artistName: "B")
        let mix = MixDescriptor(id: "m", title: "Mix", itemIDs: [])
        let model = CarPlayListBuilder(limits: limits).home(mixes: [mix], recentAlbums: [album], recentTracks: tracks(3))
        XCTAssertEqual(model.sections.map(\.header), ["Quick Play", "Mixes for You"])
        XCTAssertTrue(model.isTruncated)
    }

    func testLimitsAreNeverBelowOne() {
        let limits = CarPlayLimits(maximumItemCount: 0, maximumSectionCount: -3)
        XCTAssertEqual(limits.maximumItemCount, 1)
        XCTAssertEqual(limits.maximumSectionCount, 1)
    }

    // MARK: Downloads

    func testDownloadsGroupByAlbum() {
        let downloaded = [
            track("1", artist: "B", album: "Zeta", albumID: "z"),
            track("2", artist: "A", album: "Alpha", albumID: "a"),
            track("3", artist: "B", album: "Zeta", albumID: "z"),
            track("4", artist: "C", album: nil, albumID: nil),
        ]
        let model = CarPlayListBuilder().downloads(tracks: downloaded)
        XCTAssertEqual(model.sections[0].items.map(\.action), [.shuffleAll])
        XCTAssertEqual(model.sections[1].items.map(\.title), ["Alpha", "Unknown Album", "Zeta"])
        XCTAssertEqual(model.sections[1].items[2].subtitle, "B · 2 songs")
        XCTAssertEqual(model.sections[1].items[2].action, .browse(.downloadedAlbum(key: "id:z", title: "Zeta")))
        XCTAssertEqual(model.sections[1].items[1].action, .browse(.downloadedAlbum(key: "none", title: "Unknown Album")))
    }

    func testDownloadsEmptyState() {
        let model = CarPlayListBuilder().downloads(tracks: [])
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyTitle, "No Downloads")
    }

    func testDownloadedTracksAreInDiscAndTrackOrder() {
        let downloaded = [
            track("c", albumID: "z", index: 1, disc: 2),
            track("b", albumID: "z", index: 2, disc: 1),
            track("x", albumID: "other", index: 1, disc: 1),
            track("a", albumID: "z", index: 1, disc: nil),
        ]
        let result = CarPlayListBuilder.downloadedTracks(in: downloaded, groupKey: "id:z")
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    // MARK: Queue, signed out, formatting, navigation

    func testQueuePage() {
        let builder = CarPlayListBuilder()
        let current = track("now")
        let model = builder.queue(current: current, upNext: [track("n1"), track("now")])
        XCTAssertEqual(model.sections.map(\.header), ["Now Playing", "Up Next"])
        XCTAssertEqual(model.sections[0].items[0].action, CarPlayAction.none)
        XCTAssertEqual(model.sections[0].items[0].trackID, "now")
        XCTAssertEqual(model.sections[1].items.map(\.action), [.jumpToUpNext(index: 0), .jumpToUpNext(index: 1)])
        // A later copy of the playing song must not show the indicator.
        XCTAssertEqual(model.sections[1].items.map(\.trackID), [nil, nil])

        let empty = builder.queue(current: nil, upNext: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.emptyTitle, "Nothing Queued")
    }

    func testSignedOutIsASingleInformationalPage() {
        let model = CarPlayListBuilder().signedOut()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyTitle, "Not Signed In")
        XCTAssertNotNil(model.emptySubtitle)
    }

    func testCustomStringsAreUsed() {
        var strings = CarPlayStrings()
        strings.library = "Mediathek"
        strings.songCount = { "\($0) Titel" }
        let builder = CarPlayListBuilder(strings: strings)
        XCTAssertEqual(builder.libraryRoot().title, "Mediathek")
        XCTAssertEqual(builder.trackList(title: "X", tracks: tracks(3), style: .mixed).sections[1].header, "3 Titel")
    }

    func testFormatDuration() {
        XCTAssertEqual(CarPlayListBuilder.formatDuration(0), "0:00")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(-5), "0:00")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(.nan), "0:00")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(7), "0:07")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(187.4), "3:07")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(3765), "1:02:45")
    }

    func testNavigationPlanRespectsDepthLimit() {
        XCTAssertEqual(CarPlayNavigation.plan(stackDepth: 1), .push)
        XCTAssertEqual(CarPlayNavigation.plan(stackDepth: 4), .push)
        XCTAssertEqual(CarPlayNavigation.plan(stackDepth: 5), .popToRootThenPush)
        XCTAssertEqual(CarPlayNavigation.plan(stackDepth: 4, pushCount: 2), .popToRootThenPush)
        XCTAssertEqual(CarPlayNavigation.plan(stackDepth: 3, pushCount: 2), .push)
    }
}
