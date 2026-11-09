import SwiftUI
import JellyampCore

/// Entry to artists / albums / genres / playlists browsing.
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: LikedSongsView()) {
                    Label("Liked Songs", systemImage: "heart.fill")
                }
                NavigationLink(destination: SavedAlbumsView()) {
                    Label("Saved Albums", systemImage: "heart.rectangle")
                }
                NavigationLink(destination: FollowedArtistsView()) {
                    Label("Following", systemImage: "heart.circle")
                }
                NavigationLink(destination: AlbumsGridView()) {
                    Label("Albums", systemImage: "square.stack")
                }
                NavigationLink(destination: ArtistsView()) {
                    Label("Artists", systemImage: "music.mic")
                }
                NavigationLink(destination: GenresView()) {
                    Label("Genres", systemImage: "guitars")
                }
                NavigationLink(destination: PlaylistsView()) {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
            .navigationTitle("Library")
        }
    }
}
