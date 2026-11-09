import SwiftUI
import JellyampCore

/// Sort options for the albums grid; maps to Jellyfin `sortBy`/`sortOrder`.
enum AlbumSort: String, CaseIterable, Identifiable {
    case name, recentlyAdded, year, artist, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .recentlyAdded: return "Recently Added"
        case .year: return "Year"
        case .artist: return "Artist"
        case .random: return "Random"
        }
    }
    var sortBy: String {
        switch self {
        case .name: return "SortName"
        case .recentlyAdded: return "DateCreated"
        case .year: return "ProductionYear"
        case .artist: return "AlbumArtist,SortName"
        case .random: return "Random"
        }
    }
    var sortOrder: String {
        switch self {
        case .recentlyAdded, .year: return "Descending"
        default: return "Ascending"
        }
    }
}

struct AlbumsGridView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var sort: AlbumSort = .name
    @State private var downloadedOnly = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let pageSize = 100

    /// Albums to show: the paginated library, or — when filtered — albums
    /// reconstructed from downloaded tracks (fully in memory, no paging).
    private var displayedAlbums: [Album] {
        downloadedOnly ? downloadedAlbums : albums
    }

    private var downloadedAlbums: [Album] {
        var byAlbum: [String: Album] = [:]
        for track in container.downloads?.downloaded ?? [] {
            guard let albumID = track.albumID, byAlbum[albumID] == nil else { continue }
            byAlbum[albumID] = Album(id: albumID, title: track.albumName ?? track.title,
                                     artistName: track.artistName, imageTag: track.imageTag)
        }
        return byAlbum.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(displayedAlbums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .albumContextActions(album)
                    .onAppear {
                        // Reached the last loaded card → pull the next page.
                        if !downloadedOnly, album.id == albums.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding(.horizontal)
            if isLoading, !downloadedOnly {
                ProgressView().padding()
            }
            if downloadedOnly, displayedAlbums.isEmpty {
                Text("No downloaded albums yet.").foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Downloaded only", isOn: $downloadedOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: sort) { _ in Task { await loadMore(reset: true) } }
        .task {
            guard albums.isEmpty else { return }
            // Instant: cached first page, then refresh page 1 from the server.
            if let cached = container.libraryCache?.load([Album].self, for: LibraryCacheKey.allAlbums) {
                albums = cached
            }
            await loadMore(reset: true)
        }
    }

    /// Loads one page; `reset` reloads page 1 (and re-caches it for the default
    /// sort), otherwise it appends the next page. Only the first page is cached,
    /// so launch stays instant without persisting the whole (huge) library.
    private func loadMore(reset: Bool = false) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let startIndex = reset ? 0 : albums.count
        guard let page = try? await container.library?.albums(sortBy: sort.sortBy, sortOrder: sort.sortOrder, startIndex: startIndex, limit: pageSize) else { return }
        if reset {
            albums = page
            reachedEnd = page.count < pageSize
            if sort == .name { container.libraryCache?.save(page, for: LibraryCacheKey.allAlbums) }
        } else {
            albums += page
            reachedEnd = page.count < pageSize
        }
    }
}
