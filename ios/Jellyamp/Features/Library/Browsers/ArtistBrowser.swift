import SwiftUI
import JellyampCore
import JellyfinBackend

/// Paged, sortable artist list behind "Artists" and "Following".
struct ArtistBrowser: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var favorites = FavoritesModel.shared
    @StateObject private var loader = PagedLoader<Artist>(pageSize: 100)
    @StateObject private var alphabet = AlphabetJumpController()
    @State private var sort = SortSelection(ArtistSortOption.name)

    let filter: BrowseFilter
    var cacheKey: String?
    var emptyTitle = String(localized: "No Artists")
    var emptyMessage = String(localized: "Artists in your Jellyfin library will appear here.")
    var emptySystemImage = "music.mic"

    private var artists: [Artist] {
        guard filter.favoritesOnly else { return loader.items }
        return loader.items.filter { favorites.isFavorite($0.id, serverValue: true) }
    }

    /// A search-result list: the server orders it by relevance, so sorting
    /// and the A–Z index do not apply.
    private var isSearchResult: Bool { filter.searchTerm != nil }

    private var showsAlphabet: Bool {
        sort.showsAlphabetIndex && !isSearchResult && !container.offline.status.isOffline && !loader.state.isInitialLoading && loader.state.blockingError == nil
            && (alphabet.activeLetter != nil || (loader.state.totalCount ?? 0) > 60)
    }

    var body: some View {
        List {
            if loader.state.isInitialLoading {
                SkeletonRows(artwork: .circle)
            } else {
                ForEach(artists) { artist in
                    RouteLink(.artist(artist)) {
                        ArtistListRow(artist: artist)
                    }
                    .artistContextActions(artist)
                    .onAppear { loader.loadMoreIfNeeded(showing: artist) }
                }
                PagingFooter(loader)
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsAlphabet {
                AlphabetJumpBar(controller: alphabet, select: jump(to:)) {
                    alphabet.reset { await loader.jump(toOffset: $0) }
                }
            }
        }
        .pagedListStatus(loader) {
            EmptyStateView(title: emptyTitle, systemImage: emptySystemImage, message: emptyMessage)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isSearchResult {
                    SortMenu(selection: $sort)
                }
            }
        }
        .refreshable { await loader.refresh() }
        .task(id: sort) { await configure() }
        .onChange(of: favorites.confirmedChanges) { _ in
            guard filter.favoritesOnly else { return }
            Task { await loader.refresh() }
        }
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        alphabet.clear()
        let query = sort.query
        let filter = self.filter
        let cacheable = sort == SortSelection(ArtistSortOption.name) ? cacheKey : nil
        let cache = container.libraryCache
        await loader.configure(
            key: AnyHashable(sort),
            cached: cacheable.flatMap { cache?.load([Artist].self, for: $0) },
            onFirstPage: { page in
                if let cacheable { cache?.save(page, for: cacheable) }
            },
            fetch: { startIndex, limit in
                try await browser.artistsPage(sort: query, filter: filter, startIndex: startIndex, limit: limit)
            }
        )
    }

    private func jump(to letter: String) {
        guard let browser = container.browser else { return }
        let filter = self.filter
        alphabet.jump(
            to: letter,
            resolve: { try await browser.alphabetOffset(of: $0, kind: .artists, filter: filter) },
            apply: { await loader.jump(toOffset: $0) }
        )
    }
}
