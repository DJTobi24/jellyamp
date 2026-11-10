import SwiftUI
import JellyampCore
import JellyfinBackend

/// All music genres, as colored tiles (a list at accessibility text sizes).
struct GenresView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var loader = PagedLoader<Genre>(pageSize: 200)

    private var minimumItemWidth: CGFloat {
        CGFloat(AdaptiveGrid.minimumItemWidth(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize))
    }

    var body: some View {
        ScrollView {
            if loader.state.isInitialLoading {
                SkeletonGrid(minimumItemWidth: minimumItemWidth)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 12)], spacing: 12) {
                    ForEach(loader.items) { genre in
                        RouteLink(.genre(genre)) {
                            GenreTile(name: genre.name)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.Item.genre(genre.id))
                        .onAppear { loader.loadMoreIfNeeded(showing: genre) }
                    }
                }
                .padding(.horizontal)
                PagingFooter(loader)
            }
        }
        .navigationTitle("Genres")
        .pagedListStatus(loader) {
            EmptyStateView(
                title: String(localized: "No Genres"),
                systemImage: "guitars",
                message: String(localized: "Genres appear once your music is tagged with them.")
            )
        }
        .refreshable { await loader.refresh() }
        .task { await configure() }
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        let cache = container.libraryCache
        await loader.configure(
            key: AnyHashable("genres"),
            cached: cache?.load([Genre].self, for: LibraryCacheKey.genres),
            onFirstPage: { cache?.save($0, for: LibraryCacheKey.genres) },
            fetch: { startIndex, limit in
                try await browser.genresPage(startIndex: startIndex, limit: limit)
            }
        )
    }
}
