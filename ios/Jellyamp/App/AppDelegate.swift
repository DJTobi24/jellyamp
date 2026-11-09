import UIKit
import AVFAudio

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            // Activate at launch so the audio engine, prepared during its own
            // init, sees an active session with a valid hardware output format
            // (otherwise the engine's first start can fail to render).
            try session.setActive(true)
        } catch {
            assertionFailure("audio session setup failed: \(error)")
        }
    }
}
