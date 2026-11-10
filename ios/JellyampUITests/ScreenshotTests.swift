import XCTest

/// Captures the App Store screenshots from the demo library.
///
/// Every screenshot is attached to the test result under its file name
/// ("01-home", …) with `lifetime = .keepAlways`;
/// `scripts/ci/export-xcresult-attachments.py` pulls them out of the
/// `.xcresult` as PNGs. `bundle exec fastlane screenshots` (and the UI-test
/// workflow) run this class once per device and language.
///
/// The language comes from the environment: `SCREENSHOT_LANGUAGE=de-DE`,
/// passed to the test runner as `TEST_RUNNER_SCREENSHOT_LANGUAGE`. Default
/// is en-US.
///
/// If fastlane's own `SnapshotHelper.swift` is added to this target and the
/// target is compiled with the `FASTLANE_SNAPSHOT` condition, the same tests
/// feed fastlane's `capture_screenshots` instead (see `Screenshots` below).
final class ScreenshotTests: JellyampUITestCase {
    private func launchForScreenshots() {
        Screenshots.prepare(app)
        launch(language: Screenshots.launchLanguage)
    }

    private func capture(_ name: String) {
        // Covers are loaded asynchronously; give the last ones time to land.
        Thread.sleep(forTimeInterval: 2.5)
        Screenshots.capture(name, in: self)
    }

    func test01Home() {
        launchForScreenshots()
        waitFor(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)
        // Mixes for You fill in last; the shot is still worth taking without.
        _ = element(AccessibilityID.Home.mix(Demo.firstMix)).waitForExistence(timeout: 30)
        capture("01-home")
    }

    func test02Album() {
        launchForScreenshots()
        tap(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)
        waitFor(AccessibilityID.Item.track(Demo.track(album: 3, number: 5)), timeout: 30)
        capture("02-album")
    }

    func test03NowPlaying() {
        launchForScreenshots()
        startPlayback()
        openNowPlaying()
        // The visualizer is on by default (bars → wave → off): show the cover.
        tap(AccessibilityID.NowPlaying.visualizer)
        tap(AccessibilityID.NowPlaying.visualizer)
        waitFor(AccessibilityID.NowPlaying.artwork)
        // Let a few seconds play so the scrubber is not at zero.
        Thread.sleep(forTimeInterval: 4)
        capture("03-now-playing")
    }

    func test04Lyrics() {
        launchForScreenshots()
        startPlayback()
        openNowPlaying()
        tap(AccessibilityID.NowPlaying.next)
        waitForNowPlaying(title: "Night Ferry")
        tap(AccessibilityID.NowPlaying.lyrics)
        waitFor(AccessibilityID.Lyrics.line(0), timeout: 30)
        // Far enough into the song for a highlighted line.
        Thread.sleep(forTimeInterval: 6)
        capture("04-lyrics")
    }

    func test05Library() {
        launchForScreenshots()
        openLibrary("albums")
        waitFor(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)
        capture("05-library")
    }

    func test06Search() {
        launchForScreenshots()
        open(.search)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the Search screen has no search field")
        field.tap()
        field.typeText("night")
        waitFor(AccessibilityID.Item.track(Demo.nightFerry), timeout: 30)
        capture("06-search")
    }

    func test07Artist() {
        launchForScreenshots()
        openLibrary("artists")
        tap(AccessibilityID.Item.artist(Demo.artist(2)), timeout: 30)
        waitFor(AccessibilityID.Item.album(Demo.album(3)), timeout: 30)
        capture("07-artist")
    }

    func test08Downloads() {
        launchForScreenshots()
        openLibrary("albums")
        tap(AccessibilityID.Item.album(Demo.nightFerryAlbum), timeout: 30)
        waitFor(AccessibilityID.Item.track(Demo.departureBoard), timeout: 30)
        tap(AccessibilityID.Collection.download)
        open(.downloads)
        // A finished album is the better picture; a running transfer still
        // shows the feature, so do not fail the shot over a slow simulator.
        _ = element(AccessibilityID.Downloads.collection(Demo.nightFerryAlbum)).waitForExistence(timeout: 120)
        capture("08-downloads")
    }
}

/// Where screenshots go. One place decides between the two ways of
/// harvesting them, so the tests above do not care.
enum Screenshots {
    /// Language to launch the app in, or nil when fastlane's helper has
    /// already put it into the launch arguments.
    static var launchLanguage: String? {
        #if FASTLANE_SNAPSHOT
        return nil
        #else
        let requested = ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] ?? ""
        return requested.isEmpty ? "en-US" : requested
        #endif
    }

    static func prepare(_ app: XCUIApplication) {
        #if FASTLANE_SNAPSHOT
        setupSnapshot(app)
        #endif
    }

    static func capture(_ name: String, in testCase: XCTestCase) {
        #if FASTLANE_SNAPSHOT
        snapshot(name)
        #else
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        #endif
    }
}
