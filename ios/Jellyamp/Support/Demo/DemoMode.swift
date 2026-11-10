import Foundation
import UIKit
import JellyfinBackend
import JellyfinDemo

/// Demo mode: the app signed in to a sample library that lives inside the
/// app (`JellyfinDemo` package) instead of a Jellyfin server.
///
/// It exists for three audiences: App Review and curious people without a
/// server ("Try the Demo" on the sign-in screen), UI tests, and App Store
/// screenshots (`-JellyampDemo YES`). The demo library is served by a
/// loopback HTTP server that speaks the Jellyfin API, so the rest of the app
/// — API clients, artwork loading, the streaming player, downloads — runs
/// exactly the code it runs against a real server and knows nothing of this.
///
/// Nothing in demo mode touches the Keychain session or a real server:
/// `DependencyContainer` activates the session returned here directly, and
/// signing out stops the server again.
@MainActor
final class DemoMode {
    static let shared = DemoMode()

    /// Remembers "Try the Demo" across launches, until sign-out.
    private static let persistedKey = "jellyamp.demoMode"

    private var server: DemoHTTPServer?

    /// True when this launch should come up in the demo: asked for by launch
    /// argument, or entered earlier and never signed out of.
    static var shouldStartAtLaunch: Bool {
        LaunchOptions.demo || UserDefaults.standard.bool(forKey: persistedKey)
    }

    /// Base URL of the running demo server, nil while demo mode is off.
    var baseURL: URL? { server?.baseURL }

    /// Starts the demo server (if needed) and returns an authenticated
    /// session for it. The port is picked by the system on every launch; the
    /// session is never stored, so that does not matter.
    func start(deviceID: String, remember: Bool) throws -> JellyfinSession {
        let running: DemoHTTPServer
        if let server {
            running = server
        } else {
            running = DemoHTTPServer(backend: DemoBackend())
            server = running
        }
        let url = try running.start()
        if remember {
            UserDefaults.standard.set(true, forKey: Self.persistedKey)
        }
        return JellyfinSession(
            serverURL: url,
            deviceID: deviceID,
            accessToken: DemoCatalog.accessToken,
            userID: DemoCatalog.userID
        )
    }

    /// What Settings → Account shows in demo mode.
    var account: JellyfinAccount {
        JellyfinAccount(
            serverName: DemoCatalog.serverName,
            serverVersion: DemoCatalog.serverVersion,
            userName: DemoCatalog.userName
        )
    }

    /// The demo also answers the Sonic API (Mixes for You, Sonic Adventure).
    var sonicAPIKey: String { DemoCatalog.sonicAPIKey }

    /// Leaves demo mode: the server stops and its in-memory state (playlists
    /// created, favorites changed) is gone.
    func stop() {
        server?.stop()
        server = nil
        UserDefaults.standard.removeObject(forKey: Self.persistedKey)
    }
}

/// Launch arguments understood by the app. They exist for UI tests and
/// screenshots and are passed as `-Name YES` (read through the argument
/// domain of `UserDefaults`); no build ships a way to set them.
///
/// - `-JellyampDemo YES`: come up signed in to the demo library.
/// - `-JellyampResetState YES`: start from a clean slate — default settings,
///   no downloads, no caches, no remembered demo mode — and ignore a stored
///   sign-in for this launch (the Keychain itself is left alone).
/// - `-JellyampDisableAnimations YES`: no UIKit animations, so tests do not
///   wait for transitions.
enum LaunchOptions {
    static var demo: Bool { UserDefaults.standard.bool(forKey: "JellyampDemo") }
    static var resetState: Bool { UserDefaults.standard.bool(forKey: "JellyampResetState") }
    static var disableAnimations: Bool { UserDefaults.standard.bool(forKey: "JellyampDisableAnimations") }

    /// Called once, before anything reads settings or builds UI.
    @MainActor
    static func applyAtLaunch() {
        if disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
        if resetState {
            resetPersistentState()
        }
    }

    @MainActor private static var didReset = false

    /// Wipes what the app keeps on disk, except the Keychain.
    @MainActor
    static func resetPersistentState() {
        guard !didReset else { return }
        didReset = true
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier {
            // Settings, the remembered server address, recent searches, the
            // demo flag. Launch arguments live in another domain and stay.
            defaults.removePersistentDomain(forName: domain)
        }
        LibraryCache.clearAll()
        DownloadStore.wipe()
    }
}
