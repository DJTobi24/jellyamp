import SwiftUI
import JellyampCore

/// The signed-in app shell. Adapts to the horizontal size class:
///
/// - **compact** (iPhone, iPad in Slide Over / narrow Split View): the tab
///   bar with the mini player docked above it,
/// - **regular** (iPad, large iPhones in landscape once enabled): a sidebar
///   (Home, Search, the library lists, Downloads, Settings) with the mini
///   player docked at the bottom of the detail column.
///
/// Both layouts share `AppNavigator`, so the selected section and the
/// navigation paths survive rotation and multitasking size changes. The
/// shell also hosts what must exist once per window: toast banners, the
/// "Add to Playlist" sheet and the hardware-keyboard shortcuts.
struct AdaptiveShellView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var navigator = AppNavigator.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesSidebar: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if usesSidebar {
                SidebarShell()
            } else {
                TabShell()
            }
        }
        .tint(.white)
        .background { KeyboardShortcuts() }
        .libraryPresentation()
        .onAppear { navigator.layoutChanged(usesSidebar: usesSidebar) }
        .onChange(of: usesSidebar) { newValue in
            navigator.layoutChanged(usesSidebar: newValue)
        }
        .onDisappear {
            // The shell leaves the screen when the user signs out. The next
            // account must not inherit hearts, paths or search history.
            guard !container.isSignedIn else { return }
            navigator.reset()
            FavoritesModel.shared.reset()
            RecentSearches.clear()
        }
    }
}

// MARK: - Compact: tabs

private struct TabShell: View {
    @ObservedObject private var navigator = AppNavigator.shared

    var body: some View {
        TabView(selection: navigator.tabSelection) {
            HomeView()
                .dockedMiniPlayer()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppSection.home)
            LibraryView()
                .dockedMiniPlayer()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(AppSection.library)
            SearchView()
                .dockedMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppSection.search)
            DownloadsView()
                .dockedMiniPlayer()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .tag(AppSection.downloads)
            SettingsView()
                .dockedMiniPlayer()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppSection.settings)
        }
        .tabBarMinimizesOnScroll()
    }
}

// MARK: - Regular: sidebar

private struct SidebarShell: View {
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: navigator.sidebarBinding) {
                Section {
                    sidebarRow("Home", systemImage: "house", item: .section(.home))
                    sidebarRow("Search", systemImage: "magnifyingglass", item: .section(.search))
                }
                Section("Library") {
                    ForEach(LibraryCategory.allCases) { category in
                        Label(category.title, systemImage: category.systemImage)
                            .tag(SidebarItem.category(category))
                    }
                }
                Section {
                    sidebarRow("Downloads", systemImage: "arrow.down.circle", item: .section(.downloads))
                    sidebarRow("Settings", systemImage: "gearshape", item: .section(.settings))
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Jellyamp")
        } detail: {
            detail
                .dockedMiniPlayer()
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func sidebarRow(_ title: LocalizedStringKey, systemImage: String, item: SidebarItem) -> some View {
        Label(title, systemImage: systemImage)
            .tag(item)
    }

    /// Each section brings its own navigation stack. The library lists share
    /// the routed Library stack; `.id` gives every list its own state.
    @ViewBuilder
    private var detail: some View {
        switch navigator.sidebarSelection ?? .section(.home) {
        case .section(.home):
            HomeView()
        case .section(.search):
            SearchView()
        case .section(.downloads):
            DownloadsView()
        case .section(.settings):
            SettingsView()
        case .section(.library):
            RoutedNavigationStack(.library) {
                LibraryCategoryView(category: .albums)
            }
        case .category(let category):
            RoutedNavigationStack(.library) {
                LibraryCategoryView(category: category)
            }
            .id(category)
        }
    }
}

// MARK: - Shared pieces

extension View {
    /// Docks the mini player at the bottom of this view's safe area: above
    /// the tab bar on compact layouts, at the bottom of the detail column on
    /// regular ones. `MiniPlayerView` renders nothing while idle, so it adds
    /// no inset then. On wide layouts the bar keeps a comfortable width
    /// instead of stretching across the whole column.
    func dockedMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
    }

    /// For the root view of a full-screen cover (Now Playing). Menus used
    /// inside the cover then work as everywhere else: banners and the "Add
    /// to Playlist" sheet appear above the cover, and "Go to Album / Artist"
    /// closes the cover to reveal the destination.
    func libraryCoverPresentation() -> some View {
        modifier(LibraryCoverPresentation())
    }

    /// Hosts what the browsing screens present app-wide: toast banners and
    /// the "Add to Playlist" sheet. `AdaptiveShellView` applies it; apply it
    /// yourself only if the shell is not used.
    func libraryPresentation() -> some View {
        modifier(LibraryPresentation())
    }
}

private struct LibraryPresentation: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var navigator = AppNavigator.shared

    /// The root cannot present over a full-screen cover; while one is up
    /// (and hosts presentations itself) the request is left to it.
    private var rootPlaylistRequest: Binding<PlaylistAddRequest?> {
        Binding(
            get: { navigator.coverIsActive ? nil : navigator.playlistRequest },
            set: { navigator.playlistRequest = $0 }
        )
    }

    func body(content: Content) -> some View {
        content
            .toastHost()
            .sheet(item: rootPlaylistRequest) { request in
                AddToPlaylistView(request: request)
                    .environmentObject(container)
            }
            // Older call sites set `container.pendingPlaylistTrack`; route
            // them into the same sheet.
            .onChange(of: container.pendingPlaylistTrack) { track in
                guard let track else { return }
                container.pendingPlaylistTrack = nil
                navigator.playlistRequest = PlaylistAddRequest(track: track)
            }
    }
}

private struct LibraryCoverPresentation: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var navigator = AppNavigator.shared
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .toastHost()
            .sheet(item: $navigator.playlistRequest) { request in
                AddToPlaylistView(request: request)
                    .environmentObject(container)
            }
            .onAppear { navigator.coverIsActive = true }
            .onDisappear { navigator.coverIsActive = false }
            .onReceive(navigator.didNavigate) { _ in dismiss() }
    }
}

/// Hardware-keyboard shortcuts (iPad with a keyboard, Mac Catalyst):
/// space = play/pause, ⌘→ / ⌘← = next / previous, ⌘F = search.
/// Invisible buttons are how SwiftUI registers shortcuts before iOS 17's
/// `onKeyPress`; text fields keep priority, so typing a space still works.
private struct KeyboardShortcuts: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        Group {
            Button("Play or Pause") {
                if container.playerState.isPlaying {
                    container.player?.pause()
                } else {
                    container.player?.play()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Next Track") { container.player?.skipToNext() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { container.player?.skipToPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Search") { AppNavigator.shared.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
