import XCTest
import Combine
import UIKit
import JellyampCore
import JellyfinBackend
import JellyfinDemo
import SonicClient
@testable import Jellyamp

/// Demo mode end to end inside the app process: the container signs in to
/// the built-in sample library through the loopback server, the screens'
/// view models load from it, and nothing leaks into the Keychain.
@MainActor
final class DemoModeTests: XCTestCase {
    private var container: DependencyContainer!
    private var storedSessionBefore: JellyfinSession?

    override func setUp() async throws {
        storedSessionBefore = KeychainCredentialStore().loadSession()
        container = DependencyContainer()
    }

    override func tearDown() async throws {
        if container.isSignedIn { container.signOut() }
        container = nil
        DemoMode.shared.stop()
    }

    private func enterDemo() async throws {
        // Signing in builds the audio engine.
        try AudioOutput.requireUsable()
        await container.enterDemoMode()
        guard container.isSignedIn else {
            throw XCTSkip("The demo server could not start: \(container.signedOutNotice ?? "no reason given")")
        }
    }

    func testEnteringTheDemoSignsInWithoutTouchingTheKeychain() async throws {
        XCTAssertFalse(container.isSignedIn)
        XCTAssertFalse(container.isDemoMode)

        try await enterDemo()

        XCTAssertTrue(container.isDemoMode)
        let session = try XCTUnwrap(container.session)
        XCTAssertEqual(session.serverURL.host, "127.0.0.1")
        XCTAssertEqual(session.serverURL.scheme, "http")
        XCTAssertEqual(session.userID, DemoCatalog.userID)
        XCTAssertEqual(container.account?.serverName, DemoCatalog.serverName)
        XCTAssertNotNil(container.library)
        XCTAssertNotNil(container.player)
        XCTAssertNotNil(container.downloads)
        XCTAssertNotNil(container.browser)

        // The demo session is never persisted: a real sign-in stays as it was.
        XCTAssertEqual(KeychainCredentialStore().loadSession(), storedSessionBefore)
        // Re-validating the "stored" session is a no-op in demo mode — it
        // would otherwise write the demo session to the Keychain.
        await container.validateStoredSession()
        XCTAssertEqual(KeychainCredentialStore().loadSession(), storedSessionBefore)
        XCTAssertTrue(container.isSignedIn)
    }

    func testTheDemoOffersTheSonicFeatures() async throws {
        try await enterDemo()
        XCTAssertTrue(container.isSonicServerActive)
        for capability in [SonicCapability.similar, .adventure, .mixes, .stations] {
            XCTAssertTrue(container.sonicCapabilities.supports(capability), "\(capability)")
        }
        let mixes = try await XCTUnwrap(container.sonic).mixes(forUser: DemoCatalog.userID)
        XCTAssertEqual(mixes.map(\.title), DemoFixture.mixTitles)
    }

    func testLibraryCallsReachTheDemoBackend() async throws {
        try await enterDemo()
        let library = try XCTUnwrap(container.library)
        let albums = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 100)
        XCTAssertEqual(albums.count, DemoFixture.albumCount)
        let tracks = try await library.tracks(inAlbum: DemoFixture.nightFerryAlbum)
        XCTAssertEqual(tracks.map(\.title), DemoFixture.nightFerryTitles)

        let browser = try XCTUnwrap(container.browser)
        let page = try await browser.tracksPage(sort: TrackSortOption.title.query(), filter: .none, startIndex: 0, limit: 10)
        XCTAssertEqual(page.items.count, 10)
        XCTAssertEqual(page.totalCount, DemoFixture.trackCount)

        let lyrics = try await library.lyrics(forTrack: DemoFixture.track(album: 3, number: 2))
        XCTAssertEqual(lyrics?.isSynced, true)
    }

    func testHomeLoadsItsShelvesFromTheDemoBackend() async throws {
        try await enterDemo()
        let home = HomeViewModel()
        await home.refresh(container: container)

        XCTAssertTrue(home.hasFinishedRefresh)
        XCTAssertTrue(home.anyRequestSucceeded)
        XCTAssertEqual(home.recentAlbums.first?.title, "Nocturnes in Glass")
        XCTAssertEqual(home.recentTracks.first?.title, "Night Ferry")
        XCTAssertFalse(home.favoriteAlbums.isEmpty)
        XCTAssertEqual(home.genres.count, DemoFixture.genreCount)
        XCTAssertFalse(home.years.isEmpty)
        XCTAssertFalse(home.jumpBackIn.isEmpty)
        XCTAssertEqual(home.mixes.map(\.title), DemoFixture.mixTitles)
    }

    func testArtworkAndAudioAreServedOverLoopback() async throws {
        try await enterDemo()
        let session = try XCTUnwrap(container.session)

        let imageURL = ImageURLBuilder.url(itemID: DemoFixture.nightFerryAlbum, tag: nil, maxWidth: 300, session: session)
        let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
        XCTAssertEqual((imageResponse as? HTTPURLResponse)?.statusCode, 200)
        let image = try XCTUnwrap(UIImage(data: imageData), "the generated cover is not an image UIKit can read")
        XCTAssertEqual(image.size.width * image.scale, 300)

        let trackID = DemoFixture.track(album: 3, number: 1)
        var probe = URLRequest(url: StreamURLBuilder.url(for: trackID, request: .directPlay, session: session))
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, audioResponse) = try await URLSession.shared.data(for: probe)
        let http = try XCTUnwrap(audioResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Range"))
    }

    func testSigningOutLeavesTheDemo() async throws {
        try await enterDemo()
        XCTAssertNotNil(DemoMode.shared.baseURL)
        XCTAssertTrue(DemoMode.shouldStartAtLaunch, "the demo is remembered until sign-out")

        container.signOut()

        XCTAssertFalse(container.isSignedIn)
        XCTAssertFalse(container.isDemoMode)
        XCTAssertNil(container.session)
        XCTAssertNil(container.library)
        XCTAssertNil(DemoMode.shared.baseURL)
        XCTAssertEqual(DemoMode.shouldStartAtLaunch, LaunchOptions.demo)
        XCTAssertEqual(KeychainCredentialStore().loadSession(), storedSessionBefore)

        // And back in again: the server restarts with a fresh library.
        try await enterDemo()
        XCTAssertTrue(container.isDemoMode)
    }
}

/// What the tests know about the demo library (`DemoCatalog` in the
/// JellyfinDemo package). Spelled out here instead of read from the package:
/// the test bundle links against the app, which only carries the package
/// symbols the app itself uses.
enum DemoFixture {
    static let albumCount = 12
    static let trackCount = 60
    static let genreCount = 6
    static let mixTitles = ["Ambient Mix", "Electronic Mix", "Jazz Mix", "Rock Mix"]
    /// "Night Ferry" by Neon Estuary.
    static let nightFerryAlbum = id("b", 3)
    static let nightFerryTitles = ["Departure Board", "Night Ferry", "Harbour Lights at 2 a.m.", "Tape Deck Heart", "Last Stop: Sunrise"]

    /// `album` and `number` are 1-based.
    static func track(album: Int, number: Int) -> String {
        id("c", album * 100 + number)
    }

    private static func id(_ kind: String, _ number: Int) -> String {
        let digits = String(number)
        return kind + String(repeating: "0", count: 32 - kind.count - digits.count) + digits
    }
}

final class PlayerStateModelTests: XCTestCase {
    func testChangesArePublished() {
        let model = PlayerStateModel()
        var cancellables: Set<AnyCancellable> = []
        var trackIDs: [String?] = []
        var playing: [Bool] = []
        var times: [TimeInterval] = []
        var changes = 0
        model.$currentTrack.sink { trackIDs.append($0?.id) }.store(in: &cancellables)
        model.$isPlaying.sink { playing.append($0) }.store(in: &cancellables)
        model.$currentTime.sink { times.append($0) }.store(in: &cancellables)
        model.objectWillChange.sink { changes += 1 }.store(in: &cancellables)

        let track = Track(id: "t1", title: "One", artistName: "A", duration: 100)
        model.currentTrack = track
        model.isPlaying = true
        model.currentTime = 12.5
        model.upNext = [Track(id: "t2", title: "Two", artistName: "A", duration: 90)]

        XCTAssertEqual(trackIDs, [nil, "t1"])
        XCTAssertEqual(playing, [false, true])
        XCTAssertEqual(times, [0, 12.5])
        XCTAssertEqual(changes, 4, "every assignment announces itself to SwiftUI")
        XCTAssertEqual(model.upNext.map(\.id), ["t2"])
    }

    func testInitialStateIsIdle() {
        let model = PlayerStateModel()
        XCTAssertNil(model.currentTrack)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertTrue(model.upNext.isEmpty)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.sleepTimerActive)
        XCTAssertFalse(model.isShuffled)
        XCTAssertEqual(model.repeatMode, .off)
        XCTAssertNil(model.quality)
    }
}
