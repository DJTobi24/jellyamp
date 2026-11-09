import SwiftUI
import JellyampCore
import JellyfinBackend

/// Paged, sortable, searchable song list behind "Songs", "Liked Songs" and a
/// genre's songs. Never loads the whole list: rows arrive a page at a time,
/// search runs on the server, and Shuffle asks the server for a random
/// sample instead of shuffling what happens to be loaded.
struct TrackBrowser: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @ObservedObject private var favorites = FavoritesModel.shared
    @StateObject private var loader = PagedLoader<Track>(pageSize: 100)
    @StateObject private var alphabet = AlphabetJumpController()
    @State private var sort: SortSelection<TrackSortOption>
    @State private var searchText = ""

    private let filter: BrowseFilter
    private let cacheKey: String?
    private let searchPrompt: String
    private let emptyTitle: String
    private let emptyMessage: String
    private let emptySystemImage: String
    private let playlistTitle: String

    /// What identifies the server query; a change restarts the list.
    private struct QueryKey: Hashable {
        var sort: SortSelection<TrackSortOption>
        var search: String
    }

    init(
        filter: BrowseFilter,
        defaultSort: TrackSortOption = .title,
        cacheKey: String? = nil,
        searchPrompt: String = String(localized: "Search songs"),
        emptyTitle: String = String(localized: "No Songs"),
        emptyMessage: String = String(localized: "Songs in your Jellyfin library will appear here."),
        emptySystemImage: String = "music.note",
        playlistTitle: String = String(localized: "Songs")
    ) {
        self.filter = filter
        self.cacheKey = cacheKey
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.emptySystemImage = emptySystemImage
        self.playlistTitle = playlistTitle
        _sort = State(initialValue: SortSelection(defaultSort))
    }

    /// A search-result list ("See All" songs): the query comes with the
    /// filter, so there is no search field, sorting or A–Z index.
    private var isSearchResult: Bool { filter.searchTerm != nil }
    private var searchTerm: String? { filter.searchTerm ?? SearchQueryPolicy.effectiveQuery(searchText) }
    private var queryKey: QueryKey { QueryKey(sort: sort, search: searchTerm ?? "") }

    private var effectiveFilter: BrowseFilter {
        var result = filter
        result.searchTerm = searchTerm
        return result
    }

    /// Server rows, minus songs un-liked a moment ago in a favorites list.
    private var tracks: [Track] {
        guard filter.favoritesOnly else { return loader.items }
        return loader.items.filter { favorites.isFavorite($0.id, serverValue: true) }
    }

    private var showsAlphabet: Bool {
        sort.showsAlphabetIndex && searchTerm == nil && !container.settings.offlineModeEnabled && !loader.state.isInitialLoading && loader.state.blockingError == nil
            && (alphabet.activeLetter != nil || (loader.state.totalCount ?? 0) > 60)
    }

    private var subtitle: TrackRow.Subtitle {
        sort.option == .album ? .artistAndAlbum : .artist
    }

    var body: some View {
        List {
            if loader.state.isInitialLoading {
                SkeletonRows()
            } else {
                if !tracks.isEmpty, searchTerm == nil || isSearchResult {
                    header
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, subtitle: subtitle) {
                        play(at: index)
                    }
                    .onAppear { loader.loadMoreIfNeeded(showing: track) }
                }
                PagingFooter(loader)
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .scrollDismissesKeyboard(.immediately)
        .modifier(OptionalSearchField(text: $searchText, prompt: searchPrompt, isEnabled: !isSearchResult))
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsAlphabet {
                AlphabetJumpBar(controller: alphabet, select: jump(to:)) {
                    alphabet.reset { await loader.jump(toOffset: $0) }
                }
            }
        }
        .pagedListStatus(loader) {
            if let searchTerm {
                EmptyStateView(
                    title: String(localized: "No Results"),
                    systemImage: "magnifyingglass",
                    message: String(localized: "Nothing matches “\(searchTerm)”.")
                )
            } else {
                EmptyStateView(title: emptyTitle, systemImage: emptySystemImage, message: emptyMessage)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isSearchResult {
                    SortMenu(selection: $sort)
                }
            }
        }
        .refreshable { await loader.refresh() }
        .task(id: queryKey) { await configure() }
        .onChange(of: favorites.confirmedChanges) { _ in
            guard filter.favoritesOnly else { return }
            Task { await loader.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayShuffleBar(isEnabled: true, play: { play(at: 0) }, shuffle: shuffleAll) {
                CollectionMenuButton(tracks: tracks, title: playlistTitle)
            }
            if let total = loader.state.totalCount {
                Text(total == 1 ? "1 song" : "\(total) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Loading

    private func configure() async {
        guard let browser = container.browser else { return }
        if searchTerm != nil, !isSearchResult {
            // Debounce typing; `.task(id:)` cancels this when the text changes.
            try? await Task.sleep(nanoseconds: SearchQueryPolicy.debounceNanoseconds)
            guard !Task.isCancelled else { return }
        }
        alphabet.clear()
        let query = sort.query
        let filter = effectiveFilter
        let isDefaultView = searchTerm == nil && sort == SortSelection(TrackSortOption.title)
        let cacheable = isDefaultView ? cacheKey : nil
        let cache = container.libraryCache
        await loader.configure(
            key: AnyHashable(queryKey),
            cached: cacheable.flatMap { cache?.load([Track].self, for: $0) },
            onFirstPage: { page in
                if let cacheable { cache?.save(page, for: cacheable) }
            },
            fetch: { startIndex, limit in
                try await browser.tracksPage(sort: query, filter: filter, startIndex: startIndex, limit: limit)
            }
        )
    }

    private func jump(to letter: String) {
        guard let browser = container.browser else { return }
        let filter = effectiveFilter
        alphabet.jump(
            to: letter,
            resolve: { try await browser.alphabetOffset(of: $0, kind: .tracks, filter: filter) },
            apply: { await loader.jump(toOffset: $0) }
        )
    }

    // MARK: - Playback

    private func play(at index: Int) {
        guard let queue = PlayQueueWindow.queue(from: tracks, tappedIndex: index) else { return }
        container.player?.load(queue: queue)
    }

    /// Shuffle of the whole (possibly huge) list: a random page from the
    /// server, not a shuffle of the rows loaded so far.
    private func shuffleAll() {
        guard let browser = container.browser else { return }
        let filter = effectiveFilter
        let loaded = tracks
        let reachedEnd = loader.state.reachedEnd && loader.state.baseOffset == 0
        let actions = LibraryActions(container: container, section: section)
        if reachedEnd {
            actions.shuffle(loaded)
            return
        }
        actions.withTracks({
            try await browser.tracksPage(sort: TrackSortOption.random.query(), filter: filter, startIndex: 0, limit: 300).items
        }, perform: { actions.shuffle($0) })
    }
}

/// Adds a search field unless the list is itself a search result.
private struct OptionalSearchField: ViewModifier {
    @Binding var text: String
    let prompt: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: Text(prompt))
        } else {
            content
        }
    }
}
