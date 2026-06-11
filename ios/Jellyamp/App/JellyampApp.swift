import SwiftUI

@main
struct JellyampApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = DependencyContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.playerState)
                .preferredColorScheme(.dark)
                .task {
                    await container.bootstrap()
                }
        }
    }
}
