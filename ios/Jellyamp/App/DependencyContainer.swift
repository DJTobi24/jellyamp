import Foundation
import Combine
import JellyampCore
import JellyfinBackend
import SonicClient

/// Wires protocol seams to live implementations. Created once at launch;
/// re-wires the sonic provider whenever the server settings change.
@MainActor
final class DependencyContainer: ObservableObject {
    @Published private(set) var session: JellyfinSession?
    @Published private(set) var sonicCapabilities = SonicCapabilities(capabilities: [])
    @Published var settings = AppSettings()
    /// Set to present the "Add to Playlist" sheet for a track (driven from the
    /// track ⋯ menu, which can't present a sheet itself).
    @Published var pendingPlaylistTrack: Track?

    private(set) var library: MusicLibraryProviding?
    private(set) var sonic: SonicProviding?
    private(set) var player: PlayerEngine?
    /// Per-user on-disk cache so home shelves / lists paint instantly on launch
    /// and refresh in the background, instead of reloading from scratch.
    private(set) var libraryCache: LibraryCache?
    /// Offline downloads (download manager + on-disk store).
    private(set) var downloads: DownloadManager?
    /// Lock screen / Control Center / interruption handling; alive as long
    /// as a session is active.
    private var systemMedia: SystemMediaController?
    /// Single shared bridge the player views observe; the active `EnginePlayer`
    /// pushes state into it. Lives for the whole app session.
    let playerState = PlayerStateModel()

    /// Autoplay ("radio"): when the queue runs low, append similar tracks.
    var autoplayEnabled = true
    private let radioFeeder = RadioQueueFeeder()
    private var playHistory: [String] = []
    private var isRefillingRadio = false
    private var cancellables: Set<AnyCancellable> = []

    private let credentialStore = KeychainCredentialStore()
    private let settingsStore = UserDefaultsSettingsStore()

    var isSignedIn: Bool { session?.isAuthenticated ?? false }

    func bootstrap() async {
        settings = settingsStore.loadSettings()
        if let stored = credentialStore.loadSession() {
            await activate(session: stored)
        }
    }

    func signIn(serverURL: URL, username: String, password: String) async throws {
        let fresh = JellyfinSession(serverURL: serverURL, deviceID: Self.persistentDeviceID())
        let authenticated = try await JellyfinAuthenticator().authenticateByName(
            session: fresh,
            username: username,
            password: password
        )
        credentialStore.save(session: authenticated)
        await activate(session: authenticated)
    }

    func signOut() {
        credentialStore.clear()
        LibraryCache.clearAll()
        session = nil
        library = nil
        sonic = nil
        player = nil
        systemMedia = nil
        libraryCache = nil
        downloads?.clearAll()
        downloads = nil
        cancellables.removeAll()
        playHistory = []
    }

    private func activate(session: JellyfinSession) async {
        self.session = session
        libraryCache = LibraryCache(scope: session.userID ?? "default")
        downloads = DownloadManager(session: session)
        library = MusicLibraryAPI(session: session)
        let engine = EnginePlayer(session: session, settings: settings, stateModel: playerState)
        player = engine
        systemMedia = SystemMediaController(player: engine, playerState: playerState, session: session)
        setupAutoplay()
        await rewireSonicProvider()
    }

    // MARK: - Autoplay / radio

    /// Watches the playing track; records history and tops up the queue with
    /// similar tracks when it runs low, so playback never just stops.
    private func setupAutoplay() {
        cancellables.removeAll()
        playHistory = []
        playerState.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] id in
                guard let id else { return }
                Task { @MainActor in self?.handleTrackChanged(to: id) }
            }
            .store(in: &cancellables)
    }

    private func handleTrackChanged(to trackID: String) {
        playHistory.append(trackID)
        if playHistory.count > 200 { playHistory.removeFirst(playHistory.count - 200) }
        maybeRefillRadio()
    }

    private func maybeRefillRadio() {
        guard autoplayEnabled, !isRefillingRadio,
              radioFeeder.needsRefill(remaining: playerState.upNext.count),
              let seed = playerState.currentTrack?.id,
              let sonic, let library, let player else { return }
        isRefillingRadio = true
        Task {
            defer { isRefillingRadio = false }
            guard let similar = try? await sonic.similarTracks(to: seed, limit: radioFeeder.batchSize * 3) else { return }
            let candidates = (try? await library.tracks(byIDs: similar.map(\.itemID))) ?? []
            var queuedIDs = playerState.upNext.map(\.id)
            if let current = playerState.currentTrack?.id { queuedIDs.append(current) }
            let fresh = radioFeeder.selectTracks(from: candidates, queuedIDs: queuedIDs, historyIDs: playHistory)
            guard !fresh.isEmpty else { return }
            player.enqueue(fresh)
        }
    }

    /// Picks jellyamp-server when configured and healthy, else the
    /// Jellyfin-only fallback. The UI follows `sonicCapabilities`.
    func rewireSonicProvider() async {
        guard let session else { return }
        if let url = settings.sonicServerURL,
           let apiKey = credentialStore.loadSonicAPIKey(),
           case .available(let capabilities) = await SonicServerDiscovery().probe(baseURL: url, apiKey: apiKey) {
            sonic = SonicAPIClient(baseURL: url, apiKey: apiKey)
            sonicCapabilities = capabilities
        } else {
            let fallback = JellyfinFallbackSonicProvider(source: InstantMixAdapter(api: InstantMixAPI(session: session)))
            sonic = fallback
            sonicCapabilities = fallback.capabilities
        }
    }

    func saveSettings() {
        settingsStore.save(settings)
    }

    private static func persistentDeviceID() -> String {
        let key = "jellyamp.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

/// Bridges JellyfinBackend's InstantMixAPI to the protocol SonicClient's
/// fallback provider expects (keeps the two packages independent).
struct InstantMixAdapter: JellyfinSmartSource {
    let api: InstantMixAPI

    func instantMix(seedID: String, limit: Int) async throws -> [String] {
        try await api.instantMix(seedID: seedID, limit: limit)
    }

    func similarItems(to itemID: String, limit: Int) async throws -> [String] {
        try await api.similarItems(to: itemID, limit: limit)
    }

    func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String] {
        try await api.randomTracks(genre: genre, yearRange: yearRange, limit: limit)
    }
}
