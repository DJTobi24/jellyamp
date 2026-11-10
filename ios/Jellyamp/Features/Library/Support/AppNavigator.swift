import SwiftUI
import Combine
import JellyampCore

/// Top-level areas of the app: the tabs on iPhone, sidebar entries on iPad.
enum AppSection: String, Hashable, CaseIterable {
    case home, library, search, downloads, settings
}

/// The lists reachable from the Library root (and the iPad sidebar).
enum LibraryCategory: String, Hashable, CaseIterable, Identifiable {
    case playlists, artists, albums, songs, genres, likedSongs, savedAlbums, following

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return String(localized: "Playlists")
        case .artists: return String(localized: "Artists")
        case .albums: return String(localized: "Albums")
        case .songs: return String(localized: "Songs")
        case .genres: return String(localized: "Genres")
        case .likedSongs: return String(localized: "Liked Songs")
        case .savedAlbums: return String(localized: "Saved Albums")
        case .following: return String(localized: "Following")
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .genres: return "guitars"
        case .likedSongs: return "heart.fill"
        case .savedAlbums: return "heart.rectangle"
        case .following: return "heart.circle"
        }
    }
}

/// Which kind of result a "See All" search list shows.
enum SearchScope: String, Hashable {
    case artists, albums, songs, playlists
}

/// Everything the browsing screens can navigate to. Value-based, so a route
/// can be pushed programmatically from anywhere ("Go to Album" in a menu, a
/// Siri intent, the Now Playing screen).
enum LibraryRoute: Hashable {
    case category(LibraryCategory)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case genre(Genre)
    case searchResults(SearchScope, query: String)

    /// The album a track belongs to. The detail screen loads the full album,
    /// so the few fields a track knows are enough to start with.
    static func albumRoute(for track: Track) -> LibraryRoute? {
        guard let albumID = track.albumID else { return nil }
        return .album(Album(id: albumID, title: track.albumName ?? "", artistName: "", imageTag: track.imageTag))
    }

    static func artistRoute(for track: Track) -> LibraryRoute? {
        guard let artistID = track.artistID else { return nil }
        return .artist(Artist(id: artistID, name: track.artistName))
    }

    static func artistRoute(for album: Album) -> LibraryRoute? {
        guard let artistID = album.artistID else { return nil }
        return .artist(Artist(id: artistID, name: album.artistName))
    }
}

/// Entries of the iPad sidebar.
enum SidebarItem: Hashable {
    case section(AppSection)
    case category(LibraryCategory)
}

/// App-wide navigation state.
///
/// Each section that wraps its content in `RoutedNavigationStack` gets a
/// path stored here. `open(_:from:)` pushes a route onto the stack the user
/// is looking at when that stack is routed, and otherwise switches to the
/// Library section and pushes there — so "Go to Artist" works from every
/// tab, from the mini player and from Now Playing.
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    /// Selected tab (compact width).
    @Published var selectedSection: AppSection = .home
    /// Selected sidebar entry (regular width).
    @Published var sidebarSelection: SidebarItem? = .section(.home)
    @Published private var paths: [AppSection: [LibraryRoute]] = [:]
    /// Set to present the "Add to Playlist" sheet.
    @Published var playlistRequest: PlaylistAddRequest?
    /// True while a full-screen cover that hosts its own presentations
    /// (Now Playing) is up; the root then leaves sheets to the cover.
    @Published var coverIsActive = false
    /// Bumped to ask the search screen to focus its field (⌘F).
    @Published private(set) var searchFocusRequests = 0

    /// Fires after every programmatic navigation, so a full-screen cover
    /// (Now Playing) can dismiss itself to reveal the destination.
    let didNavigate = PassthroughSubject<LibraryRoute, Never>()

    /// True while the split-view layout is on screen; decides whether
    /// `open` moves the tab or the sidebar selection.
    var usesSidebar = false
    private var routedSections: Set<AppSection> = []
    private var lastCategory: LibraryCategory = .albums

    func path(for section: AppSection) -> Binding<[LibraryRoute]> {
        Binding(
            get: { self.paths[section] ?? [] },
            set: { self.paths[section] = $0 }
        )
    }

    func register(_ section: AppSection) {
        routedSections.insert(section)
    }

    /// Navigates to `route`. `section` is the routed stack the request comes
    /// from (`@Environment(\.routedSection)`), nil when unknown.
    func open(_ route: LibraryRoute, from section: AppSection? = nil) {
        if let section, routedSections.contains(section), isVisible(section) {
            paths[section, default: []].append(route)
        } else {
            show(.library)
            paths[.library, default: []].append(route)
        }
        didNavigate.send(route)
    }

    /// Switches to a section (tab or sidebar entry).
    func show(_ section: AppSection) {
        selectedSection = section
        if usesSidebar {
            switch section {
            case .library:
                if case .category? = sidebarSelection { return }
                sidebarSelection = .category(lastCategory)
            default:
                sidebarSelection = .section(section)
            }
        }
    }

    func popToRoot(_ section: AppSection) {
        paths[section] = []
    }

    /// Tab binding that pops to the root when the selected tab is tapped
    /// again, like the system apps do.
    var tabSelection: Binding<AppSection> {
        Binding(
            get: { self.selectedSection },
            set: { newValue in
                if newValue == self.selectedSection {
                    self.popToRoot(newValue)
                } else {
                    self.selectedSection = newValue
                }
            }
        )
    }

    /// Sidebar binding; choosing another library list starts it at its root.
    var sidebarBinding: Binding<SidebarItem?> {
        Binding(
            get: { self.sidebarSelection },
            set: { newValue in
                guard let newValue, newValue != self.sidebarSelection else { return }
                self.sidebarSelection = newValue
                switch newValue {
                case .section(let section):
                    self.selectedSection = section
                case .category(let category):
                    self.lastCategory = category
                    self.selectedSection = .library
                    self.paths[.library] = []
                }
            }
        )
    }

    /// Keeps tab and sidebar in step when the layout changes (rotation,
    /// Split View, Slide Over).
    func layoutChanged(usesSidebar: Bool) {
        self.usesSidebar = usesSidebar
        guard usesSidebar else { return }
        switch selectedSection {
        case .library:
            if case .category? = sidebarSelection { return }
            sidebarSelection = .category(lastCategory)
            paths[.library] = []
        default:
            sidebarSelection = .section(selectedSection)
        }
    }

    func focusSearch() {
        show(.search)
        popToRoot(.search)
        searchFocusRequests += 1
    }

    /// Clears navigation state (sign-out).
    func reset() {
        paths = [:]
        selectedSection = .home
        sidebarSelection = .section(.home)
        playlistRequest = nil
    }

    private func isVisible(_ section: AppSection) -> Bool {
        selectedSection == section
    }
}

private struct RoutedSectionKey: EnvironmentKey {
    static let defaultValue: AppSection? = nil
}

extension EnvironmentValues {
    /// The routed navigation stack a view lives in, if any.
    var routedSection: AppSection? {
        get { self[RoutedSectionKey.self] }
        set { self[RoutedSectionKey.self] = newValue }
    }
}

/// A `NavigationStack` whose path lives in `AppNavigator`, with the library
/// destinations registered. Any tab can adopt it by replacing
/// `NavigationStack {` with `RoutedNavigationStack(.home) {`; routes opened
/// from that tab are then pushed in place instead of switching to Library.
struct RoutedNavigationStack<Root: View>: View {
    @ObservedObject private var navigator = AppNavigator.shared
    private let section: AppSection
    private let root: Root

    init(_ section: AppSection, @ViewBuilder root: () -> Root) {
        self.section = section
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: navigator.path(for: section)) {
            root
                .navigationDestination(for: LibraryRoute.self) { route in
                    LibraryRouteDestination(route: route)
                }
        }
        .environment(\.routedSection, section)
        .onAppear { navigator.register(section) }
    }
}

/// A navigation link to a library route that works in both kinds of stack:
/// value-based inside a `RoutedNavigationStack`, destination-based inside a
/// plain `NavigationStack` (screens of other features that push library
/// views without adopting routing).
struct RouteLink<Label: View>: View {
    @Environment(\.routedSection) private var section
    private let route: LibraryRoute
    private let label: Label

    init(_ route: LibraryRoute, @ViewBuilder label: () -> Label) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        if section != nil {
            NavigationLink(value: route) { label }
        } else {
            NavigationLink(destination: LibraryRouteDestination(route: route)) { label }
        }
    }
}

/// Maps a route to its screen.
struct LibraryRouteDestination: View {
    let route: LibraryRoute

    var body: some View {
        switch route {
        case .category(let category):
            LibraryCategoryView(category: category)
        case .album(let album):
            AlbumDetailView(album: album)
        case .artist(let artist):
            ArtistDetailView(artist: artist)
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .genre(let genre):
            GenreDetailView(genre: genre)
        case .searchResults(let scope, let query):
            SearchResultsListView(scope: scope, query: query)
        }
    }
}

/// The root screen of a library list.
struct LibraryCategoryView: View {
    let category: LibraryCategory

    var body: some View {
        switch category {
        case .playlists: PlaylistsView()
        case .artists: ArtistsView()
        case .albums: AlbumsGridView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .likedSongs: LikedSongsView()
        case .savedAlbums: SavedAlbumsView()
        case .following: FollowedArtistsView()
        }
    }
}
