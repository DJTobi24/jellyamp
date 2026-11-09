import CarPlay
import UIKit
import JellyampCore

/// Entry point of the CarPlay scene (role
/// `CPTemplateApplicationSceneSessionRoleApplication`).
///
/// The class is always compiled so CI keeps it building, but the system only
/// instantiates it when the build was generated with `CARPLAY_ENABLED=YES`,
/// which adds the scene manifest entry naming this class and the
/// `com.apple.developer.carplay-audio` entitlement (see docs/CARPLAY.md).
///
/// CarPlay may launch the app straight into this scene while the phone is
/// locked: no window scene, no SwiftUI view tree. Everything the scene needs
/// therefore comes from `DependencyContainer.shared`, and the coordinator
/// takes care of restoring the session before it shows content.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coordinator
        coordinator.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}

extension CarPlayStrings {
    /// The CarPlay texts as localizable strings (Core only knows the English
    /// defaults because it must build without Apple's localization APIs).
    static var localized: CarPlayStrings {
        var strings = CarPlayStrings()
        strings.home = String(localized: "Home")
        strings.library = String(localized: "Library")
        strings.downloads = String(localized: "Downloads")
        strings.quickPlay = String(localized: "Quick Play")
        strings.shuffleLikedSongs = String(localized: "Shuffle Liked Songs")
        strings.mixesForYou = String(localized: "Mixes for You")
        strings.recentlyAdded = String(localized: "Recently Added")
        strings.recentlyPlayed = String(localized: "Recently Played")
        strings.artists = String(localized: "Artists")
        strings.albums = String(localized: "Albums")
        strings.playlists = String(localized: "Playlists")
        strings.likedSongs = String(localized: "Liked Songs")
        strings.genres = String(localized: "Genres")
        strings.songs = String(localized: "Songs")
        strings.play = String(localized: "Play")
        strings.shuffle = String(localized: "Shuffle")
        strings.shuffleAll = String(localized: "Shuffle All")
        strings.startRadio = String(localized: "Start Radio")
        strings.nowPlaying = String(localized: "Now Playing")
        strings.upNext = String(localized: "Up Next")
        strings.unknownAlbum = String(localized: "Unknown Album")
        strings.nothingHere = String(localized: "Nothing Here Yet")
        strings.homeEmptyHint = String(localized: "Play something on your iPhone and it will show up here.")
        strings.noDownloads = String(localized: "No Downloads")
        strings.noDownloadsHint = String(localized: "Download music in Jellyamp on your iPhone to listen offline.")
        strings.queueEmpty = String(localized: "Nothing Queued")
        strings.signedOutTitle = String(localized: "Not Signed In")
        strings.signedOutHint = String(localized: "Open Jellyamp on your iPhone and sign in to your Jellyfin server.")
        strings.songCount = { count in
            count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
        }
        return strings
    }
}
