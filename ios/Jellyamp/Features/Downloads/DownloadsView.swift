import SwiftUI

/// Offline downloads land in Phase 2 (DownloadManager + GRDB download store).
struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableCompatView(
                title: "No Downloads",
                systemImage: "arrow.down.circle",
                description: "Downloaded albums and playlists will appear here for offline listening."
            )
            .navigationTitle("Downloads")
        }
    }
}

/// `ContentUnavailableView` needs iOS 17; this is the 16-compatible stand-in.
struct ContentUnavailableCompatView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
