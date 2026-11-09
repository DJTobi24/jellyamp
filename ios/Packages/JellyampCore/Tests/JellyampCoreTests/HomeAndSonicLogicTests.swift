import XCTest
@testable import JellyampCore

private func track(_ id: String, album: String? = nil, artist: String = "Artist") -> Track {
    Track(id: id, title: "Title \(id)", artistName: artist, albumName: album.map { "Album \($0)" }, albumID: album, duration: 100)
}

final class HomeGreetingTests: XCTestCase {
    func testBucketsByHour() {
        XCTAssertEqual(HomeGreeting.bucket(forHour: 5), .morning)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 11), .morning)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 12), .afternoon)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 17), .afternoon)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 18), .evening)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 21), .evening)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 22), .night)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 0), .night)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 4), .night)
    }

    func testOutOfRangeHoursWrap() {
        XCTAssertEqual(HomeGreeting.bucket(forHour: 24), .night)
        XCTAssertEqual(HomeGreeting.bucket(forHour: 33), .morning)
        XCTAssertEqual(HomeGreeting.bucket(forHour: -1), .night)
    }

    func testBucketFromDateUsesCalendarTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-01-01 08:00:00 UTC
        let date = Date(timeIntervalSince1970: 1_767_254_400)
        XCTAssertEqual(HomeGreeting.bucket(for: date, calendar: calendar), .morning)
        calendar.timeZone = TimeZone(secondsFromGMT: 12 * 3600)!
        XCTAssertEqual(HomeGreeting.bucket(for: date, calendar: calendar), .evening)
    }
}

final class HomeShelvesTests: XCTestCase {
    func testJumpBackInDerivesDistinctAlbumsInRecencyOrder() {
        let recent = [track("1", album: "b"), track("2", album: "a"), track("3", album: "b"), track("4"), track("5", album: "c")]
        let albums = HomeShelves.jumpBackInAlbums(fromRecentTracks: recent)
        XCTAssertEqual(albums.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(albums[0].title, "Album b")
        XCTAssertEqual(albums[0].artistName, "Artist")
    }

    func testJumpBackInHonorsLimit() {
        let recent = (1...10).map { track("\($0)", album: "album\($0)") }
        XCTAssertEqual(HomeShelves.jumpBackInAlbums(fromRecentTracks: recent, limit: 3).count, 3)
        XCTAssertTrue(HomeShelves.jumpBackInAlbums(fromRecentTracks: recent, limit: 0).isEmpty)
    }

    func testUniquedKeepsFirstOccurrence() {
        let tracks = [track("1"), track("2"), track("1")]
        XCTAssertEqual(HomeShelves.uniqued(tracks).map(\.id), ["1", "2"])
    }

    func testContentStateResolution() {
        XCTAssertEqual(HomeContentState.resolve(hasAnyContent: true, hasFinishedRefresh: false, anyRequestSucceeded: false), .content)
        XCTAssertEqual(
            HomeContentState.resolve(hasAnyContent: false, hasFinishedRefresh: false, anyRequestSucceeded: false),
            .loadingFirstTime
        )
        XCTAssertEqual(
            HomeContentState.resolve(hasAnyContent: false, hasFinishedRefresh: true, anyRequestSucceeded: true),
            .emptyLibrary
        )
        XCTAssertEqual(
            HomeContentState.resolve(hasAnyContent: false, hasFinishedRefresh: true, anyRequestSucceeded: false),
            .unreachable
        )
    }
}

final class AdventureTests: XCTestCase {
    func testValidationReportsWhatIsMissing() {
        XCTAssertEqual(AdventureRequest.validate(startID: nil, endID: "b", steps: 10), .failure(.missingStart))
        XCTAssertEqual(AdventureRequest.validate(startID: "a", endID: nil, steps: 10), .failure(.missingEnd))
        XCTAssertEqual(AdventureRequest.validate(startID: "a", endID: "", steps: 10), .failure(.missingEnd))
        XCTAssertEqual(AdventureRequest.validate(startID: "a", endID: "a", steps: 10), .failure(.sameTrack))
    }

    func testValidRequestClampsSteps() throws {
        let request = try AdventureRequest.validate(startID: "a", endID: "b", steps: 500).get()
        XCTAssertEqual(request.steps, 50)
        XCTAssertEqual(request.expectedTrackCount, 52)
        XCTAssertEqual(AdventureRequest(startID: "a", endID: "b", steps: 1).steps, 5)
        XCTAssertTrue(AdventureRequest.stepChoices.allSatisfy(AdventureRequest.allowedSteps.contains))
        XCTAssertTrue(AdventureRequest.stepChoices.contains(AdventureRequest.defaultSteps))
    }

    func testPathKeepsEndpointsAndDropsDuplicates() {
        let request = AdventureRequest(startID: "a", endID: "z", steps: 5)
        XCTAssertEqual(
            AdventurePath.normalizedIDs(["a", "m1", "m2", "m1", "z"], request: request),
            ["a", "m1", "m2", "z"]
        )
        // Server omitted the endpoints / returned the end early.
        XCTAssertEqual(AdventurePath.normalizedIDs(["m1", "z", "m2"], request: request), ["a", "m1", "m2", "z"])
        XCTAssertEqual(AdventurePath.normalizedIDs([], request: request), ["a", "z"])
    }

    func testOrderedTracksFollowPathAndSkipUnresolved() {
        let resolved = [track("z"), track("a"), track("m2")]
        XCTAssertEqual(AdventurePath.orderedTracks(resolved, alongIDs: ["a", "m1", "m2", "z"]).map(\.id), ["a", "m2", "z"])
    }

    func testPlaylistNameAndDuration() {
        XCTAssertEqual(
            AdventurePath.defaultPlaylistName(start: track("1"), end: track("2")),
            "Adventure: Title 1 \u{2192} Title 2"
        )
        XCTAssertEqual(AdventurePath.totalDuration(of: [track("1"), track("2")]), 200, accuracy: 1e-9)
    }
}

final class SimilarRankingTests: XCTestCase {
    func testOrdersByDistanceExcludesSeedAndDuplicates() {
        let results: [(itemID: String, distance: Double)] = [
            ("c", 0.3), ("seed", 0.0), ("a", 0.1), ("b", 0.2), ("a", 0.4),
        ]
        XCTAssertEqual(SimilarRanking.orderedIDs(from: results, excluding: "seed", limit: 10), ["a", "b", "c"])
        XCTAssertEqual(SimilarRanking.orderedIDs(from: results, excluding: "seed", limit: 2), ["a", "b"])
        XCTAssertTrue(SimilarRanking.orderedIDs(from: results, excluding: "seed", limit: 0).isEmpty)
    }

    func testTiesKeepProviderOrder() {
        let results: [(itemID: String, distance: Double)] = [("x", 1), ("y", 1), ("z", 1)]
        XCTAssertEqual(SimilarRanking.orderedIDs(from: results, excluding: "", limit: 5), ["x", "y", "z"])
    }

    func testOrderedResolvesInRankOrder() {
        let albums = [Album(id: "2", title: "Two", artistName: ""), Album(id: "1", title: "One", artistName: "")]
        XCTAssertEqual(SimilarRanking.ordered(albums, byIDs: ["1", "missing", "2"]).map(\.title), ["One", "Two"])
    }

    func testExcludingAlbum() {
        let tracks = [track("1", album: "same"), track("2", album: "other"), track("3")]
        XCTAssertEqual(SimilarRanking.excludingAlbum(tracks, albumID: "same").map(\.id), ["2", "3"])
        XCTAssertEqual(SimilarRanking.excludingAlbum(tracks, albumID: nil).count, 3)
    }
}

final class SonicServerConfigTests: XCTestCase {
    func testEmptyInputMeansNotConfigured() {
        XCTAssertEqual(SonicServerConfig.parseURL("   "), .empty)
    }

    func testAddsSchemeAndStripsTrailingSlashAndAPIPath() {
        XCTAssertEqual(SonicServerConfig.parseURL("server:8095"), .valid(URL(string: "http://server:8095")!))
        XCTAssertEqual(SonicServerConfig.parseURL(" 192.168.1.5:8095/ "), .valid(URL(string: "http://192.168.1.5:8095")!))
        XCTAssertEqual(
            SonicServerConfig.parseURL("HTTPS://sonic.example.com/base/api/v1/"),
            .valid(URL(string: "https://sonic.example.com/base")!)
        )
        XCTAssertEqual(
            SonicServerConfig.parseURL("http://host:8095/api/v1?x=1#frag"),
            .valid(URL(string: "http://host:8095")!)
        )
    }

    func testRejectsGarbageAndForeignSchemes() {
        XCTAssertEqual(SonicServerConfig.parseURL("ftp://host"), .invalid)
        XCTAssertEqual(SonicServerConfig.parseURL("not a url"), .invalid)
        XCTAssertEqual(SonicServerConfig.parseURL("http://"), .invalid)
    }

    func testInfoURL() {
        XCTAssertEqual(
            SonicServerConfig.infoURL(baseURL: URL(string: "http://host:8095")!).absoluteString,
            "http://host:8095/api/v1/info"
        )
    }

    func testVersionFromInfoBody() {
        let body = Data(#"{"version":"1.2","jellyfinServerId":"x","tracksTotal":1,"tracksAnalyzed":1,"capabilities":[]}"#.utf8)
        XCTAssertEqual(SonicServerConfig.version(fromInfoBody: body), "1.2")
        XCTAssertNil(SonicServerConfig.version(fromInfoBody: Data("{}".utf8)))
        XCTAssertNil(SonicServerConfig.version(fromInfoBody: Data("nope".utf8)))
    }

    func testAnalysisProgressSummary() {
        let partial = AnalysisProgressSummary(tracksAnalyzed: 12_034, tracksTotal: 12_500)
        XCTAssertEqual(partial.fraction, 0.96272, accuracy: 1e-5)
        XCTAssertEqual(partial.percent, 96)
        XCTAssertFalse(partial.isComplete)

        let almost = AnalysisProgressSummary(tracksAnalyzed: 999, tracksTotal: 1000)
        XCTAssertEqual(almost.percent, 99)

        let done = AnalysisProgressSummary(tracksAnalyzed: 10, tracksTotal: 10)
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(done.percent, 100)

        let empty = AnalysisProgressSummary(tracksAnalyzed: 0, tracksTotal: 0)
        XCTAssertEqual(empty.fraction, 1)
        XCTAssertTrue(empty.isComplete)

        XCTAssertEqual(AnalysisProgressSummary(tracksAnalyzed: 20, tracksTotal: 10).fraction, 1)
    }
}
