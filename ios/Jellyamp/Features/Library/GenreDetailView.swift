import SwiftUI
import JellyampCore

struct GenreDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let genre: Genre
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var searchText = ""

    private var displayed: [Track] { tracks.filtered(by: searchText) }

    var body: some View {
        TrackListContent(
            tracks: displayed,
            isLoaded: loaded,
            emptyMessage: "No tracks in this genre."
        )
        .listStyle(.plain)
        .navigationTitle(genre.name)
        .searchable(text: $searchText, prompt: "Search in \(genre.name)")
        .task {
            tracks = (try? await container.library?.tracks(inGenre: genre.id)) ?? []
            loaded = true
        }
    }
}
