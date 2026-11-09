import SwiftUI
import JellyampCore
import JellyfinBackend

/// The albums and songs of one genre, each as a paged list.
struct GenreDetailView: View {
    private enum Content: String, CaseIterable, Identifiable {
        case albums, songs
        var id: String { rawValue }
    }

    let genre: Genre
    @State private var content: Content = .albums

    var body: some View {
        Group {
            switch content {
            case .albums:
                AlbumBrowser(
                    filter: BrowseFilter(genreID: genre.id),
                    emptyMessage: String(localized: "No albums in this genre.")
                )
            case .songs:
                TrackBrowser(
                    filter: BrowseFilter(genreID: genre.id),
                    defaultSort: .album,
                    searchPrompt: String(localized: "Search in \(genre.name)"),
                    emptyMessage: String(localized: "No songs in this genre."),
                    playlistTitle: genre.name
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $content) {
                Text("Albums").tag(Content.albums)
                Text("Songs").tag(Content.songs)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
