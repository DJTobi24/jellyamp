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
                .tabItem { Label("Home", systemImage: "house.fill") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.white)
        .tabBarMinimizesOnScroll()
        .safeAreaInset(edge: .bottom) {
            MiniPlayerView()
        }
    }
}
