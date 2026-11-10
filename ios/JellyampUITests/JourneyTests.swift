import XCTest

/// The main user journeys, each from a fresh launch in demo mode.
final class OnboardingUITests: JellyampUITestCase {
    func testOnboardingAppearsWhenSignedOut() {
        launch(demo: false)

        waitFor(AccessibilityID.Onboarding.serverAddress, timeout: 40)
        waitFor(AccessibilityID.Onboarding.continueButton)
        waitFor(AccessibilityID.Onboarding.demoButton)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "signed out, but the tab bar is showing")
        XCTAssertFalse(element(AccessibilityID.Sidebar.home).exists, "signed out, but the sidebar is showing")
        // Nothing typed yet: there is nowhere to continue to.
        XCTAssertFalse(element(AccessibilityID.Onboarding.continueButton).isEnabled)
    }

    func testDemoButtonSignsIn() {
        launch(demo: false)

        tap(AccessibilityID.Onboarding.demoButton, timeout: 40)

        waitForShell()
        waitFor(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)
        XCTAssertFalse(element(AccessibilityID.Onboarding.serverAddress).exists)
    }

    func testSigningOutReturnsToOnboarding() {
        launch()

        open(.settings)
        tap(AccessibilityID.Settings.account)
        tap(AccessibilityID.Settings.signOut)
        let confirm = confirmationButton(labelPrefix: "Sign Out", excludingIdentifier: AccessibilityID.Settings.signOut)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the sign-out confirmation did not appear")
        confirm.tap()

        waitFor(AccessibilityID.Onboarding.serverAddress, timeout: 30)
        waitFor(AccessibilityID.Onboarding.demoButton)
    }
}

final class HomeUITests: JellyampUITestCase {
    func testHomeShowsItsShelves() {
        launch()

        // Jump Back In / Recently Added / Favorite Albums.
        waitFor(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)
        // Recently Played.
        waitFor(AccessibilityID.Home.track(Demo.nightFerry))
        // Mixes for You arrive once the demo's Sonic API has been probed.
        waitFor(AccessibilityID.Home.mix(Demo.firstMix), timeout: 40)
        waitFor(AccessibilityID.Home.adventure)
    }

    func testAlbumOpensFromHome() {
        launch()

        tap(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)

        for number in 1...5 {
            waitFor(AccessibilityID.Item.track(Demo.track(album: 3, number: number)))
        }
        waitFor(AccessibilityID.Collection.play)
        waitFor(AccessibilityID.Collection.shuffle)
        waitFor(AccessibilityID.Collection.download)
    }
}

final class PlaybackUITests: JellyampUITestCase {
    func testPlayATrackAndUseThePlayer() {
        launch()
        startPlayback()

        // The mini player reports "playing" while loading and playing.
        waitForAny(prefix: AccessibilityID.MiniPlayer.playPausePrefix)
        waitFor(AccessibilityID.MiniPlayer.playPause(isPlaying: true), timeout: 30)

        openNowPlaying()
        waitForNowPlaying(title: "Departure Board")
        waitFor(AccessibilityID.NowPlaying.artwork)
        waitFor(AccessibilityID.NowPlaying.scrubber)

        // Pause and resume.
        tap(AccessibilityID.NowPlaying.playPause(isPlaying: true), timeout: 30)
        waitFor(AccessibilityID.NowPlaying.playPause(isPlaying: false))
        tap(AccessibilityID.NowPlaying.playPause(isPlaying: false))
        waitFor(AccessibilityID.NowPlaying.playPause(isPlaying: true))

        // Next track of the album.
        tap(AccessibilityID.NowPlaying.next)
        waitForNowPlaying(title: "Night Ferry")

        // Close: the mini player is still there and shows the new track.
        tap(AccessibilityID.NowPlaying.close)
        waitFor(AccessibilityID.MiniPlayer.open)
        waitForDisappearance(of: AccessibilityID.NowPlaying.close)
    }

    func testQueueAndLyrics() {
        launch()
        startPlayback()
        openNowPlaying()

        // Queue: the rest of the album is up next.
        tap(AccessibilityID.NowPlaying.queue)
        waitFor(AccessibilityID.Queue.done)
        waitFor(AccessibilityID.Queue.upNext(0))
        waitFor(AccessibilityID.Queue.upNext(3))
        // Jump to the first upcoming track ("Night Ferry", which has lyrics).
        tap(AccessibilityID.Queue.upNext(0))
        tap(AccessibilityID.Queue.done)
        waitForDisappearance(of: AccessibilityID.Queue.done)
        waitForNowPlaying(title: "Night Ferry")

        // Lyrics.
        tap(AccessibilityID.NowPlaying.lyrics)
        waitFor(AccessibilityID.Lyrics.close)
        waitFor(AccessibilityID.Lyrics.line(0), timeout: 30)
        waitFor(AccessibilityID.Lyrics.line(3))
        tap(AccessibilityID.Lyrics.close)
        waitForDisappearance(of: AccessibilityID.Lyrics.close)

        // Visualizer toggle keeps the player usable.
        tap(AccessibilityID.NowPlaying.visualizer)
        waitFor(AccessibilityID.NowPlaying.artwork)
    }

    func testFavoriteFromNowPlaying() {
        launch()
        startPlayback()
        openNowPlaying()

        // "Departure Board" is not a favorite in the demo library.
        tap(AccessibilityID.NowPlaying.favorite(isOn: false), timeout: 30)
        waitFor(AccessibilityID.NowPlaying.favorite(isOn: true))
        tap(AccessibilityID.NowPlaying.favorite(isOn: true))
        waitFor(AccessibilityID.NowPlaying.favorite(isOn: false))
    }
}

final class LibraryUITests: JellyampUITestCase {
    func testEveryLibraryListShowsContent() {
        launch()

        openLibrary("albums")
        waitFor(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)

        openLibrary("artists")
        waitForAny(prefix: AccessibilityID.Item.artist(""), timeout: 30)

        openLibrary("songs")
        waitFor(AccessibilityID.Item.track(Demo.firstSong), timeout: 30)

        openLibrary("playlists")
        waitFor(AccessibilityID.Item.playlist(Demo.playlist(1)), timeout: 30)
        waitFor(AccessibilityID.Item.playlist(Demo.playlist(3)))

        openLibrary("genres")
        waitForAny(prefix: AccessibilityID.Item.genre(""), timeout: 30)
    }

    func testArtistAndPlaylistScreensOpen() {
        launch()

        openLibrary("artists")
        tap(AccessibilityID.Item.artist(Demo.artist(2)), timeout: 30)
        // The artist page: Play/Shuffle in its header …
        waitFor(AccessibilityID.Collection.play, timeout: 30)
        // … and Neon Estuary's two albums. The page is a lazy list and the
        // albums come after the popular songs: off screen on an iPhone.
        scrollToFind(AccessibilityID.Item.album(Demo.album(3)), timeout: 30)
        waitFor(AccessibilityID.Item.album(Demo.album(4)))

        openLibrary("playlists")
        tap(AccessibilityID.Item.playlist(Demo.playlist(2)), timeout: 30)
        // "Late Drive" opens with "Night Ferry".
        waitFor(AccessibilityID.Item.track(Demo.nightFerry), timeout: 30)
        waitFor(AccessibilityID.Collection.play)
    }

    func testFavoriteAnAlbum() {
        launch()

        openLibrary("albums")
        tap(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)
        tap(AccessibilityID.Collection.favorite(isOn: false), timeout: 30)
        waitFor(AccessibilityID.Collection.favorite(isOn: true))

        // It is now listed under Saved Albums.
        openLibrary("savedAlbums")
        waitFor(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)
    }

    func testCreateFillAndDeleteAPlaylist() {
        launch()
        let name = "UI Test Mix"
        let playlist = AccessibilityID.Item.playlist(Demo.firstCreatedPlaylist)

        // Create.
        openLibrary("playlists")
        waitFor(AccessibilityID.Item.playlist(Demo.playlist(1)), timeout: 30)
        tap(AccessibilityID.Library.newPlaylist)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the New Playlist alert did not appear")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the New Playlist alert has no text field")
        field.tap()
        field.typeText(name)
        alertButton("Create").tap()
        waitFor(playlist, timeout: 30)

        // Add a song through its context menu.
        openLibrary("songs")
        let song = waitFor(AccessibilityID.Item.track(Demo.firstSong), timeout: 30)
        song.press(forDuration: 1.2)
        let addToPlaylist = element(AccessibilityID.TrackMenu.addToPlaylist)
        if addToPlaylist.waitForExistence(timeout: 5) {
            addToPlaylist.tap()
        } else {
            // Menu items do not always expose their identifier.
            let byLabel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add to Playlist")).firstMatch
            XCTAssertTrue(byLabel.waitForExistence(timeout: 5), "the track menu has no Add to Playlist entry")
            byLabel.tap()
        }
        tap(AccessibilityID.AddToPlaylist.playlist(Demo.firstCreatedPlaylist), timeout: 30)
        waitForDisappearance(of: AccessibilityID.AddToPlaylist.cancel)

        // The playlist now holds the song.
        openLibrary("playlists")
        tap(playlist, timeout: 30)
        waitFor(AccessibilityID.Item.track(Demo.firstSong), timeout: 30)
        goBack()

        // Delete it with the swipe action.
        let row = waitFor(playlist, timeout: 30)
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "swiping the playlist row revealed no Delete action")
        delete.tap()
        let confirm = confirmationButton(labelPrefix: "Delete “")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the delete confirmation did not appear")
        confirm.tap()
        waitForDisappearance(of: playlist, timeout: 30)
        // The built-in playlists are untouched.
        waitFor(AccessibilityID.Item.playlist(Demo.playlist(1)))
    }
}

final class SearchUITests: JellyampUITestCase {
    func testSearchFindsATrack() {
        launch()
        open(.search)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the Search screen has no search field")
        field.tap()
        field.typeText("Lighthouse")

        waitFor(AccessibilityID.Item.track(Demo.lighthouse), timeout: 30)
    }
}

final class DownloadsUITests: JellyampUITestCase {
    func testDownloadAnAlbum() {
        launch()

        open(.downloads)
        waitFor(AccessibilityID.Downloads.empty, timeout: 30)

        openLibrary("albums")
        tap(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)
        waitFor(AccessibilityID.Item.track(Demo.track(album: 10, number: 1)), timeout: 30)
        tap(AccessibilityID.Collection.download)

        open(.downloads)
        // Five small files from the loopback server; the transfers run in the
        // system's background download service, which can take its time on a
        // busy CI machine.
        waitFor(AccessibilityID.Downloads.collection(Demo.afterglowMotelAlbum), timeout: 180)
        XCTAssertFalse(element(AccessibilityID.Downloads.empty).exists)
    }
}

final class SettingsUITests: JellyampUITestCase {
    func testEverySettingsScreenOpens() {
        launch()
        open(.settings)

        let rows = [
            AccessibilityID.Settings.playback,
            AccessibilityID.Settings.downloads,
            AccessibilityID.Settings.sonic,
            AccessibilityID.Settings.scrobbling,
            AccessibilityID.Settings.account,
            AccessibilityID.Settings.about,
        ]
        for row in rows {
            tap(row, timeout: 30)
            // The pushed screen replaces the list: its rows are gone and a
            // back button leads to them again.
            waitForDisappearance(of: AccessibilityID.Settings.about == row ? AccessibilityID.Settings.playback : AccessibilityID.Settings.about, timeout: 10)
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "\(row) opened without a navigation bar")
            goBack()
            waitFor(row, timeout: 15)
        }
        // Account names the demo server.
        tap(AccessibilityID.Settings.account)
        waitFor(AccessibilityID.Settings.signOut)
    }
}

/// The regular-width layout. Skipped on iPhone.
final class SidebarUITests: JellyampUITestCase {
    func testSidebarShellOnIPad() throws {
        try XCTSkipUnless(isPad, "the sidebar layout exists on iPad only")
        launch()

        XCTAssertFalse(app.tabBars.firstMatch.exists, "the sidebar layout must not show a tab bar")
        for row in [AccessibilityID.Sidebar.home, AccessibilityID.Sidebar.search, AccessibilityID.Sidebar.downloads, AccessibilityID.Sidebar.settings] {
            waitFor(row)
        }
        for category in ["playlists", "artists", "albums", "songs", "genres", "likedSongs", "savedAlbums", "following"] {
            waitFor(AccessibilityID.Sidebar.category(category))
        }

        // Home is the initial detail; the lists open next to the sidebar.
        waitFor(AccessibilityID.Home.album(Demo.nightFerryAlbum), timeout: 40)
        openLibrary("albums")
        waitFor(AccessibilityID.Item.album(Demo.afterglowMotelAlbum), timeout: 30)
        waitFor(AccessibilityID.Sidebar.home)
        open(.settings)
        waitFor(AccessibilityID.Settings.playback)

        // Playback docks the mini player in the detail column.
        open(.home)
        startPlayback()
        waitFor(AccessibilityID.Sidebar.home)
    }
}
