import Foundation
import Combine
import UIKit
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
    /// Set to present the Sonic Adventure builder starting from a track
    /// (driven from the track ⋯ menu, which can't present a sheet itself).
    /// The "Add to Playlist" sheet is requested through
    /// `AppNavigator.playlistRequest`.
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
    /// Single shared bridge the player views observe; the active
    /// `AudioEnginePlayer` pushes state into it. Lives for the whole app
    /// session.
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
    private var settingsObserver: AnyCancellable?

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

    /// Only through `ensureBootstrapped()`.
    private func bootstrap() async {
        LaunchOptions.applyAtLaunch()
        settings = settingsStore.loadSettings()
        // Every change of `settings` is saved and handed to the engine, the
        // scrobbler and (through its own observer) the offline coordinator,
        // whichever screen made it. The settings screens were written by
        // different slices — some saved on every change, some when they
        // disappeared — and a toggle changed from a screen of the second
        // kind did not reach the running engine until then.
        settingsObserver = $settings
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // `@Published` emits before the value is stored.
                Task { @MainActor [weak self] in self?.saveSettings() }
            }
        installFavoritesHooks()
        if LaunchOptions.isHostingUnitTests {
            // The unit tests sign their own containers in and out.
            return
        }
        if DemoMode.shouldStartAtLaunch {
            // Before the Keychain is read: a demo launch must neither use
            // nor disturb a real sign-in.
            await enterDemoMode()
            return
        }
        if LaunchOptions.resetState {
            // A clean-slate launch (UI tests) shows onboarding even on a
            // device that is signed in; the stored session stays untouched.
            return
        }
        guard let stored = credentialStore.loadSession() else { return }
        guard stored.isAuthenticated else {
            // The last run ended with an expired sign-in (`expireSession`):
            // downloads and settings are still here, waiting for the same
            // user to sign in again.
            signedOutNotice = Self.sessionExpiredNotice
            return
        }
        account = credentialStore.loadAccount()
        await activate(session: stored)
        // Not awaited: launch (and offline playback) must not wait for
        // the network.
        Task { await validateStoredSession() }
    }

    // MARK: - Demo mode

    /// True while the app is signed in to the built-in sample library
    /// (`DemoMode`) instead of a Jellyfin server.
    @Published private(set) var isDemoMode = false

    /// Signs in to the built-in sample library. Nothing is written to the
    /// Keychain: a stored session of a real server stays as it is.
    func enterDemoMode() async {
        guard !isSignedIn else { return }
        do {
            // Remembered only when the user chose it; a launch argument
            // applies to that launch alone.
            let demoSession = try DemoMode.shared.start(deviceID: Self.persistentDeviceID(), remember: !LaunchOptions.demo)
            isDemoMode = true
            account = DemoMode.shared.account
            signedOutNotice = nil
            await activate(session: demoSession)
        } catch {
            isDemoMode = false
            signedOutNotice = String(localized: "The demo library could not be started. Please try again.")
        }
    }

    // MARK: - Sign-in / session lifecycle

    /// Server name/version and user name for Settings → Account.
    @Published private(set) var account: JellyfinAccount?
    /// Shown by onboarding after the app signed the user out by itself
    /// (token revoked on the server). Cleared by the next successful sign-in.
    @Published var signedOutNotice: String?
    private var isRevalidatingSession = false

    private static var sessionExpiredNotice: String {
        String(localized: "Your Jellyfin server no longer accepts this device's sign-in. Please sign in again. Your downloads and settings are still here.")
    }

    /// Unauthenticated session for the onboarding flows (password sign-in,
    /// Quick Connect) against a server found by `JellyfinServerDiscovery`.
    func makeSignInSession(server: JellyfinServerInfo) -> JellyfinSession {
        Self.identified(JellyfinSession(serverURL: server.url, deviceID: Self.persistentDeviceID()))
    }

    /// Persists and activates a session produced by `JellyfinAuthenticator`
    /// (`signIn` or `signInWithQuickConnect`).
    func completeSignIn(_ result: JellyfinSignInResult, server: JellyfinServerInfo) async {
        // After an expired sign-in the previous user's downloads, caches and
        // linked accounts are still on the device. The same user picks them
        // up again; anybody else must not inherit them.
        if let previous = credentialStore.loadSession(), !Self.isSameUser(previous, result.session) {
            wipeLocalData(downloads: nil)
        }
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
        // The demo session is not a stored one and must never become one.
        guard !isDemoMode else { return }
        guard let current = session, current.isAuthenticated, !isRevalidatingSession else { return }
        isRevalidatingSession = true
        defer { isRevalidatingSession = false }
        switch await JellyfinAuthenticator().validate(session: current) {
        case .rejected:
            guard session == current else { return }
            expireSession()
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
    /// triggers a re-validation, which ends the session if the token is
    /// really dead. For clients that are routed offline by a decorator
    /// (`library`, `browser`).
    func makeSessionTransport() -> HTTPTransport {
        UnauthorizedReportingTransport { [weak self] in
            Task { @MainActor [weak self] in
                await self?.validateStoredSession()
            }
        }
    }

    /// The session transport for clients that have nothing to serve offline
    /// (ID lookups, stations, Instant Mix, playback reports): while offline
    /// they fail at once instead of running into a timeout, and their
    /// request outcomes feed the same offline state as the library's.
    ///
    /// - Parameter marksUnreachable: false for background traffic whose
    ///   failure should not switch the app to downloads (playback reports).
    func makeGatedSessionTransport(marksUnreachable: Bool = true) -> HTTPTransport {
        OfflineGatedTransport(
            base: makeSessionTransport(),
            state: offline.status.tracker,
            marksUnreachable: marksUnreachable
        )
    }

    /// "Sign Out" chosen by the user: the device forgets the account and
    /// everything that belongs to it — downloads, cached library data, the
    /// sonic server key and the linked scrobbling accounts.
    func signOut() {
        if let ending = session, ending.isAuthenticated {
            // Best effort: revoke the token server-side; never blocks or
            // fails the local sign-out (which must work offline).
            Task.detached { await JellyfinAuthenticator().logout(session: ending) }
        }
        let downloads = self.downloads
        let leavingDemo = isDemoMode
        tearDownSession()
        if leavingDemo {
            // Leaving the demo must not sign the user out of a real server
            // whose session is still in the Keychain, nor remove their
            // scrobbling accounts: only what the demo itself created goes.
            isDemoMode = false
            DemoMode.shared.stop()
            LibraryCache.clearAll()
            downloads?.clearAll()
            return
        }
        credentialStore.clear()
        wipeLocalData(downloads: downloads)
    }

    /// The server rejected the token (revoked, expired, device removed).
    /// Nobody asked for this: gigabytes of downloads and the user's settings
    /// must not disappear because an admin restarted something. Everything
    /// stays on the device, only the session ends; onboarding explains why
    /// and offers the same server again. `completeSignIn` wipes the data if
    /// somebody else signs in instead.
    private func expireSession() {
        guard session != nil else { return }
        // Their URLs carry the dead token; they restart after the next sign-in.
        downloads?.suspendTransfers()
        tearDownSession()
        credentialStore.markSessionExpired()
        signedOutNotice = Self.sessionExpiredNotice
    }

    /// Stops everything that lives only while a session is active. Leaves
    /// what is stored on the device alone.
    private func tearDownSession() {
        // Explicitly, not by releasing it: something may still hold the
        // engine for a moment. Also sends the final "stopped" report and
        // clears `playerState`, which the lock screen follows.
        player?.shutdown()
        stations.stop()
        scrobbling.stop()
        cancellables.removeAll()
        playHistory = []
        isRefillingRadio = false
        systemMedia = nil
        player = nil
        offline.deactivate()
        downloads = nil
        library = nil
        sonic = nil
        sonicCapabilities = SonicCapabilities(capabilities: [])
        libraryCache = nil
        account = nil
        pendingAdventureStart = nil
        FavoritesModel.shared.reset()
        // Last: observers of `$session` (root view, CarPlay, Siri/Spotlight
        // integration) then find everything else already gone.
        session = nil
    }

    /// Removes what belongs to an account from the device.
    /// - Parameter downloads: the account's download manager if one is alive.
    private func wipeLocalData(downloads: DownloadManager?) {
        LibraryCache.clearAll()
        if let downloads {
            downloads.clearAll()
        } else {
            BackgroundDownloadSession.shared.cancelAll()
            DownloadStore.wipe()
        }
        credentialStore.clearSonicAPIKey()
        // Scrobbling accounts are personal: forget them with the account.
        scrobbling.signOut()
        settings.scrobbling = ScrobblingSettings()
        settingsStore.save(settings)
    }

    /// Jellyfin user IDs are GUIDs generated per server, so the ID alone
    /// identifies "this user on this server" — also when the server is
    /// reached under another address (LAN vs. public name) the next time.
    private static func isSameUser(_ lhs: JellyfinSession, _ rhs: JellyfinSession) -> Bool {
        func canonical(_ id: String?) -> String? {
            id.map { $0.replacingOccurrences(of: "-", with: "").lowercased() }
        }
        guard let left = canonical(lhs.userID), let right = canonical(rhs.userID) else { return false }
        return left == right
    }

    private func activate(session newSession: JellyfinSession) async {
        // Never two engines or two sets of remote-command handlers.
        if player != nil {
            player?.shutdown()
            systemMedia = nil
        }
        let session = Self.identified(newSession)
        self.session = session
        libraryCache = LibraryCache(scope: session.userID ?? "default")
        let downloads = DownloadManager(session: session)
        // A download refused with 401 is as good a hint as an API call.
        downloads.onUnauthorized = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.validateStoredSession()
            }
        }
        self.downloads = downloads
        // Serve downloads when offline mode is on or the server is unreachable.
        library = offline.activate(
            wrapping: MusicLibraryAPI(session: session, transport: makeSessionTransport()),
            downloads: downloads,
            container: self
        )
        // Crossfade-capable engine (mixes two nodes).
        let engine = AudioEnginePlayer(
            session: session,
            settings: settings,
            stateModel: playerState,
            reportTransport: makeGatedSessionTransport(marksUnreachable: false)
        )
        player = engine
        if let preset = EQPreset.builtIn(id: settings.activeEQPresetID) {
            engine.apply(eqPreset: preset)
        }
        // Loudness-leveling fallbacks, injected as closures so the engine
        // never sees the container: measured LUFS from the sonic server for
        // tracks without a NormalizationGain tag (cached on disk), and the
        // album's own gain for consecutive tracks of one album.
        let loudness = LoudnessService { [weak self] trackID in
            guard let self, let sonic = await self.loudnessCapableSonic() else { return nil }
            let measured = try await sonic.loudness(forTrack: trackID)
            return MeasuredLoudness(integratedLufs: measured.integratedLufs, truePeakDB: measured.truePeak)
        }
        engine.loudnessLookup = { trackID in await loudness.loudness(forTrack: trackID) }
        engine.albumGainLookup = { [weak self] albumID in
            guard let library = await self?.library else { return nil }
            return (try? await library.album(id: albumID))?.normalizationGainDB
        }
        // The lock screen's like command goes the same way as every heart
        // in the app (`FavoritesModel`).
        systemMedia = SystemMediaController(
            player: engine,
            playerState: playerState,
            session: session,
            isFavorite: { track in FavoritesModel.shared.isFavorite(track) },
            setFavorite: { [weak self] track, isFavorite in
                Task { @MainActor [weak self] in
                    try? await FavoritesModel.shared.set(
                        itemID: track.id,
                        isFavorite: isFavorite,
                        serverValue: track.isFavorite,
                        library: self?.library
                    )
                }
            }
        )
        setupAutoplay()
        // Made-up tracks have no business on someone's Last.fm profile.
        if !isDemoMode {
            scrobbling.start(playerState: playerState, settings: settings.scrobbling)
        }
        await rewireSonicProvider()
    }

    // MARK: - Favorites

    /// Connects `FavoritesModel` to the parts that keep their own copy of
    /// the flag or depend on the set of favorites. Installed once.
    private func installFavoritesHooks() {
        let favorites = FavoritesModel.shared
        favorites.onChange = { [weak self] itemID, isFavorite in
            // Queued copies of the track, and through `playerState` the Now
            // Playing screen, the lock screen and CarPlay.
            self?.player?.setFavorite(trackID: itemID, isFavorite: isFavorite)
        }
        favorites.onConfirmed = { [weak self] in
            guard let self else { return }
            // Favorite artists and albums are names Siri is told about.
            SystemIntegration.shared.refreshShortcutParameters()
            // "Auto-download favorites" follows the heart.
            let rules = self.settings.smartSync
            if rules.autoDownloadFavorites || rules.autoDownloadFavoriteAlbums {
                self.offline.requestSync()
            }
        }
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

    /// The sonic provider, but only when it can measure loudness.
    private func loudnessCapableSonic() -> SonicProviding? {
        sonicCapabilities.supports(.loudness) ? sonic : nil
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
        if isDemoMode, let demoURL = DemoMode.shared.baseURL,
           case .available(let capabilities) = await SonicServerDiscovery().probe(baseURL: demoURL, apiKey: DemoMode.shared.sonicAPIKey) {
            // The demo server also answers the Sonic API, so the sample
            // library shows Mixes for You and Sonic Adventure.
            sonic = SonicAPIClient(baseURL: demoURL, apiKey: DemoMode.shared.sonicAPIKey)
            sonicCapabilities = capabilities
            return
        }
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
            let fallback = JellyfinFallbackSonicProvider(
                source: InstantMixAdapter(api: InstantMixAPI(session: session, transport: makeGatedSessionTransport()))
            )
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

    /// Persists and applies the current settings. Runs by itself after every
    /// change (see `bootstrap`); calling it directly is only needed when the
    /// effect must not wait for the next main-actor turn.
    func saveSettings() {
        settingsStore.save(settings)
        player?.updateSettings(settings)
        scrobbling.apply(settings.scrobbling)
    }

    /// Stamps the session with what the server's device list should show:
    /// the kind of device and the real app version (the package defaults are
    /// placeholders). Not persisted — applied to every session we activate.
    private static func identified(_ session: JellyfinSession) -> JellyfinSession {
        var session = session
        // The name travels inside a quoted header value: plain ASCII only.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.")
        let name = String(UIDevice.current.name.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        session.deviceName = name.isEmpty ? UIDevice.current.model : name
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
            session.clientVersion = version
        }
        return session
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
