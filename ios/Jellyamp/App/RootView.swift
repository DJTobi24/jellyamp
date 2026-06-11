import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        if container.isSignedIn {
            mainTabs
        } else {
            OnboardingView()
        }
    }

    private var mainTabs: some View {
        TabView {
            HomeView()
                .miniPlayerInset()
                .tabItem { Label("Home", systemImage: "house.fill") }
            LibraryView()
                .miniPlayerInset()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
            SearchView()
                .miniPlayerInset()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            DownloadsView()
                .miniPlayerInset()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            SettingsView()
                .miniPlayerInset()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.white)
        .tabBarMinimizesOnScroll()
    }
}

private extension View {
    /// Docks the mini player just *above* the tab bar. Applied per-tab (not on
    /// the `TabView`): a bottom safe-area inset on the tab content sits above
    /// the bar, whereas one on the `TabView` itself overlaps the tab buttons.
    /// `MiniPlayerView` renders nothing when idle, so it adds no inset then.
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
    }
}
