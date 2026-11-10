import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `OfflineLibrary` covers `MusicLibraryProviding`; these two cover the other
/// ways the app reaches Jellyfin, so that all of them agree on one
/// `OfflineStateTracker`:
///
/// - `OfflineAwareBrowser` for the paged browsing screens (`LibraryBrowsing`),
///   which have a downloaded equivalent to fall back to;
/// - `OfflineGatedTransport` for clients without one (ID lookups, stations,
///   Instant Mix, playback reports), which must at least fail at once and
///   cleanly instead of spinning into a timeout.

/// Routes paged browsing like `OfflineLibrary` routes the library: the
/// server while it is reachable, `offline` (a `LibraryProviderBrowser` over
/// the offline-decorated library) when offline mode is on, the network is
/// gone or the request fails for connectivity reasons. A list the downloads
/// cannot produce surfaces as `LibraryBrowseError.unavailable`, which the UI
/// words as "not available offline".
public struct OfflineAwareBrowser: LibraryBrowsing {
    private let online: LibraryBrowsing
    private let offline: LibraryBrowsing
    private let state: OfflineStateTracker
    private let isConnectivityError: @Sendable (Error) -> Bool

    /// - Parameter online: must talk to the server directly (not through an
    ///   `OfflineGatedTransport` on the same tracker — the tracker hands out
    ///   one probe per interval, and this decorator already claims it).
    public init(
        online: LibraryBrowsing,
        offline: LibraryBrowsing,
        state: OfflineStateTracker,
        isConnectivityError: @escaping @Sendable (Error) -> Bool = OfflineLibrary.isConnectivityError(_:)
    ) {
        self.online = online
        self.offline = offline
        self.state = state
        self.isConnectivityError = isConnectivityError
    }

    private func route<T>(_ call: (LibraryBrowsing) async throws -> T) async throws -> T {
        switch state.route() {
        case .offline:
            return try await call(offline)
        case .online, .probe:
            do {
                let value = try await call(online)
                state.recordRequestSuccess()
                return value
            } catch {
                guard isConnectivityError(error) else {
                    // The server answered (with an error): it is reachable.
                    if error is JellyfinError { state.recordRequestSuccess() }
                    throw error
                }
                state.recordConnectivityFailure()
                return try await call(offline)
            }
        }
    }

    public func albumsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Album> {
        try await route { try await $0.albumsPage(sort: sort, filter: filter, startIndex: startIndex, limit: limit) }
    }

    public func artistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Artist> {
        try await route { try await $0.artistsPage(sort: sort, filter: filter, startIndex: startIndex, limit: limit) }
    }

    public func tracksPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Track> {
        try await route { try await $0.tracksPage(sort: sort, filter: filter, startIndex: startIndex, limit: limit) }
    }

    public func playlistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Playlist> {
        try await route { try await $0.playlistsPage(sort: sort, filter: filter, startIndex: startIndex, limit: limit) }
    }

    public func genresPage(startIndex: Int, limit: Int) async throws -> Page<Genre> {
        try await route { try await $0.genresPage(startIndex: startIndex, limit: limit) }
    }

    public func playlistTracksPage(playlistID: String, startIndex: Int, limit: Int) async throws -> Page<Track> {
        try await route { try await $0.playlistTracksPage(playlistID: playlistID, startIndex: startIndex, limit: limit) }
    }

    public func alphabetOffset(of letter: String, kind: BrowseKind, filter: BrowseFilter) async throws -> Int {
        try await route { try await $0.alphabetOffset(of: letter, kind: kind, filter: filter) }
    }

    public func discography(artistID: String) async throws -> [Album] {
        try await route { try await $0.discography(artistID: artistID) }
    }

    public func appearsOn(artistID: String) async throws -> [Album] {
        try await route { try await $0.appearsOn(artistID: artistID) }
    }

    public func playlist(id: String) async throws -> Playlist? {
        try await route { try await $0.playlist(id: id) }
    }
}

/// Transport for Jellyfin clients that have nothing to serve offline. While
/// the tracker says "offline" a request is refused immediately with
/// `URLError(.notConnectedToInternet)` — no socket is opened in offline mode
/// and nothing waits for a timeout against a dead server. Otherwise the
/// request goes out and its outcome is reported to the tracker, so these
/// clients notice (and recover from) an unreachable server like the library
/// does.
public struct OfflineGatedTransport: HTTPTransport {
    private let base: HTTPTransport
    private let state: OfflineStateTracker
    private let marksUnreachable: Bool
    private let isConnectivityError: @Sendable (Error) -> Bool

    /// - Parameter marksUnreachable: whether a connectivity failure of a
    ///   request through this transport declares the server unreachable
    ///   (which switches the whole app to downloads until the next probe).
    ///   Pass false for traffic whose failure is weak evidence — background
    ///   POSTs such as playback reports can fail on a stale connection while
    ///   the server is fine. Successes are always recorded.
    public init(
        base: HTTPTransport = URLSessionTransport(),
        state: OfflineStateTracker,
        marksUnreachable: Bool = true,
        isConnectivityError: @escaping @Sendable (Error) -> Bool = OfflineLibrary.isConnectivityError(_:)
    ) {
        self.base = base
        self.state = state
        self.marksUnreachable = marksUnreachable
        self.isConnectivityError = isConnectivityError
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if state.route() == .offline {
            throw URLError(.notConnectedToInternet)
        }
        do {
            let answer = try await base.send(request)
            // Any HTTP status means the server is there.
            state.recordRequestSuccess()
            return answer
        } catch {
            if marksUnreachable, isConnectivityError(error) { state.recordConnectivityFailure() }
            throw error
        }
    }
}
