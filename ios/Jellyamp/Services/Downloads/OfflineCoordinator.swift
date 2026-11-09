import Foundation
import Combine
import OSLog
import UIKit
import JellyampCore
import JellyfinBackend
import SonicClient

/// Glue for everything offline: wraps the library in the `OfflineLibrary`
/// decorator, keeps the offline state and the download manager in step with
/// the settings, and runs smart sync.
///
/// Lives for the whole app session (the banner observes `status`);
/// `activate` / `deactivate` follow sign-in and sign-out. It observes the
/// container's published settings itself, so no call is needed when they
/// change.
@MainActor
final class OfflineCoordinator {
    let status = OfflineStatus()
    /// Outcome of the last smart-sync run, for the settings screen.
    let syncState = SmartSyncState()

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "SmartSync")
    private weak var container: DependencyContainer?
    private weak var downloads: DownloadManager?
    /// The undecorated server library. Sync must never read through the
    /// offline decorator: a fallback answer would look like "the playlist
    /// shrank" and delete downloads.
    private var online: MusicLibraryProviding?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingSync: Task<Void, Never>?
    private var isSyncing = false
    private var syncRequestedWhileRunning = false

    /// Wraps `online` so it serves downloads when offline, and starts
    /// following settings, connectivity and app activation.
    func activate(
        wrapping online: MusicLibraryProviding,
        downloads: DownloadManager,
        container: DependencyContainer
    ) -> MusicLibraryProviding {
        deactivate()
        self.online = online
        self.downloads = downloads
        self.container = container
        applySettings(container.settings)

        // Only the settings that matter here: a crossfade slider being dragged
        // must not start a sync.
        container.$settings
            .removeDuplicates { old, new in
                old.offlineModeEnabled == new.offlineModeEnabled
                    && old.downloadsOverCellular == new.downloadsOverCellular
                    && old.smartSync == new.smartSync
            }
            .dropFirst()
            .sink { [weak self] settings in
                Task { @MainActor in
                    self?.applySettings(settings)
                    self?.requestSync()
                }
            }
            .store(in: &cancellables)
        // Capabilities arrive after the sonic provider was probed; mixes can
        // only be synced from then on.
        container.$sonicCapabilities
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            }
            .store(in: &cancellables)
        // Coming back online (or onto Wi-Fi) is a reason to sync.
        status.$reason
            .combineLatest(status.$isExpensive)
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            }
            .store(in: &cancellables)
        // The first sync has to wait until the index is reconciled.
        downloads.$isReady
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.downloads?.wake()
                    self?.requestSync()
                }
            }
            .store(in: &cancellables)

        let tracker = status.tracker
        return OfflineLibrary(
            online: online,
            catalog: downloads,
            state: tracker,
            onGenresFetched: { [weak downloads] genres in
                Task { @MainActor in downloads?.remember(genres: genres) }
            }
        )
    }

    func deactivate() {
        cancellables.removeAll()
        pendingSync?.cancel()
        pendingSync = nil
        online = nil
        downloads = nil
        container = nil
        status.tracker.setUserEnabled(false)
    }

    /// Runs smart sync soon. Requests are coalesced, so toggling several
    /// rules in a row results in one run.
    func requestSync() {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// "Sync Now" from the settings screen. Runs in its own task so a newer
    /// request (which cancels `pendingSync`) cannot abort a run half-way.
    func syncNow() {
        Task { [weak self] in
            await self?.sync()
        }
    }

    private func applySettings(_ settings: AppSettings) {
        status.tracker.setUserEnabled(settings.offlineModeEnabled)
        downloads?.apply(settings: settings)
    }

    // MARK: Smart sync

    private func sync() async {
        guard !isSyncing else {
            syncRequestedWhileRunning = true
            return
        }
        isSyncing = true
        syncState.isRunning = true
        defer {
            isSyncing = false
            syncState.isRunning = false
            if syncRequestedWhileRunning {
                syncRequestedWhileRunning = false
                requestSync()
            }
        }
        do {
            try await performSync()
        } catch {
            // Leave everything as it is: a failed fetch must never be read as
            // "nothing is wanted any more".
            log.error("smart sync aborted: \(String(describing: error), privacy: .public)")
            syncState.lastResult = .failed
        }
    }

    private func performSync() async throws {
        guard let container, let downloads, let online, downloads.isReady else { return }
        let settings = container.settings
        guard !status.isOffline else {
            syncState.lastResult = .skippedOffline
            return
        }
        // Automatic downloads wait for Wi-Fi unless cellular is allowed.
        guard !status.isExpensive || settings.downloadsOverCellular else {
            syncState.lastResult = .skippedCellular
            return
        }

        try await resyncPlaylists(downloads: downloads, online: online)

        let rules = settings.smartSync
        // Nothing to add and nothing of ours to clean up.
        guard rules.isEnabled || !downloads.index.smartSyncTrackIDs.isEmpty else {
            syncState.lastResult = .done(Date())
            return
        }
        // Until the sonic provider is wired we can't tell "no mixes" from
        // "not asked yet"; the capabilities publisher triggers another run.
        guard let sonic = container.sonic else { return }

        var tracksByID: [String: Track] = [:]
        var favoriteIDs: [String] = []
        if rules.autoDownloadFavorites {
            let favorites = try await online.favoriteTracks(limit: 5000)
            favoriteIDs = favorites.map(\.id)
            for track in favorites { tracksByID[track.id] = track }
        }
        var favoriteAlbumTrackIDs: [String] = []
        if rules.autoDownloadFavoriteAlbums {
            let favoriteAlbums = try await online.favoriteAlbums(limit: 500)
            for album in favoriteAlbums {
                let albumTracks = try await online.tracks(inAlbum: album.id)
                favoriteAlbumTrackIDs.append(contentsOf: albumTracks.map(\.id))
                for track in albumTracks { tracksByID[track.id] = track }
            }
        }
        var mixes: [MixDescriptor] = []
        if rules.keepLatestMixes > 0, container.sonicCapabilities.supports(.mixes), let userID = container.session?.userID {
            let allMixes = try await sonic.mixes(forUser: userID)
            mixes = Array(allMixes.prefix(rules.keepLatestMixes))
            var wanted: [String] = []
            for id in mixes.flatMap(\.itemIDs) where tracksByID[id] == nil && !wanted.contains(id) {
                wanted.append(id)
            }
            // Chunked: the ids travel in the query string.
            var start = 0
            while start < wanted.count {
                let chunk = Array(wanted[start..<min(start + 100, wanted.count)])
                let resolved = try await online.tracks(byIDs: chunk)
                for track in resolved { tracksByID[track.id] = track }
                start += 100
            }
        }
        // Signed out (or switched accounts) while fetching: this manager is
        // no longer the active one and must not be told to download.
        guard self.downloads === downloads else { return }

        let index = downloads.index
        let plan = SmartSyncPlanner(rules: rules).plan(
            favoriteIDs: favoriteIDs,
            favoriteAlbumTrackIDs: favoriteAlbumTrackIDs,
            mixes: mixes,
            downloadedIDs: Set(index.entries.keys),
            pinnedIDs: index.manuallyPinnedTrackIDs,
            estimatedBytes: tracksByID.mapValues { DownloadStorage.estimatedBytes(for: $0) }
        )
        // Tracks the plan wants that the server no longer returns are dropped
        // from the pin; already downloaded ones keep their stored metadata.
        var known = tracksByID
        for id in plan.desired where known[id] == nil {
            if let existing = index.entry(for: id)?.track { known[id] = existing }
        }
        downloads.applySmartSync(plan: plan, tracksByID: known)
        syncState.skippedForStorage = plan.skippedForStorage.count
        syncState.lastResult = .done(Date())
    }

    /// Brings downloaded playlists in line with their server content.
    private func resyncPlaylists(downloads: DownloadManager, online: MusicLibraryProviding) async throws {
        let playlistPins = downloads.index.pins.filter { $0.kind == .playlist }
        guard !playlistPins.isEmpty else { return }
        // The list gives current names / covers and tells us which playlists
        // still exist; a deleted playlist keeps its downloads until the user
        // removes them.
        let current = try await online.playlists()
        for pin in playlistPins {
            guard let playlist = current.first(where: { $0.id == pin.itemID }) else { continue }
            guard let tracks = try? await online.tracks(inPlaylist: pin.itemID) else { continue }
            // The pin may have been removed (or the user signed out) while
            // we were fetching.
            guard self.downloads === downloads, downloads.index.pin(id: pin.id) != nil else { continue }
            var serverIDs: [String] = []
            for track in tracks where !serverIDs.contains(track.id) { serverIDs.append(track.id) }
            let unchanged = serverIDs == pin.trackIDs && playlist.name == pin.title && playlist.imageTag == pin.imageTag
            if !unchanged {
                // Not a user request: paused or failed tracks stay as they are.
                downloads.setPin(DownloadPin.playlist(playlist, now: Date()), tracks: tracks, reviveStalled: false)
            }
        }
    }
}

/// What the settings screen shows about smart sync.
@MainActor
final class SmartSyncState: ObservableObject {
    enum Result: Equatable {
        case done(Date)
        case skippedOffline
        case skippedCellular
        case failed
    }

    @Published var isRunning = false
    @Published var lastResult: Result?
    /// Tracks left out by the storage limit in the last run.
    @Published var skippedForStorage = 0
}
