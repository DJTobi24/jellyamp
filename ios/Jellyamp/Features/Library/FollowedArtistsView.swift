import SwiftUI
import JellyampCore

struct FollowedArtistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var artists: [Artist] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, artists.isEmpty {
                ContentUnavailableCompatView(
                    title: "Not Following Anyone",
                    systemImage: "heart",
                    description: "Tap the heart on an artist to follow them."
                )
            } else {
                List(artists) { artist in
                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                        HStack {
                            ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                                .clipShape(Circle())
                            Text(artist.name)
                        }
                    }
                    .artistContextActions(artist)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Following")
        .task {
            artists = (try? await container.library?.favoriteArtists(limit: 500)) ?? []
            loaded = true
        }
    }
}
