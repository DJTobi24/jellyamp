import SwiftUI
import JellyampCore
import JellyfinBackend

/// The user's favorited artists.
struct FollowedArtistsView: View {
    var body: some View {
        ArtistBrowser(
            filter: BrowseFilter(favoritesOnly: true),
            emptyTitle: String(localized: "Not Following Anyone"),
            emptyMessage: String(localized: "Tap the heart on an artist to follow them."),
            emptySystemImage: "heart"
        )
        .navigationTitle("Following")
    }
}
