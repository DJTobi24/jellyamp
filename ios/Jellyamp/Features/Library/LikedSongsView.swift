import SwiftUI
import JellyampCore

struct LikedSongsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var searchText = ""

    var body: some View {
        TrackListContent(
            tracks: tracks.filtered(by: searchText),
            isLoaded: loaded,
            emptyMessage: "No liked songs yet — tap the heart on a track to add it."
        )
        .listStyle(.plain)
        .navigationTitle("Liked Songs")
        .searchable(text: $searchText, prompt: "Search liked songs")
        .task {
            tracks = (try? await container.library?.favoriteTracks(limit: 500)) ?? []
            loaded = true
        }
    }
}
