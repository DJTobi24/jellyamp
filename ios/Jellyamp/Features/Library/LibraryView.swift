import SwiftUI
import JellyampCore

/// Entry to playlists / artists / albums / songs / genres and the favorites
/// lists. Owns the Library tab's navigation stack; on iPad the same lists are
/// reached from the sidebar instead (see `AdaptiveShellView`).
struct LibraryView: View {
    var body: some View {
        RoutedNavigationStack(.library) {
            LibraryRootList()
        }
    }
}

/// The list of library categories.
struct LibraryRootList: View {
    private let browse: [LibraryCategory] = [.playlists, .artists, .albums, .songs, .genres]
    private let favorites: [LibraryCategory] = [.likedSongs, .savedAlbums, .following]

    var body: some View {
        List {
            Section {
                ForEach(browse) { category in
                    row(category)
                }
            }
            Section("Favorites") {
                ForEach(favorites) { category in
                    row(category)
                }
            }
        }
        .navigationTitle("Library")
        .readableContentWidth()
    }

    private func row(_ category: LibraryCategory) -> some View {
        RouteLink(.category(category)) {
            Label(category.title, systemImage: category.systemImage)
                .frame(minHeight: 32)
        }
    }
}
