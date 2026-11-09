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
    /// Set to present the Sonic Adventure builder starting from a track
    /// (driven from the track ⋯ menu, like `pendingPlaylistTrack`).
    @Published var pendingAdventureStart: Track?

    private(set) var library: MusicLibraryProviding?
    private(set) var sonic: SonicProviding?
    private(set) var player: PlayerEngine?
    /// Per-user on-disk cache so home shelves / lists paint instantly on launch
    /// and refresh in the background, instead of reloading from scratch.
    private(set) var libraryCache: LibraryCache?
    /// Offline downloads (download manager + on-disk store).
    private(set) var downloads: DownloadManager?
    /// Offline state (banner), the offline library decorator and smart sync.
    let offline = OfflineCoordinator()
    /// Lock screen / Control Center / interruption handling; alive as long
    /// as a session is active.
    private var systemMedia: SystemMediaController?
    /// Single shared bridge the player views observe; the active `EnginePlayer`
    /// pushes state into it. Lives for the whole app session.
    let playerState = PlayerStateModel()
    /// Last.fm / ListenBrainz scrobbling; follows `playerState` while signed in.
    let scrobbling = ScrobbleService()

    /// Autoplay ("radio"): when the queue runs low, append similar tracks.
    /// Follows the persisted setting.
    var autoplayEnabled: Bool { settings.autoplayEnabled }
    /// Endless stations (Home); while one plays it owns the queue refills.
    let stations = StationCoordinator()
    private let radioFeeder = RadioQueueFeeder()
    private var playHistory: [String] = []
    private var isRefillingRadio = false
    private var cancellables: Set<AnyCancellable> = []

    private let credentialStore = KeychainCredentialStore()
    private let settingsStore = UserDefaultsSettingsStore()

    var isSignedIn: Bool { session?.isAuthenticated ?? false }

    /// The one container of the process. Siri / Shortcuts intents and the
    /// CarPlay scene run without the SwiftUI window (the app may be launched
    /// in the background just for them), so they cannot get the container
    /// from the environment and reach it here instead.
    static let shared = DependencyContainer()
    private var bootstrapTask: Task<Void, Never>?
    /// True once `bootstrap()` has finished (signed in or not).
    private(set) var isBootstrapped = false

    /// Runs `bootstrap()` exactly once, whoever asks first — the window, an
    /// intent or CarPlay — and lets every other caller wait for that run.
    /// Calling `bootstrap()` twice would build a second audio engine.
    func ensureBootstrapped() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task {
            await self.bootstrap()
            self.isBootstrapped = true
            SystemIntegration.shared.attach(to: self)
        }
        bootstrapTask = task
        await task.value
    }

    func bootstrap() async {
        settings = settingsStore.loadSettings()
        if let stored = credentialStore.loadSession() {
            account = credentialStore.loadAccount()
            await activate(session: stored)
            // Not awaited: launch (and offline playback) must not wait for
            // the network.
            Task { await validateStoredSession() }
        }
    }

    // MARK: - Sign-in / session lifecycle

    /// Server name/version and user name for Settings → Account.
    @Published private(set) var account: JellyfinAccount?
    /// Shown by onboarding after the app signed the user out by itself
    /// (token revoked on the server). Cleared by the next successful sign-in.
    @Published var signedOutNotice: String?
    private var isRevalidatingSession = false

    /// Unauthenticated session for the onboarding flows (password sign-in,
    /// Quick Connect) against a server found by `JellyfinServerDiscovery`.
    func makeSignInSession(server: JellyfinServerInfo) -> JellyfinSession {
        JellyfinSession(serverURL: server.url, deviceID: Self.persistentDeviceID())
    }

    /// Persists and activates a session produced by `JellyfinAuthenticator`
    /// (`signIn` or `signInWithQuickConnect`).
    func completeSignIn(_ result: JellyfinSignInResult, server: JellyfinServerInfo) async {
        let account = JellyfinAccount(serverName: server.name, serverVersion: server.version, userName: result.userName)
        credentialStore.save(session: result.session, account: account)
        self.account = account
        signedOutNotice = nil
        await activate(session: result.session)
    }

    /// Checks the stored token with the server. Only an explicit rejection
    /// (HTTP 401) signs the user out; an unreachable server changes nothing,
    /// so downloaded music stays playable offline.
    func validateStoredSession() async {
        guard let current = session, current.isAuthenticated, !isRevalidatingSession else { return }
        isRevalidatingSession = true
        defer { isRevalidatingSession = false }
        switch await JellyfinAuthenticator().validate(session: current) {
        case .rejected:
            guard session == current else { return }
            signedOutNotice = String(localized: "Your Jellyfin server no longer accepts this device's sign-in. Please sign in again.")
            signOut()
        case .valid(let userName):
            // Refresh what Settings → Account shows (server renamed/updated).
            var refreshed = account ?? JellyfinAccount()
            if let userName { refreshed.userName = userName }
            if let info = try? await JellyfinServerDiscovery().probe(url: current.serverURL) {
                refreshed.serverName = info.name
                refreshed.serverVersion = info.version
            }
            guard session == current, refreshed != account else { return }
            account = refreshed
            credentialStore.save(session: current, account: refreshed)
        case .indeterminate:
            break
        }
    }

    /// Transport for the API clients: any 401 on an authenticated request
    /// triggers a re-validation, which signs out if the token is really dead.
    private func makeSessionTransport() -> HTTPTransport {
        UnauthorizedReportingTransport { [weak self] in
            Task { @MainActor [weak self] in
                await self?.validateStoredSession()
            }
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
        if let ending = session, ending.isAuthenticated {
            // Best effort: revoke the token server-side; never blocks or
            // fails the local sign-out (which must work offline).
            Task.detached { await JellyfinAuthenticator().logout(session: ending) }
        }
        account = nil
        credentialStore.clear()
        LibraryCache.clearAll()
        session = nil
        library = nil
        sonic = nil
        player = nil
        systemMedia = nil
        libraryCache = nil
        offline.deactivate()
        downloads?.clearAll()
        downloads = nil
        cancellables.removeAll()
        playHistory = []
        // Scrobbling accounts are personal: forget them with the session.
        scrobbling.signOut()
        settings.scrobbling = ScrobblingSettings()
        settingsStore.save(settings)
        stations.stop()
    }

    private func activate(session: JellyfinSession) async {
        self.session = session
        libraryCache = LibraryCache(scope: session.userID ?? "default")
        downloads = DownloadManager(session: session)
        library = MusicLibraryAPI(session: session, transport: makeSessionTransport())
        // Serve downloads when offline mode is on or the server is unreachable.
        if let downloads, let online = library {
            library = offline.activate(wrapping: online, downloads: downloads, container: self)
        }
        // Crossfade-capable engine (mixes two nodes). Swap back to
        // `EnginePlayer(...)` for the AVPlayer streaming engine if needed.
        let engine = AudioEnginePlayer(session: session, settings: settings, stateModel: playerState)
        player = engine
        if let preset = EQPreset.builtIn(id: settings.activeEQPresetID) {
            engine.apply(eqPreset: preset)
        }
        systemMedia = SystemMediaController(player: engine, playerState: playerState, session: session)
        setupAutoplay()
        scrobbling.start(playerState: playerState, settings: settings.scrobbling)
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
        stations.trackChanged(to: trackID, upNext: playerState.upNext)
        maybeRefillRadio()
    }

    private func maybeRefillRadio() {
        // A running station refills from its own source, also when plain
        // autoplay is switched off — starting a station asks for endless play.
        if stations.refillIfNeeded(container: self) { return }
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
           case .available(let capabilities) = await SonicServerDiscovery().probe(baseURL: url, apiKey: apiKey),
           !capabilities.capabilities.isEmpty {
            sonic = SonicAPIClient(baseURL: url, apiKey: apiKey)
            sonicCapabilities = capabilities
        } else {
            // Also taken while a freshly installed sonic server has not analyzed
            // anything yet (it reports no capabilities): Jellyfin's Instant Mix
            // keeps working until the first scan finishes.
            let fallback = JellyfinFallbackSonicProvider(source: InstantMixAdapter(api: InstantMixAPI(session: session, transport: makeSessionTransport())))
            sonic = fallback
            sonicCapabilities = fallback.capabilities
        }
    }

    /// Saves the optional jellyamp-server configuration and re-wires the
    /// provider. `url == nil` removes the server (and its key); a nil
    /// `newAPIKey` keeps the key already in the Keychain.
    func updateSonicServer(url: URL?, newAPIKey: String?) async {
        settings.sonicServerURL = url
        if url == nil {
            credentialStore.clearSonicAPIKey()
        } else if let newAPIKey, !newAPIKey.isEmpty {
            credentialStore.saveSonicAPIKey(newAPIKey)
        }
        saveSettings()
        await rewireSonicProvider()
    }

    /// The stored jellyamp-server key, for "Test connection" without retyping.
    var storedSonicAPIKey: String? { credentialStore.loadSonicAPIKey() }

    func saveSettings() {
        settingsStore.save(settings)
        player?.updateSettings(settings)
        scrobbling.apply(settings.scrobbling)
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
