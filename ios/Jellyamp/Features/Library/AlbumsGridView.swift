import SwiftUI
import JellyampCore
import JellyfinBackend

/// All albums of the library: paged grid with sort options, an A–Z index
/// and a "Downloaded only" filter.
struct AlbumsGridView: View {
    var body: some View {
        AlbumBrowser(filter: .none, cacheKey: LibraryCacheKey.allAlbums, allowsDownloadedFilter: true)
            .navigationTitle("Albums")
    }
}
