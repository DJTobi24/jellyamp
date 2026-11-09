import SwiftUI
import JellyampCore
import JellyfinBackend

/// The Search tab: owns its navigation stack.
struct SearchView: View {
    var body: some View {
        RoutedNavigationStack(.search) {
            SearchScreen()
        }
    }
}

/// Search field with grouped results; recent searches and genre tiles while
/// the field is empty.
struct SearchScreen: View {
    private enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var navigator = AppNavigator.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var results = GroupedSearchResults()
    /// The query `results` belong to (they stay on screen while the next
    /// query is in flight).
    @State private var resultsQuery = ""
    @State private var phase: Phase = .idle
    @State private var recents = RecentSearches.loadList()
    @State private var genres: [Genre] = []
    @State private var genresPhase: LoadPhase = .loading

    /// How many rows of each kind are shown before "See All".
    private let previewCount = 4
    private let songPreviewCount = 6
    /// Results fetched per kind for the overview.
    private let fetchLimit = 24

    private var effectiveQuery: String? { SearchQueryPolicy.effectiveQuery(query) }

    private var minimumTileWidth: CGFloat {
        CGFloat(AdaptiveGrid.minimumItemWidth(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize))
    }

    var body: some View {
        Group {
            if effectiveQuery != nil {
                resultsList
            } else {
                browse
            }
        }
        .navigationTitle("Search")
        .modifier(SearchField(text: $query, isPresented: $isSearchPresented))
        .onSubmit(of: .search) { record(query) }
        .task(id: query) { await runSearch() }
        .task { await loadGenres() }
        .onChange(of: navigator.searchFocusRequests) { _ in
            isSearchPresented = true
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        List {
            if phase == .searching, results.isEmpty {
                SkeletonRows(count: 8)
            } else if !results.isEmpty {
                if let top = results.topResult {
                    Section {
                        topResultRow(top)
                    } header: {
                        Text("Top Result")
                    }
                }
                artistsSection
                albumsSection
                songsSection
                playlistsSection
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if case .failed(let message) = phase {
                ErrorStateView(title: String(localized: "Search Failed"), message: message) {
                    Task { await runSearch(debounce: false) }
                }
            } else if phase == .loaded, results.isEmpty {
                EmptyStateView(
                    title: String(localized: "No Results"),
                    systemImage: "magnifyingglass",
                    message: String(localized: "Nothing in your library matches “\(resultsQuery)”. Check the spelling or try fewer words.")
                )
            }
        }
        // While a newer query is in flight the previous results stay, dimmed.
        .opacity(phase == .searching && !results.isEmpty ? 0.55 : 1)
    }

    @ViewBuilder
    private func topResultRow(_ hit: SearchHit) -> some View {
        switch hit {
        case .artist(let artist):
            RouteLink(.artist(artist)) { ArtistListRow(artist: artist) }
                .artistContextActions(artist)
                .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
        case .album(let album):
            RouteLink(.album(album)) { AlbumListRow(album: album) }
                .albumContextActions(album)
                .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
        case .playlist(let playlist):
            RouteLink(.playlist(playlist)) { PlaylistListRow(playlist: playlist) }
                .playlistContextActions(playlist)
                .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
        case .track(let track):
            TrackRow(track: track, subtitle: .artistAndAlbum) {
                play(track)
            }
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        if !results.artists.isEmpty {
            Section {
                ForEach(results.artists.prefix(previewCount)) { artist in
                    RouteLink(.artist(artist)) { ArtistListRow(artist: artist) }
                        .artistContextActions(artist)
                        .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
                }
            } header: {
                groupHeader(String(localized: "Artists"), scope: .artists, count: results.artists.count, preview: previewCount)
            }
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        if !results.albums.isEmpty {
            Section {
                ForEach(results.albums.prefix(previewCount)) { album in
                    RouteLink(.album(album)) { AlbumListRow(album: album) }
                        .albumContextActions(album)
                        .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
                }
            } header: {
                groupHeader(String(localized: "Albums"), scope: .albums, count: results.albums.count, preview: previewCount)
            }
        }
    }

    @ViewBuilder
    private var songsSection: some View {
        if !results.tracks.isEmpty {
            Section {
                ForEach(results.tracks.prefix(songPreviewCount)) { track in
                    TrackRow(track: track, subtitle: .artistAndAlbum) {
                        play(track)
                    }
                }
            } header: {
                groupHeader(String(localized: "Songs"), scope: .songs, count: results.tracks.count, preview: songPreviewCount)
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        if !results.playlists.isEmpty {
            Section {
                ForEach(results.playlists.prefix(previewCount)) { playlist in
                    RouteLink(.playlist(playlist)) { PlaylistListRow(playlist: playlist) }
                        .playlistContextActions(playlist)
                        .simultaneousGesture(TapGesture().onEnded { record(resultsQuery) })
                }
            } header: {
                groupHeader(String(localized: "Playlists"), scope: .playlists, count: results.playlists.count, preview: previewCount)
            }
        }
    }

    /// Section title with a "See All" link when there is more than the
    /// preview shows (or the fetch limit was hit, so the server has more).
    private func groupHeader(_ title: String, scope: SearchScope, count: Int, preview: Int) -> some View {
        HStack {
            Text(title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if count > preview {
                RouteLink(.searchResults(scope, query: resultsQuery)) {
                    Text("See All")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(Text("See all \(title)"))
            }
        }
    }

    // MARK: - Browse (empty query)

    private var browse: some View {
        List {
            if !recents.isEmpty {
                Section {
                    ForEach(recents.terms, id: \.self) { term in
                        Button {
                            query = term
                            isSearchPresented = true
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                                .frame(minHeight: 32)
                        }
                        .accessibilityHint(Text("Searches again"))
                    }
                    .onDelete { offsets in
                        // Resolve the offsets first: removing shifts them.
                        let removed = offsets.filter { recents.terms.indices.contains($0) }.map { recents.terms[$0] }
                        for term in removed {
                            recents.remove(term)
                        }
                        RecentSearches.save(recents)
                    }
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear") {
                            recents.clear()
                            RecentSearches.save(recents)
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .accessibilityLabel(Text("Clear recent searches"))
                    }
                }
            }
            Section {
                genreTiles
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
            } header: {
                Text("Browse Genres")
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await loadGenres(force: true) }
    }

    @ViewBuilder
    private var genreTiles: some View {
        if !genres.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: 12)], spacing: 12) {
                ForEach(genres) { genre in
                    RouteLink(.genre(genre)) {
                        GenreTile(name: genre.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if genresPhase == .loading {
            SkeletonGrid(count: 6, minimumItemWidth: minimumTileWidth)
        } else if let message = genresPhase.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await loadGenres(force: true) }
                }
            }
        } else {
            Text("Your library has no genres yet.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Logic

    /// Runs for every change of the text (`.task(id:)` cancels the previous
    /// run): waits out the debounce, searches, ranks and groups.
    private func runSearch(debounce: Bool = true) async {
        guard let term = effectiveQuery, let library = container.library else {
            results = GroupedSearchResults()
            resultsQuery = ""
            phase = .idle
            return
        }
        phase = .searching
        if debounce {
            try? await Task.sleep(nanoseconds: SearchQueryPolicy.debounceNanoseconds)
            guard !Task.isCancelled else { return }
        }
        do {
            let found = try await library.search(query: term, limit: fetchLimit)
            guard !Task.isCancelled else { return }
            results = SearchRanker.group(
                query: term, tracks: found.tracks, albums: found.albums, artists: found.artists, playlists: found.playlists
            )
            resultsQuery = term
            phase = .loaded
        } catch {
            guard !Task.isCancelled, !LibraryErrorText.isCancellation(error) else { return }
            results = GroupedSearchResults()
            resultsQuery = term
            phase = .failed(LibraryErrorText.message(for: error))
        }
    }

    private func loadGenres(force: Bool = false) async {
        guard force || genres.isEmpty, let browser = container.browser else { return }
        let cache = container.libraryCache
        if genres.isEmpty, let cached = cache?.load([Genre].self, for: LibraryCacheKey.genres) {
            genres = cached
        }
        if genres.isEmpty { genresPhase = .loading }
        do {
            let page = try await browser.genresPage(startIndex: 0, limit: 200)
            genres = page.items
            genresPhase = .loaded
            cache?.save(page.items, for: LibraryCacheKey.genres)
        } catch {
            guard !LibraryErrorText.isCancellation(error) else { return }
            genresPhase = genres.isEmpty ? .failed(LibraryErrorText.message(for: error)) : .loaded
        }
    }

    /// Plays the tapped song and queues the other song results behind it.
    private func play(_ track: Track) {
        record(resultsQuery)
        let songs = results.tracks
        let index = songs.firstIndex { $0.id == track.id } ?? 0
        container.player?.load(queue: PlayQueue(tracks: songs.isEmpty ? [track] : songs, startAt: index))
    }

    private func record(_ term: String) {
        recents.add(term)
        RecentSearches.save(recents)
    }
}

/// `.searchable` with programmatic focus (⌘F) where the system offers it.
private struct SearchField: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.searchable(text: $text, isPresented: $isPresented, prompt: Text("Artists, albums, songs, playlists"))
        } else {
            content.searchable(text: $text, prompt: Text("Artists, albums, songs, playlists"))
        }
    }
}

/// Colored genre tile for the browse grid. The hue is derived from the name
/// with a stable hash, so a genre keeps its color across launches.
struct GenreTile: View {
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [color, color.opacity(0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(10)
        }
        .frame(minHeight: 80)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
    }

    /// Brightness 0.45 keeps white text at 4.5:1 or better for every hue
    /// (yellow and green are the critical ones).
    private var color: Color {
        Color(hue: StableColor.hue(for: name), saturation: 0.6, brightness: 0.45)
    }
}

/// Last few search terms, persisted in UserDefaults.
enum RecentSearches {
    private static let key = "jellyamp.recentSearches"

    static func loadList() -> RecentSearchList {
        RecentSearchList(terms: UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ list: RecentSearchList) {
        UserDefaults.standard.set(list.terms, forKey: key)
    }

    /// Forget the history (sign-out).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
