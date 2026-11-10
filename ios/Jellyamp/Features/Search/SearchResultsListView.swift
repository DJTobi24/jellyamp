import SwiftUI
import JellyampCore
import JellyfinBackend

/// "See All" for one kind of search result: the complete, paged list of
/// matches for a query. Reuses the library browsers with a search filter.
struct SearchResultsListView: View {
    let scope: SearchScope
    let query: String

    private var filter: BrowseFilter { BrowseFilter(searchTerm: query) }
    private var emptyTitle: String { String(localized: "No Results") }
    private var emptyMessage: String { String(localized: "Nothing matches “\(query)”.") }

    var body: some View {
        Group {
            switch scope {
            case .artists:
                ArtistBrowser(filter: filter, emptyTitle: emptyTitle, emptyMessage: emptyMessage, emptySystemImage: "magnifyingglass")
            case .albums:
                AlbumBrowser(filter: filter, emptyTitle: emptyTitle, emptyMessage: emptyMessage, emptySystemImage: "magnifyingglass")
            case .songs:
                TrackBrowser(
                    filter: filter,
                    emptyTitle: emptyTitle,
                    emptyMessage: emptyMessage,
                    emptySystemImage: "magnifyingglass",
                    playlistTitle: query
                )
            case .playlists:
                PlaylistSearchResults(query: query)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch scope {
        case .artists: return String(localized: "Artists: “\(query)”")
        case .albums: return String(localized: "Albums: “\(query)”")
        case .songs: return String(localized: "Songs: “\(query)”")
        case .playlists: return String(localized: "Playlists: “\(query)”")
        }
    }
}

/// Paged playlist matches.
private struct PlaylistSearchResults: View {
    @EnvironmentObject private var container: DependencyContainer
    @StateObject private var loader = PagedLoader<Playlist>(pageSize: 50)
    let query: String

    var body: some View {
        List {
            if loader.state.isInitialLoading {
                SkeletonRows()
            } else {
                ForEach(loader.items) { playlist in
                    RouteLink(.playlist(playlist)) {
                        PlaylistListRow(playlist: playlist)
                    }
                    .playlistContextActions(playlist)
                    .onAppear { loader.loadMoreIfNeeded(showing: playlist) }
                }
                PagingFooter(loader)
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .pagedListStatus(loader) {
            EmptyStateView(
                title: String(localized: "No Results"),
                systemImage: "magnifyingglass",
                message: String(localized: "Nothing matches “\(query)”.")
            )
        }
        .refreshable { await loader.refresh() }
        .task { await configure() }
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        let filter = BrowseFilter(searchTerm: query)
        await loader.configure(key: AnyHashable(query)) { startIndex, limit in
            try await browser.playlistsPage(
                sort: PlaylistSortOption.name.query(), filter: filter, startIndex: startIndex, limit: limit
            )
        }
    }
}
