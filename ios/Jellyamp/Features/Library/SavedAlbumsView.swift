import SwiftUI
import JellyampCore

struct SavedAlbumsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var albums: [Album] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if loaded, albums.isEmpty {
                ContentUnavailableCompatView(
                    title: "No Saved Albums",
                    systemImage: "heart",
                    description: "Tap the heart on an album to save it here."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .albumContextActions(album)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle("Saved Albums")
        .task {
            albums = (try? await container.library?.favoriteAlbums(limit: 500)) ?? []
            loaded = true
        }
    }
}
