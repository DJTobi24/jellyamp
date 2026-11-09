import SwiftUI
import JellyampCore

struct ArtistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var artists: [Artist] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var sortBy = "SortName"   // or "Random"

    private let pageSize = 100

    var body: some View {
        List {
            ForEach(artists) { artist in
                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                    HStack {
                        ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                            .clipShape(Circle())
                        Text(artist.name)
                    }
                }
                .artistContextActions(artist)
                .onAppear {
                    if artist.id == artists.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Artists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortBy) {
                        Text("Name").tag("SortName")
                        Text("Random").tag("Random")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: sortBy) { _ in Task { await loadMore(reset: true) } }
        .task {
            guard artists.isEmpty else { return }
            if let cached = container.libraryCache?.load([Artist].self, for: LibraryCacheKey.allArtists) {
                artists = cached
            }
            await loadMore(reset: true)
        }
    }

    private func loadMore(reset: Bool = false) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let startIndex = reset ? 0 : artists.count
        guard let page = try? await container.library?.artists(sortBy: sortBy, startIndex: startIndex, limit: pageSize) else { return }
        if reset {
            artists = page
            if sortBy == "SortName" { container.libraryCache?.save(page, for: LibraryCacheKey.allArtists) }
        } else {
            artists += page
        }
        reachedEnd = page.count < pageSize
    }
}
