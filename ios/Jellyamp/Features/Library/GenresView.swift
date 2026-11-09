import SwiftUI
import JellyampCore

struct GenresView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var genres: [Genre] = []

    var body: some View {
        List(genres) { genre in
            NavigationLink(destination: GenreDetailView(genre: genre)) {
                Text(genre.name)
            }
        }
        .navigationTitle("Genres")
        .task {
            genres = (try? await container.library?.genres()) ?? []
        }
    }
}
