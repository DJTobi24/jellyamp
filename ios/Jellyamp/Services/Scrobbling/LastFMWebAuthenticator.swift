import AuthenticationServices
import Foundation
import JellyampCore
import UIKit

/// The app's Last.fm API account, read from Info.plist.
///
/// `LastFMAPIKey` / `LastFMAPISecret` are filled from the `LASTFM_API_KEY` /
/// `LASTFM_API_SECRET` build settings (see `ios/Config/Secrets.example.xcconfig`)
/// so they are never committed. A build without them simply has no Last.fm
/// support: the settings screen explains that instead of offering "Connect".
enum LastFMConfiguration {
    static var credentials: LastFMCredentials? {
        LastFMCredentials(
            configuredAPIKey: Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String,
            configuredSecret: Bundle.main.object(forInfoDictionaryKey: "LastFMAPISecret") as? String
        )
    }
}

/// Shows the Last.fm "allow access" page in the system web-auth sheet.
///
/// Last.fm's token flow for native apps has no redirect back into the app:
/// the user approves on the page and then closes the sheet. So this only
/// reports that the sheet was dismissed; whether access was granted is found
/// out afterwards by asking Last.fm for the session.
@MainActor
final class LastFMWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Presents `url` and returns once the sheet has been closed.
    func present(_ url: URL) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "jellyamp") { _, _ in
                gate.run { continuation.resume() }
            }
            webSession.presentationContextProvider = self
            // Share Safari's cookies so a user already signed in to Last.fm
            // only has to tap "Allow access".
            webSession.prefersEphemeralWebBrowserSession = false
            session = webSession
            if !webSession.start() {
                gate.run { continuation.resume() }
            }
        }
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        if let anyWindow = scenes.first?.windows.first {
            return anyWindow
        }
        return ASPresentationAnchor()
    }
}

/// Guards a continuation against being resumed twice (a failed `start()`
/// and the completion handler could otherwise both fire).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}
