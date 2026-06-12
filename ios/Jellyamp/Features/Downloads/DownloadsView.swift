import SwiftUI
import JellyampCore

struct DownloadsView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        NavigationStack {
            Group {
                if let downloads = container.downloads {
                    DownloadsList(downloads: downloads)
                } else {
                    ContentUnavailableCompatView(
                        title: "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: "Downloaded music will appear here for offline listening."
                    )
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

private struct DownloadsList: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        if downloads.downloaded.isEmpty && downloads.inProgress.isEmpty {
            ContentUnavailableCompatView(
                title: "No Downloads",
                systemImage: "arrow.down.circle",
                description: "Use the ⋯ menu on a track, album or playlist to download it for offline listening."
            )
        } else {
            List {
                if !downloads.inProgress.isEmpty {
                    Section("Downloading") {
                        ForEach(downloads.inProgress) { track in
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(track.title).lineLimit(1)
                            }
                        }
                    }
                }
                if !downloads.downloaded.isEmpty {
                    Section("Downloaded") {
                        ForEach(Array(downloads.downloaded.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 8) {
                                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                container.player?.load(queue: PlayQueue(tracks: downloads.downloaded, startAt: index))
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { downloads.remove(downloads.downloaded[index]) }
                        }
                    }
                }
            }
            .listStyle(.plain)
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
