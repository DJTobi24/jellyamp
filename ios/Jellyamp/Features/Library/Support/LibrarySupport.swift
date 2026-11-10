import Foundation
import SwiftUI
import JellyampCore
import JellyfinBackend

extension DependencyContainer {
    /// Paged library access for the browsing screens: the server while it is
    /// reachable, the downloaded library otherwise — offline mode, no
    /// network, or a request that fails for connectivity reasons. It shares
    /// `offline`'s state tracker with `library`, so both switch together and
    /// a browse request that finds the server gone raises the offline
    /// banner. The server client uses the session transport: a rejected
    /// token is noticed from any list. Cheap to create; built on demand.
    var browser: LibraryBrowsing? {
        guard let session, let library else { return nil }
        return OfflineAwareBrowser(
            online: LibraryBrowseAPI(session: session, transport: makeSessionTransport()),
            offline: LibraryProviderBrowser(library: library),
            state: offline.status.tracker
        )
    }
}

/// Turns errors into one short sentence a user can act on.
enum LibraryErrorText {
    static func message(for error: Error) -> String {
        if let error = error as? JellyfinError {
            switch error {
            case .unauthorized, .notAuthenticated:
                return String(localized: "Your session has expired. Sign in again.")
            case .notFound:
                return String(localized: "This item no longer exists on the server.")
            case .serverError(let status):
                return String(localized: "The server reported an error (\(status)).")
            default:
                // Also covers cases other features add to the enum later.
                return String(localized: "The server sent an unexpected response.")
            }
        }
        if error is LibraryBrowseError {
            return String(localized: "This list is not available offline.")
        }
        if let offlineText = OfflineErrorMessage.text(for: error) {
            return offlineText
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "You appear to be offline.")
            case .timedOut:
                return String(localized: "The server took too long to answer.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "The server cannot be reached.")
            default:
                return String(localized: "The connection to the server failed.")
            }
        }
        return String(localized: "Something went wrong. Please try again.")
    }

    /// Cancellation is not a failure worth showing.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}

/// Session-wide favorite state and the one way to change it.
///
/// Every heart — rows, menus, Now Playing, the lock screen's like command,
/// CarPlay, the Siri intent — reads through `isFavorite` and writes through
/// `set` / `toggle`, so a change made anywhere shows everywhere. Surfaces
/// that keep their own copy of the flag (the player's queued tracks, and
/// through them the lock screen) are updated by `onChange`, which the
/// container installs.
@MainActor
final class FavoritesModel: ObservableObject {
    static let shared = FavoritesModel()

    @Published private(set) var overrides = FavoriteOverrides()
    /// Counts changes the server has confirmed. Favorites lists reload when
    /// it moves (reloading on the optimistic change would race the request).
    @Published private(set) var confirmedChanges = 0

    /// Called for every change of an item's effective state, including the
    /// rollback of a failed one.
    var onChange: ((_ itemID: String, _ isFavorite: Bool) -> Void)?
    /// Called once the server has accepted a change.
    var onConfirmed: (() -> Void)?

    func isFavorite(_ itemID: String, serverValue: Bool) -> Bool {
        overrides.isFavorite(itemID, serverValue: serverValue)
    }

    func isFavorite(_ track: Track) -> Bool {
        overrides.isFavorite(track.id, serverValue: track.isFavorite)
    }

    /// Sets the favorite state: shown immediately, then written to the
    /// server; on failure the previous state comes back and the error is
    /// thrown for the caller to present. Does nothing when the item already
    /// is in the wanted state.
    func set(itemID: String, isFavorite target: Bool, serverValue: Bool, library: MusicLibraryProviding?) async throws {
        let before = overrides.isFavorite(itemID, serverValue: serverValue)
        guard before != target else { return }
        let previous = overrides.values[itemID]
        overrides.set(itemID, isFavorite: target)
        onChange?(itemID, target)
        do {
            guard let library else { throw JellyfinError.notAuthenticated }
            try await library.setFavorite(itemID: itemID, isFavorite: target)
        } catch {
            overrides.restore(itemID, previous: previous)
            onChange?(itemID, before)
            throw error
        }
        confirmedChanges += 1
        onConfirmed?()
    }

    /// Flips the heart for the in-app buttons; a failure is explained by a
    /// banner.
    func toggle(itemID: String, serverValue: Bool, library: MusicLibraryProviding?) {
        let target = !overrides.isFavorite(itemID, serverValue: serverValue)
        Task { @MainActor in
            do {
                try await self.set(itemID: itemID, isFavorite: target, serverValue: serverValue, library: library)
            } catch {
                ToastCenter.shared.show(
                    target
                        ? String(localized: "Could not add to favorites.")
                        : String(localized: "Could not remove from favorites."),
                    detail: LibraryErrorText.message(for: error),
                    style: .error
                )
            }
        }
    }

    /// Forget all local state (sign-out / account switch).
    func reset() {
        overrides.reset()
    }
}

/// What the "Add to Playlist" sheet should add.
struct PlaylistAddRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
    /// Shown in the sheet: a track title, an album title, "12 songs", …
    let title: String

    init(tracks: [Track], title: String) {
        self.tracks = tracks
        self.title = title
    }

    init(track: Track) {
        self.tracks = [track]
        self.title = track.title
    }
}

/// Tells list screens that data they show was changed elsewhere in the app.
@MainActor
final class LibraryChanges: ObservableObject {
    static let shared = LibraryChanges()

    /// Bumped when a playlist was created, renamed, deleted or its contents
    /// changed; the playlists list refreshes when it moves.
    @Published private(set) var playlistsRevision = 0

    /// - Parameter namesChanged: a playlist was created, renamed or deleted.
    ///   Siri only recognises playlist names it was told about, so the
    ///   system is asked to read the list again.
    func playlistsChanged(namesChanged: Bool = false) {
        playlistsRevision += 1
        if namesChanged {
            SystemIntegration.shared.refreshShortcutParameters()
        }
    }
}

/// Load state of a screen that fetches its content in one go.
enum LoadPhase: Equatable {
    case loading
    case loaded
    case failed(String)

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
