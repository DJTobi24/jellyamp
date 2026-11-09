import Combine
import Foundation
import JellyampCore
import Network
import UIKit

/// Why connecting a scrobbling account did not work, in words for the UI.
struct ScrobbleConnectError: Error {
    let message: String
}

/// App-shell end of scrobbling: forwards what `PlayerStateModel` publishes to
/// the `ScrobbleCoordinator`, hands the resulting actions to the
/// `ScrobbleEngine`, and owns the account credentials. All decisions (when a
/// play counts, queueing, retries) live in JellyampCore; this only adapts.
@MainActor
final class ScrobbleService: ObservableObject {
    /// Queue length / last error per service, for the settings screen.
    @Published private(set) var status = ScrobbleStatus()
    @Published private(set) var isLastFMConnected = false
    @Published private(set) var hasListenBrainzToken = false

    /// Nil when this build carries no Last.fm API key (see `LastFMConfiguration`).
    let lastFMCredentials: LastFMCredentials? = LastFMConfiguration.credentials

    private let keychain = KeychainCredentialStore()
    private let engine = ScrobbleEngine(store: FileScrobbleQueueStore())
    private let webAuthenticator = LastFMWebAuthenticator()
    private var coordinator = ScrobbleCoordinator()
    private var settings = ScrobblingSettings()
    private var playerCancellables: Set<AnyCancellable> = []
    private var lifecycleCancellables: Set<AnyCancellable> = []
    private var pathMonitor: NWPathMonitor?
    /// A Last.fm token the user was sent to approve but that could not be
    /// exchanged yet; tried again first on the next "Connect".
    private var pendingLastFMToken: String?

    init() {
        isLastFMConnected = keychain.loadLastFMSessionKey() != nil
        hasListenBrainzToken = keychain.loadListenBrainzToken() != nil
    }

    // MARK: - Lifecycle

    /// Begin following the player. Safe to call again (e.g. after a new sign-in).
    func start(playerState: PlayerStateModel, settings: ScrobblingSettings) {
        stop()
        self.settings = settings
        coordinator = ScrobbleCoordinator()

        // `currentTrack` is re-published on every state change, so only a
        // change of id is a new track; repeat-one replays are recognised by
        // the coordinator from the position wrapping around.
        playerState.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in
                let now = Date()
                Task { @MainActor in self?.trackChanged(to: track, at: now) }
            }
            .store(in: &playerCancellables)

        playerState.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                let now = Date()
                Task { @MainActor in self?.playingChanged(isPlaying, at: now) }
            }
            .store(in: &playerCancellables)

        // The engine ticks ten times a second; two samples a second are
        // plenty to measure played time.
        playerState.$currentTime
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] position in
                let now = Date()
                Task { @MainActor in self?.positionChanged(to: position, at: now) }
            }
            .store(in: &playerCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
            .store(in: &lifecycleCancellables)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.djtobi.jellyamp.scrobble-path"))
        pathMonitor = monitor

        reconfigure(thenFlush: true)
    }

    func stop() {
        playerCancellables.removeAll()
        lifecycleCancellables.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        coordinator = ScrobbleCoordinator()
    }

    /// The scrobbling settings changed (toggle, account connected, …).
    func apply(_ newSettings: ScrobblingSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        reconfigure(thenFlush: true)
    }

    /// Jellyfin sign-out: the next person using the app must not scrobble to
    /// the previous person's accounts.
    func signOut() {
        stop()
        keychain.clearScrobblingCredentials()
        pendingLastFMToken = nil
        isLastFMConnected = false
        hasListenBrainzToken = false
        settings = ScrobblingSettings()
        Task {
            _ = await engine.discardPending(for: .listenBrainz)
            _ = await engine.discardPending(for: .lastFM)
            let configured = await engine.configure(targets: [], queueOnly: [])
            status = configured
        }
    }

    /// Try to deliver queued listens now ("Send Now" and automatic triggers).
    func flush(ignoringBackoff: Bool = false) {
        Task {
            let updated = await engine.flush(ignoringBackoff: ignoringBackoff)
            received(updated)
        }
    }

    // MARK: - ListenBrainz account

    /// Checks the token with the server and stores it. Returns the user name.
    func connectListenBrainz(token rawToken: String, serverURL: URL?) async -> Result<String, ScrobbleConnectError> {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failure(ScrobbleConnectError(message: String(localized: "Paste your ListenBrainz user token first.")))
        }
        let client = ListenBrainzClient(
            token: token,
            baseURL: serverURL ?? ListenBrainzClient.defaultBaseURL,
            clientVersion: Self.appVersion
        )
        do {
            guard let username = try await client.tokenOwner() else {
                return .failure(ScrobbleConnectError(message: String(localized: "ListenBrainz did not accept this token.")))
            }
            keychain.saveListenBrainzToken(token)
            hasListenBrainzToken = true
            return .success(username)
        } catch {
            return .failure(ScrobbleConnectError(message: String(localized: "ListenBrainz could not be reached. Check your connection and the server address.")))
        }
    }

    func disconnectListenBrainz() {
        keychain.deleteListenBrainzToken()
        hasListenBrainzToken = false
        Task {
            let updated = await engine.discardPending(for: .listenBrainz)
            status = updated
        }
    }

    // MARK: - Last.fm account

    /// Runs the Last.fm web authorization and stores the session key.
    /// Returns the Last.fm user name.
    func connectLastFM() async -> Result<String, ScrobbleConnectError> {
        guard let credentials = lastFMCredentials else {
            return .failure(ScrobbleConnectError(message: String(localized: "This build has no Last.fm API key.")))
        }
        let client = LastFMClient(credentials: credentials)

        // The user may have approved an earlier attempt after closing the sheet.
        if let token = pendingLastFMToken, let session = try? await client.getSession(token: token) {
            return .success(store(session))
        }

        do {
            let token = try await client.getToken()
            pendingLastFMToken = token
            await webAuthenticator.present(client.authorizationURL(token: token))
            let session = try await client.getSession(token: token)
            return .success(store(session))
        } catch let error as LastFMError {
            switch error.kind {
            case .authorizationPending:
                return .failure(ScrobbleConnectError(message: String(localized: "Access was not approved on Last.fm. Tap Connect and choose “Yes, allow access”.")))
            case .invalidToken:
                pendingLastFMToken = nil
                return .failure(ScrobbleConnectError(message: String(localized: "The Last.fm sign-in expired. Please try again.")))
            case .invalidAPIKey:
                return .failure(ScrobbleConnectError(message: String(localized: "Last.fm rejected this app's API key.")))
            case .retryLater:
                return .failure(ScrobbleConnectError(message: String(localized: "Last.fm is temporarily unavailable. Please try again later.")))
            case .invalidSession, .other:
                return .failure(ScrobbleConnectError(message: String(localized: "Last.fm sign-in failed.")))
            }
        } catch {
            return .failure(ScrobbleConnectError(message: String(localized: "Last.fm could not be reached. Check your connection.")))
        }
    }

    func disconnectLastFM() {
        keychain.deleteLastFMSessionKey()
        pendingLastFMToken = nil
        isLastFMConnected = false
        Task {
            let updated = await engine.discardPending(for: .lastFM)
            status = updated
        }
    }

    private func store(_ session: LastFMSession) -> String {
        keychain.saveLastFMSessionKey(session.key)
        pendingLastFMToken = nil
        isLastFMConnected = true
        return session.username
    }

    // MARK: - Player events

    private func trackChanged(to track: Track?, at now: Date) {
        perform(coordinator.trackChanged(to: track, at: now))
    }

    private func playingChanged(_ isPlaying: Bool, at now: Date) {
        perform(coordinator.playbackStateChanged(isPlaying: isPlaying, at: now))
    }

    private func positionChanged(to position: TimeInterval, at now: Date) {
        perform(coordinator.progress(position: position, at: now))
    }

    private func perform(_ actions: [ScrobbleAction]) {
        guard !actions.isEmpty else { return }
        Task {
            let updated = await engine.perform(actions)
            received(updated)
        }
    }

    // MARK: - Engine configuration

    private func reconfigure(thenFlush: Bool) {
        var targets: [ScrobbleTarget] = []
        var queueOnly: Set<ScrobbleServiceID> = []

        if settings.listenBrainzEnabled {
            if let token = keychain.loadListenBrainzToken() {
                let client = ListenBrainzClient(
                    token: token,
                    baseURL: settings.listenBrainzServerURL ?? ListenBrainzClient.defaultBaseURL,
                    clientVersion: Self.appVersion
                )
                targets.append(ListenBrainzScrobbleTarget(client: client))
            } else {
                // Switched on but the token was rejected: keep collecting
                // listens until the user enters a new one.
                queueOnly.insert(.listenBrainz)
            }
        }

        if settings.lastFMEnabled, let credentials = lastFMCredentials {
            if let sessionKey = keychain.loadLastFMSessionKey() {
                let client = LastFMClient(credentials: credentials, sessionKey: sessionKey)
                targets.append(LastFMScrobbleTarget(client: client))
            } else {
                queueOnly.insert(.lastFM)
            }
        }

        let configuredTargets = targets
        let configuredQueueOnly = queueOnly
        Task {
            var updated = await engine.configure(targets: configuredTargets, queueOnly: configuredQueueOnly)
            if thenFlush {
                updated = await engine.flush()
            }
            received(updated)
        }
    }

    /// Publishes a new status and reacts to credentials a service refused:
    /// the dead token / session key is forgotten so the settings screen asks
    /// the user to connect again, while listens keep being queued.
    private func received(_ updated: ScrobbleStatus) {
        status = updated
        var credentialsDropped = false
        if updated.needsReauthentication.contains(.lastFM), keychain.loadLastFMSessionKey() != nil {
            keychain.deleteLastFMSessionKey()
            isLastFMConnected = false
            credentialsDropped = true
        }
        if updated.needsReauthentication.contains(.listenBrainz), keychain.loadListenBrainzToken() != nil {
            keychain.deleteListenBrainzToken()
            hasListenBrainzToken = false
            credentialsDropped = true
        }
        if credentialsDropped {
            reconfigure(thenFlush: false)
        }
    }

    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
