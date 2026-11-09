import SwiftUI
import JellyampCore
import JellyfinBackend

/// All album artists of the library: paged list with sort options and an
/// A–Z index.
struct ArtistsView: View {
    var body: some View {
        ArtistBrowser(filter: .none, cacheKey: LibraryCacheKey.allArtists)
            .navigationTitle("Artists")
    }
}
