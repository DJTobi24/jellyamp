import SwiftUI
import JellyampCore
import JellyfinBackend

/// Paged, sortable album grid. One implementation behind "Albums", "Saved
/// Albums" and a genre's albums — they differ only in the filter.
///
/// Layout adapts on its own: as many columns as fit (2 on a phone, up to 8
/// on a wide iPad), and a plain list on phones at accessibility text sizes,
/// where captions under two narrow covers would be cut off after a few
/// letters.
struct AlbumBrowser: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var favorites = FavoritesModel.shared
    @StateObject private var loader = PagedLoader<Album>(pageSize: 100)
    @StateObject private var alphabet = AlphabetJumpController()
    @State private var sort = SortSelection(AlbumSortOption.name)
    @State private var downloadedOnly = false

    let filter: BrowseFilter
    /// Cache the first page of the default sort under this key.
    var cacheKey: String?
    /// Offer the "Downloaded only" toggle (full library only).
    var allowsDownloadedFilter = false
    var emptyTitle = String(localized: "No Albums")
    var emptyMessage = String(localized: "Albums in your Jellyfin library will appear here.")
    var emptySystemImage = "square.stack"

    private var usesList: Bool {
        dynamicTypeSize.isAccessibilitySize && horizontalSizeClass == .compact
    }

    private var minimumItemWidth: CGFloat {
        CGFloat(AdaptiveGrid.minimumItemWidth(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize))
    }

    /// Server rows, minus albums un-saved a moment ago in a favorites list.
    private var albums: [Album] {
        guard filter.favoritesOnly else { return loader.items }
        return loader.items.filter { favorites.isFavorite($0.id, serverValue: true) }
    }

    /// Albums reconstructed from downloaded tracks (fully in memory).
    private var downloadedAlbums: [Album] {
        var byAlbum: [String: Album] = [:]
        for track in container.downloads?.downloaded ?? [] {
            guard let albumID = track.albumID, byAlbum[albumID] == nil else { continue }
            byAlbum[albumID] = Album(
                id: albumID, title: track.albumName ?? track.title, artistName: track.artistName, imageTag: track.imageTag
            )
        }
        return byAlbum.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// A search-result list: the server orders it by relevance, so sorting
    /// and the A–Z index do not apply.
    private var isSearchResult: Bool { filter.searchTerm != nil }

    private var showsAlphabet: Bool {
        sort.showsAlphabetIndex && !isSearchResult && !downloadedOnly && !container.settings.offlineModeEnabled && !loader.state.isInitialLoading && loader.state.blockingError == nil
            && (alphabet.activeLetter != nil || (loader.state.totalCount ?? 0) > 60)
    }

    var body: some View {
        ScrollView {
            if downloadedOnly {
                collection(downloadedAlbums, paged: false)
            } else if loader.state.isInitialLoading {
                SkeletonGrid(minimumItemWidth: minimumItemWidth)
            } else {
                collection(albums, paged: true)
                PagingFooter(loader)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsAlphabet {
                AlphabetJumpBar(controller: alphabet, select: jump(to:)) {
                    alphabet.reset { await loader.jump(toOffset: $0) }
                }
            }
        }
        .overlay {
            if downloadedOnly, downloadedAlbums.isEmpty {
                EmptyStateView(
                    title: String(localized: "No Downloaded Albums"),
                    systemImage: "arrow.down.circle",
                    message: String(localized: "Download an album from its ⋯ menu to listen offline.")
                )
            }
        }
        .pagedListStatus(loader, isActive: !downloadedOnly) {
            EmptyStateView(title: emptyTitle, systemImage: emptySystemImage, message: emptyMessage)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isSearchResult {
                    Menu {
                        SortMenuItems(selection: $sort)
                        if allowsDownloadedFilter, container.downloads != nil {
                            Toggle("Downloaded Only", isOn: $downloadedOnly)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel(Text("Sort and filter"))
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

    @ViewBuilder
    private func collection(_ items: [Album], paged: Bool) -> some View {
        if usesList {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { album in
                    RouteLink(.album(album)) {
                        AlbumListRow(album: album)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .albumContextActions(album)
                    .onAppear { if paged { loader.loadMoreIfNeeded(showing: album) } }
                    Divider()
                }
            }
            .padding(.horizontal)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(items) { album in
                    RouteLink(.album(album)) {
                        AlbumGridCell(album: album)
                    }
                    .buttonStyle(.plain)
                    .albumContextActions(album)
                    .onAppear { if paged { loader.loadMoreIfNeeded(showing: album) } }
                }
            }
            .padding(.horizontal)
        }
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        alphabet.clear()
        let query = sort.query
        let filter = self.filter
        // Only the default view is worth caching: it is what the screen
        // opens with.
        let cacheable = sort == SortSelection(AlbumSortOption.name) ? cacheKey : nil
        let cache = container.libraryCache
        await loader.configure(
            key: AnyHashable(sort),
            cached: cacheable.flatMap { cache?.load([Album].self, for: $0) },
            onFirstPage: { page in
                if let cacheable { cache?.save(page, for: cacheable) }
            },
            fetch: { startIndex, limit in
                try await browser.albumsPage(sort: query, filter: filter, startIndex: startIndex, limit: limit)
            }
        )
    }

    private func jump(to letter: String) {
        guard let browser = container.browser else { return }
        let filter = self.filter
        alphabet.jump(
            to: letter,
            resolve: { try await browser.alphabetOffset(of: $0, kind: .albums, filter: filter) },
            apply: { await loader.jump(toOffset: $0) }
        )
    }
}
