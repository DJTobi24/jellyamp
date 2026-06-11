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

    private(set) var library: MusicLibraryProviding?
    private(set) var sonic: SonicProviding?
    private(set) var player: PlayerEngine?
    /// Single shared bridge the player views observe; the active `EnginePlayer`
    /// pushes state into it. Lives for the whole app session.
    let playerState = PlayerStateModel()

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
        session = nil
        library = nil
        sonic = nil
    }

    private func activate(session: JellyfinSession) async {
        self.session = session
        library = MusicLibraryAPI(session: session)
        player = EnginePlayer(session: session, settings: settings, stateModel: playerState)
        await rewireSonicProvider()
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
