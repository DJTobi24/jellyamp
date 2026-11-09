import SwiftUI

@main
struct JellyampApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared with Siri/Shortcuts intents and the CarPlay scene, which run
    // outside this view tree (see `DependencyContainer.shared`).
    @StateObject private var container = DependencyContainer.shared

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
