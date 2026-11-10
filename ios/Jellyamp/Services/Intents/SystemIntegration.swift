import AppIntents
import Combine
import CoreSpotlight
import Foundation
import JellyampCore
import SwiftUI
import UniformTypeIdentifiers

/// Keeps the system's picture of Jellyamp current: which names Siri can
/// recognise in App Shortcut phrases, what was played (so Siri Suggestions
/// and Spotlight can offer it again), and the "continue this album" activity.
///
/// Attached once by `DependencyContainer.ensureBootstrapped()`, so it works
/// the same whether the process was started by the user, Siri or CarPlay.
@MainActor
final class SystemIntegration {
    static let shared = SystemIntegration()

    private weak var container: DependencyContainer?
    private var cancellables: Set<AnyCancellable> = []
    /// Kept alive while it is the current activity; the system drops an
    /// activity as soon as its object is released.
    private var albumActivity: NSUserActivity?
    private var activityAlbumID: String?

    private init() {}

    func attach(to container: DependencyContainer) {
        guard self.container == nil else { return }
        self.container = container

        // Sign-in / sign-out: the set of playable names changes completely.
        container.$session
            .map { $0?.isAuthenticated ?? false }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                // `@Published` fires before the value (and the library built
                // from it) is in place, so act on the next main-actor turn.
                Task { @MainActor in self?.sessionChanged(signedIn: signedIn) }
            }
            .store(in: &cancellables)

        container.playerState.$currentTrack
            .removeDuplicates { $0?.albumID == $1?.albumID }
            .sink { [weak self] track in
                Task { @MainActor in self?.updateAlbumActivity(for: track) }
            }
            .store(in: &cancellables)
    }

    private func sessionChanged(signedIn: Bool) {
        refreshShortcutParameters()
        if !signedIn {
            // Nothing of the old account may linger in Spotlight or Siri.
            albumActivity?.invalidate()
            albumActivity = nil
            activityAlbumID = nil
            NSUserActivity.deleteAllSavedUserActivities {}
        }
    }

    /// Tells the system to re-read `MusicEntityQuery.suggestedEntities()`.
    /// Call after anything that changes which playlists, favorites or genres
    /// exist; Siri only understands names it was told about this way.
    func refreshShortcutParameters() {
        if #available(iOS 16.4, *) {
            JellyampShortcuts.updateAppShortcutParameters()
        }
    }

    // MARK: - "Continue album" activity

    /// Advertises the album being played as an `NSUserActivity`: it shows up
    /// in Spotlight and Siri Suggestions ("Continue Kind of Blue") and is
    /// handed back to `continueListening(_:)` when the user taps it.
    private func updateAlbumActivity(for track: Track?) {
        guard let track, let albumID = track.albumID, let albumName = track.albumName, !albumName.isEmpty else {
            return
        }
        guard albumID != activityAlbumID else { return }

        let activity = NSUserActivity(activityType: ListeningActivity.playAlbumType)
        activity.title = String(localized: "Play \(albumName)")
        activity.userInfo = [
            ListeningActivity.albumIDKey: albumID,
            ListeningActivity.albumNameKey: albumName,
        ]
        activity.requiredUserInfoKeys = [ListeningActivity.albumIDKey, ListeningActivity.albumNameKey]
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
        activity.isEligibleForHandoff = false
        // One entry per album: playing it again updates instead of duplicating.
        activity.persistentIdentifier = "album:\(albumID)"

        let attributes = CSSearchableItemAttributeSet(contentType: UTType.audio)
        attributes.contentDescription = track.artistName
        attributes.album = albumName
        attributes.artist = track.artistName
        activity.contentAttributeSet = attributes

        albumActivity?.resignCurrent()
        albumActivity = activity
        activityAlbumID = albumID
        activity.becomeCurrent()
    }

    /// Handles an activity delivered by Spotlight / Siri Suggestions.
    func continueListening(_ activity: NSUserActivity) {
        guard activity.activityType == ListeningActivity.playAlbumType,
              let albumID = activity.userInfo?[ListeningActivity.albumIDKey] as? String else { return }
        let albumName = activity.userInfo?[ListeningActivity.albumNameKey] as? String ?? ""
        Task { @MainActor in
            guard let commands = try? await MusicCommands.live() else { return }
            _ = try? await commands.play(MusicItemRef(kind: .album, id: albumID, name: albumName), shuffled: false)
        }
    }
}

/// Constants of the "continue album" activity. The type must also be listed
/// under `NSUserActivityTypes` in Info.plist (see `ios/project.yml`).
enum ListeningActivity {
    static let playAlbumType = "dev.djtobi.jellyamp.playAlbum"
    static let albumIDKey = "albumID"
    static let albumNameKey = "albumName"
}

extension View {
    /// Lets Spotlight / Siri Suggestions results start playback. Attach once
    /// to the root view of the window.
    func continuesListeningActivities() -> some View {
        onContinueUserActivity(ListeningActivity.playAlbumType) { activity in
            Task { @MainActor in
                SystemIntegration.shared.continueListening(activity)
            }
        }
    }
}

/// Donates "the user just played this" to the system so Siri Suggestions,
/// Spotlight and the Shortcuts app can offer it again.
///
/// Intents run *by* Siri or Shortcuts are donated automatically; this is for
/// playback started by touch — in the app or in CarPlay.
@MainActor
enum IntentDonor {
    static func donatePlay(_ item: MusicItemRef, artistName: String? = nil) {
        let entity = MusicEntity(kind: item.kind, itemID: item.id, name: item.name, artistName: artistName)
        let intent = PlayMusicIntent(target: entity)
        Task {
            _ = try? await IntentDonationManager.shared.donate(intent: intent)
        }
    }

    static func donateRadio(_ item: MusicItemRef) {
        let entity = MusicEntity(kind: item.kind, itemID: item.id, name: item.name)
        let intent = StartRadioIntent(seed: entity)
        Task {
            _ = try? await IntentDonationManager.shared.donate(intent: intent)
        }
    }

    static func donateShuffleLikedSongs() {
        let intent = ShuffleLikedSongsIntent()
        Task {
            _ = try? await IntentDonationManager.shared.donate(intent: intent)
        }
    }
}
