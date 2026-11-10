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

    private var didDumpHierarchy = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        didDumpHierarchy = false
        app = XCUIApplication()
        // iPad in landscape shows the sidebar next to the content; in
        // portrait the split view hides it behind a toolbar button.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Failure diagnostics

    /// Prints what was on screen when the first assertion of a test failed.
    /// On CI the result bundle (with its screenshots) is an artifact nobody
    /// may be able to open; the accessibility hierarchy in the log says
    /// which identifiers were there instead of the expected one.
    /// `scripts/ci/xcodebuild.sh` repeats these lines at the end of the step.
    override func record(_ issue: XCTIssue) {
        if !didDumpHierarchy, let app {
            didDumpHierarchy = true
            let marker = "UI-HIERARCHY| "
            print("\(marker)==== \(name): \(issue.compactDescription)")
            let lines = app.debugDescription.split(separator: "\n", omittingEmptySubsequences: true)
            var printed = 0
            for line in lines {
                // Element lines only; pointers and the legend are noise.
                guard line.contains("{{") else { continue }
                let text = line.replacingOccurrences(of: #"0x[0-9a-fA-F]+, "#, with: "", options: .regularExpression)
                print(marker + text)
                printed += 1
                if printed >= 400 {
                    print("\(marker)… (truncated)")
                    break
                }
            }
            print("\(marker)==== end")
            fflush(stdout)
        }
        super.record(issue)
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

    /// Waits for the element, scrolls it into view if necessary and taps it.
    func tap(_ identifier: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let target = waitFor(identifier, timeout: timeout, file: file, line: line)
        scrollIntoView(target)
        if target.isHittable {
            target.tap()
        } else {
            // Covered or clipped (a card under the mini player, a toolbar
            // item in an overflow): tap its centre directly.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    // MARK: - Scrolling

    /// Drags the content until `target` can be tapped. An element of a
    /// (non-lazy) scroll view exists while it is off screen or under the tab
    /// bar and the mini player, but a tap sent to its position would hit
    /// whatever is there instead — Home's lower shelves are such elements.
    /// Does nothing for an element that is on screen but covered, and gives
    /// up when dragging does not move the element.
    func scrollIntoView(_ target: XCUIElement) {
        var attempts = 0
        while attempts < 12, target.exists, !target.isHittable {
            let screen = app.frame
            let frame = target.frame
            guard screen.width > 0, screen.height > 0, frame.width > 0 else { return }
            // Navigation bar at the top; tab bar and mini player at the bottom.
            let top = screen.minY + 110
            let bottom = screen.maxY - 170
            let y = min(max((frame.midY - screen.minY) / screen.height, 0.2), 0.8)
            if frame.midY > bottom {
                drag(fromX: contentX, y: 0.62, toX: contentX, y: 0.38)
            } else if frame.midY < top {
                drag(fromX: contentX, y: 0.38, toX: contentX, y: 0.62)
            } else if frame.midX > screen.maxX - 24 {
                drag(fromX: 0.8, y: y, toX: 0.5, y: y)
            } else if frame.midX < screen.minX + 24 {
                drag(fromX: 0.5, y: y, toX: 0.8, y: y)
            } else {
                return
            }
            attempts += 1
            // Not part of anything that scrolls (a bar, the mini player):
            // dragging on will not help.
            if target.exists, target.frame == frame { return }
        }
    }

    /// Waits for an element of a lazy container (`List`, lazy stacks and
    /// grids), which does not exist until it is scrolled near the screen:
    /// scrolls down step by step until it shows up.
    @discardableResult
    func scrollToFind(_ identifier: String, timeout: TimeInterval = 20, maxScrolls: Int = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(identifier)
        var scrolls = 0
        // The first wait also covers the page loading its content.
        while !found.waitForExistence(timeout: scrolls == 0 ? timeout : 2), scrolls < maxScrolls {
            drag(fromX: contentX, y: 0.62, toX: contentX, y: 0.38)
            scrolls += 1
        }
        XCTAssertTrue(found.exists, "no element with identifier \"\(identifier)\", also after scrolling down \(scrolls) times", file: file, line: line)
        return found
    }

    /// Horizontal position (0…1) inside the content: on iPad the sidebar
    /// takes the left third of the screen.
    private var contentX: CGFloat { isPad ? 0.65 : 0.5 }

    /// A slow drag between two points of the screen (normalized), without
    /// the momentum of a swipe, so the distance scrolled is predictable.
    private func drag(fromX: CGFloat, y fromY: CGFloat, toX: CGFloat, y toY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end)
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

    /// Taps the back button of the content's navigation bar. UIKit gives
    /// that button the identifier "BackButton" whatever its title is; on
    /// iPad the sidebar has a navigation bar of its own (whose first button
    /// toggles the sidebar), so the bar is never chosen by its index: the
    /// content's bar is the one furthest to the right.
    func goBack() {
        let bars = app.navigationBars
        guard bars.firstMatch.waitForExistence(timeout: 5) else { return }
        let backButtons = bars.buttons.matching(identifier: "BackButton")
        if backButtons.firstMatch.waitForExistence(timeout: 3) {
            backButtons.element(boundBy: max(backButtons.count - 1, 0)).tap()
            return
        }
        let content = bars.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }
        if let back = content?.buttons.element(boundBy: 0), back.waitForExistence(timeout: 5) {
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
