import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        if container.isSignedIn {
            // Tabs on compact width, sidebar on regular width; also hosts the
            // mini player, toast banners and the "Add to Playlist" sheet.
            AdaptiveShellView()
        } else {
            OnboardingView()
        }
    }
}
