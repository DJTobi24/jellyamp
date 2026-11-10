import SwiftUI
import JellyampCore

@main
struct JellyampApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared with Siri/Shortcuts intents and the CarPlay scene, which run
    // outside this view tree (see `DependencyContainer.shared`).
    @StateObject private var container = DependencyContainer.shared

    init() {
        // Core composes some user-facing text itself (counts, durations,
        // station titles) and only knows English; hand it the localized
        // strings before anything is drawn or spoken. `init` runs for every
        // launch, including background launches for Siri and CarPlay.
        CoreStrings.current = .localized
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.playerState)
                .preferredColorScheme(.dark)
                .task {
                    await container.ensureBootstrapped()
                }
        }
    }
}
