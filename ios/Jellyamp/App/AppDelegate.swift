import UIKit
import AVFAudio

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A launch the user did not see — background downloads finishing, a
        // Shortcuts automation, CarPlay connecting — must not silence
        // whatever other app is playing: only set the category then. The
        // engine activates the session itself right before it starts
        // (`AudioEnginePlayer.startEngineIfNeeded`), so playback started by
        // an intent or from the car still works.
        configureAudioSession(activate: application.applicationState != .background)
        return true
    }

    /// The system relaunched (or woke) the app because background downloads
    /// finished; hand the completion handler to the download session.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadSession.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }

    private func configureAudioSession(activate: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            guard activate else { return }
            // Activate at a foreground launch so the audio engine, prepared
            // during its own init, sees an active session with a valid
            // hardware output format (otherwise the engine's first start can
            // fail to render). After a background launch the engine gets the
            // same through `startEngineIfNeeded`, which activates the session
            // and prepares the engine again before starting it.
            try session.setActive(true)
        } catch {
            assertionFailure("audio session setup failed: \(error)")
        }
    }
}
