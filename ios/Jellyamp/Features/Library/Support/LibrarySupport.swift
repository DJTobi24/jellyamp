import Foundation
import SwiftUI
import JellyampCore
import JellyfinBackend

extension DependencyContainer {
    /// Paged library access for the browsing screens. In offline mode it goes
    /// through `library` (which another layer decorates with the offline
    /// filter) so lists show what is actually playable; otherwise it talks to
    /// the server directly. Cheap to create, so it is built on demand.
    var browser: LibraryBrowsing? {
        if settings.offlineModeEnabled, let library {
            return LibraryProviderBrowser(library: library)
        }
        guard let session else { return nil }
        return LibraryBrowseAPI(session: session)
    }
}

/// Turns errors into one short sentence a user can act on.
enum LibraryErrorText {
    static func message(for error: Error) -> String {
        // Changes the offline library cannot make (favorites, playlists).
        if let offlineMessage = OfflineErrorMessage.text(for: error) {
            return offlineMessage
        }
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

/// Session-wide favorite state. Every heart reads through it, so a change
/// made on one screen shows on all others without reloading them.
@MainActor
final class FavoritesModel: ObservableObject {
    static let shared = FavoritesModel()

    @Published private(set) var overrides = FavoriteOverrides()
    /// Counts changes the server has confirmed. Favorites lists reload when
    /// it moves (reloading on the optimistic change would race the request).
    @Published private(set) var confirmedChanges = 0

    func isFavorite(_ itemID: String, serverValue: Bool) -> Bool {
        overrides.isFavorite(itemID, serverValue: serverValue)
    }

    /// Flips the heart immediately and writes it to the server; on failure
    /// the previous state comes back and a banner explains why.
    func toggle(itemID: String, serverValue: Bool, library: MusicLibraryProviding?) {
        let previous = overrides.values[itemID]
        let target = !overrides.isFavorite(itemID, serverValue: serverValue)
        overrides.set(itemID, isFavorite: target)
        guard let library else {
            overrides.restore(itemID, previous: previous)
            return
        }
        Task { @MainActor in
            do {
                try await library.setFavorite(itemID: itemID, isFavorite: target)
                self.confirmedChanges += 1
            } catch {
                self.overrides.restore(itemID, previous: previous)
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

    func playlistsChanged() {
        playlistsRevision += 1
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
