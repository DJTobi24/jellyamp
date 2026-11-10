import XCTest
import UIKit

/// Base class of all UI tests.
///
/// Every test launches a fresh app in demo mode (`-JellyampDemo YES`): the
/// built-in sample library, no server, no network. State is reset on each
/// launch, so tests are independent and can run in any order.
///
/// Elements are found by accessibility identifier (`AccessibilityID`, the
/// same file the app compiles), never by their text: the app is localized
/// and labels change with the language. The few system-owned controls that
/// cannot carry an identifier (alert buttons) are matched by their English
/// label, which is why functional tests pin the app language to English.
class JellyampUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// IDs of the demo library (see `DemoCatalog` in the JellyfinDemo package).
    enum Demo {
        static func album(_ number: Int) -> String { id("b", number) }
        static func artist(_ number: Int) -> String { id("a", number) }
        /// `album` and `number` are 1-based.
        static func track(album: Int, number: Int) -> String { id("c", album * 100 + number) }
        static func playlist(_ number: Int) -> String { id("d", number) }
        /// The demo backend numbers playlists created at runtime from 101.
        static let firstCreatedPlaylist = id("d", 101)
        static let firstMix = "mix-demo-1"

        /// "Night Ferry" by Neon Estuary: recently played, favorite, has
        /// synced lyrics — the album most tests work with.
        static let nightFerryAlbum = album(3)
        static let departureBoard = track(album: 3, number: 1)
        static let nightFerry = track(album: 3, number: 2)
        /// "Afterglow Motel": first album alphabetically, not a favorite.
        static let afterglowMotelAlbum = album(10)
        /// "A Field Guide to Fog": first song alphabetically.
        static let firstSong = track(album: 2, number: 2)
        /// "Goodnight, Lighthouse", the only title containing "Lighthouse".
        static let lighthouse = track(album: 6, number: 5)

        private static func id(_ kind: String, _ number: Int) -> String {
            let digits = String(number)
            return kind + String(repeating: "0", count: 32 - kind.count - digits.count) + digits
        }
    }

    enum Section {
        case home, search, downloads, settings
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // iPad in landscape shows the sidebar next to the content; in
        // portrait the split view hides it behind a toolbar button.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Launch

    /// Launches the app from a clean slate.
    /// - Parameters:
    ///   - demo: signed in to the demo library (false: signed out, onboarding).
    ///   - language: BCP 47 language of the app, e.g. "en-US" or "de-DE";
    ///     nil leaves the language to whoever configured `app` before
    ///     (fastlane's snapshot helper).
    func launch(demo: Bool = true, language: String? = "en-US") {
        var arguments = ["-JellyampResetState", "YES", "-JellyampDisableAnimations", "YES"]
        if demo {
            arguments += ["-JellyampDemo", "YES"]
        }
        if let language {
            let parts = language.split(separator: "-").map(String.init)
            arguments += ["-AppleLanguages", "(\(parts[0]))"]
            arguments += ["-AppleLocale", parts.count > 1 ? "\(parts[0])_\(parts[1])" : parts[0]]
        }
        app.launchArguments += arguments
        app.launch()
        if demo {
            waitForShell()
        }
    }

    /// Waits until the signed-in shell (tab bar or sidebar) is on screen.
    func waitForShell(file: StaticString = #filePath, line: UInt = #line) {
        if isPad {
            waitFor(AccessibilityID.Sidebar.home, timeout: 40, file: file, line: line)
        } else {
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "the tab bar did not appear after launch", file: file, line: line)
        }
    }

    // MARK: - Finding elements

    /// The first element with this accessibility identifier, of any type.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// All elements whose identifier starts with `prefix` (identifiers that
    /// carry an item ID or a state: "album.<id>", "nowPlaying.playPause.playing").
    func elements(withPrefix prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "no element with identifier \"\(identifier)\" after \(Int(timeout)) s", file: file, line: line)
        return found
    }

    @discardableResult
    func waitForAny(prefix: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = elements(withPrefix: prefix).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "no element whose identifier starts with \"\(prefix)\" after \(Int(timeout)) s", file: file, line: line)
        return found
    }

    func waitForDisappearance(of identifier: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element(identifier))
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\"\(identifier)\" is still on screen after \(Int(timeout)) s", file: file, line: line)
    }

    /// Waits for the element and taps it. Elements inside scroll views are
    /// scrolled into view by XCUITest.
    func tap(_ identifier: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let target = waitFor(identifier, timeout: timeout, file: file, line: line)
        if target.isHittable {
            target.tap()
        } else {
            // Covered or clipped (a card under the mini player, a toolbar
            // item in an overflow): tap its centre directly.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    // MARK: - Navigation

    /// Switches to a top-level section through the tab bar or the sidebar.
    func open(_ section: Section, file: StaticString = #filePath, line: UInt = #line) {
        if isPad {
            switch section {
            case .home: tap(AccessibilityID.Sidebar.home, file: file, line: line)
            case .search: tap(AccessibilityID.Sidebar.search, file: file, line: line)
            case .downloads: tap(AccessibilityID.Sidebar.downloads, file: file, line: line)
            case .settings: tap(AccessibilityID.Sidebar.settings, file: file, line: line)
            }
        } else {
            switch section {
            case .home: tapTab(AccessibilityID.Tab.home, file: file, line: line)
            case .search: tapTab(AccessibilityID.Tab.search, file: file, line: line)
            case .downloads: tapTab(AccessibilityID.Tab.downloads, file: file, line: line)
            case .settings: tapTab(AccessibilityID.Tab.settings, file: file, line: line)
            }
        }
    }

    /// Opens one of the library lists ("albums", "artists", "songs",
    /// "playlists", "genres", "likedSongs", "savedAlbums", "following").
    func openLibrary(_ category: String, file: StaticString = #filePath, line: UInt = #line) {
        if isPad {
            tap(AccessibilityID.Sidebar.category(category), file: file, line: line)
        } else {
            tapTab(AccessibilityID.Tab.library, file: file, line: line)
            // Back to the Library root if a list is still open from before.
            let row = element(AccessibilityID.Library.category(category))
            var attempts = 0
            while !row.waitForExistence(timeout: 3), attempts < 4 {
                goBack()
                attempts += 1
            }
            tap(AccessibilityID.Library.category(category), file: file, line: line)
        }
    }

    private func tapTab(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "no tab bar", file: file, line: line)
        let button = bar.buttons.element(boundBy: index)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the tab bar has no item \(index)", file: file, line: line)
        button.tap()
    }

    /// Taps the back button of the content's navigation bar: the first
    /// button of the last bar (on iPad the sidebar has a bar of its own,
    /// which comes first).
    func goBack() {
        let bars = app.navigationBars
        guard bars.firstMatch.waitForExistence(timeout: 5) else { return }
        let back = bars.element(boundBy: max(bars.count - 1, 0)).buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
    }

    // MARK: - Player

    /// Starts playback of the first track of "Night Ferry" from Home and
    /// waits for the mini player.
    func startPlayback(file: StaticString = #filePath, line: UInt = #line) {
        tap(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40, file: file, line: line)
        tap(AccessibilityID.Item.track(Demo.departureBoard), timeout: 30, file: file, line: line)
        waitFor(AccessibilityID.MiniPlayer.open, timeout: 30, file: file, line: line)
    }

    func openNowPlaying(file: StaticString = #filePath, line: UInt = #line) {
        tap(AccessibilityID.MiniPlayer.open, file: file, line: line)
        waitFor(AccessibilityID.NowPlaying.close, timeout: 20, file: file, line: line)
    }

    /// Waits until the Now Playing screen shows the track with this title.
    /// Titles are library data, not localized text.
    func waitForNowPlaying(title: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let info = waitFor(AccessibilityID.NowPlaying.trackInfo, file: file, line: line)
        let shows = NSPredicate(format: "label CONTAINS %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: shows, object: info)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Now Playing shows \"\(info.label)\", expected \"\(title)\"", file: file, line: line)
    }

    // MARK: - System controls without identifiers

    /// A button of the frontmost alert: by English label, else by position
    /// (the last button is the confirming one).
    func alertButton(_ label: String) -> XCUIElement {
        let alert = app.alerts.firstMatch
        _ = alert.waitForExistence(timeout: 10)
        let named = alert.buttons[label]
        if named.exists { return named }
        return alert.buttons.element(boundBy: max(alert.buttons.count - 1, 0))
    }

    /// The destructive button of a confirmation dialog whose English label
    /// starts with `labelPrefix`. Confirmation dialogs are action sheets on
    /// iPhone and popovers on iPad, so it is searched app-wide, excluding
    /// the control that opened the dialog.
    func confirmationButton(labelPrefix: String, excludingIdentifier excluded: String? = nil) -> XCUIElement {
        var format = "label BEGINSWITH %@"
        var arguments: [Any] = [labelPrefix]
        if let excluded {
            format += " AND identifier != %@"
            arguments.append(excluded)
        }
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        for query in [app.sheets.buttons, app.alerts.buttons, app.popovers.buttons] {
            let candidate = query.matching(predicate).firstMatch
            if candidate.waitForExistence(timeout: 2) { return candidate }
        }
        return app.buttons.matching(predicate).firstMatch
    }
}
