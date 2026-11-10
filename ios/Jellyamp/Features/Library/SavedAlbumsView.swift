import SwiftUI
import JellyampCore
import JellyfinBackend

/// The user's favorited albums.
struct SavedAlbumsView: View {
    var body: some View {
        AlbumBrowser(
            filter: BrowseFilter(favoritesOnly: true),
            emptyTitle: String(localized: "No Saved Albums"),
            emptyMessage: String(localized: "Tap the heart on an album to save it here."),
            emptySystemImage: "heart"
        )
        .navigationTitle("Saved Albums")
    }
}
