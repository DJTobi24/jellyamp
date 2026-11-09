import SwiftUI
import JellyampCore
import JellyfinBackend

/// Every song of the library: paged list with sort options, server-side
/// search and an A–Z index.
struct SongsView: View {
    var body: some View {
        TrackBrowser(filter: .none)
            .navigationTitle("Songs")
    }
}
