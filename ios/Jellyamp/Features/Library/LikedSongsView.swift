import SwiftUI
import JellyampCore
import JellyfinBackend

/// The user's favorited tracks. Reloads when a song is liked or un-liked
/// anywhere in the app.
struct LikedSongsView: View {
    var body: some View {
        TrackBrowser(
            filter: BrowseFilter(favoritesOnly: true),
            cacheKey: LibraryCacheKey.likedSongs,
            searchPrompt: String(localized: "Search liked songs"),
            emptyTitle: String(localized: "No Liked Songs"),
            emptyMessage: String(localized: "Choose “Add to Liked Songs” from a song’s ⋯ menu to collect it here."),
            emptySystemImage: "heart",
            playlistTitle: String(localized: "Liked Songs")
        )
        .navigationTitle("Liked Songs")
    }
}
