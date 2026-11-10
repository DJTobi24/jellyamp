import SwiftUI
import JellyampCore

/// The Downloads tab: what is transferring, and everything that is on the
/// device grouped as albums, playlists and songs.
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        DownloadSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Download Settings")
                }
            }
        }
    }
}

private struct DownloadsList: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        let catalog = downloads.catalog
        let pending = downloads.index.pendingEntries
        if catalog.isEmpty && pending.isEmpty {
            ContentUnavailableCompatView(
                title: "No Downloads",
                systemImage: "arrow.down.circle",
                description: "Use the ⋯ menu on a track, album or playlist to download it for offline listening."
            )
        } else {
            List {
                DownloadsSummarySection(downloads: downloads, songs: catalog.tracksByTitle)
                if !pending.isEmpty {
                    DownloadQueueSection(downloads: downloads, progress: downloads.progress, entries: pending)
                }
                DownloadedAlbumsSection(downloads: downloads, albums: catalog.albums(limit: Int.max))
                DownloadedPinsSection(downloads: downloads, kind: .playlist, title: "Playlists")
                DownloadedPinsSection(downloads: downloads, kind: .artist, title: "Artists")
                DownloadedSongsSection(downloads: downloads, songs: catalog.tracksByTitle)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Summary

/// Storage used plus Play / Shuffle for everything downloaded.
private struct DownloadsSummarySection: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var downloads: DownloadManager
    let songs: [Track]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("\(songs.count) songs · \(DownloadFormatting.bytes(downloads.totalBytes))")
                } icon: {
                    Image(systemName: "internaldrive")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                HStack {
                    Button {
                        container.player?.load(queue: PlayQueue(tracks: songs, startAt: 0))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        container.player?.playShuffled(songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(songs.isEmpty)
            }
            .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Queue

private struct DownloadQueueSection: View {
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var progress: DownloadProgressModel
    let entries: [DownloadEntry]

    /// Rows shown individually; a 2000-track sync should not build 2000 rows.
    private let visibleLimit = 25

    var body: some View {
        Section {
            overallRow
            ForEach(Array(entries.prefix(visibleLimit))) { entry in
                DownloadQueueRow(downloads: downloads, entry: entry, fraction: progress.fraction(for: entry.id))
            }
            if entries.count > visibleLimit {
                Text("and \(entries.count - visibleLimit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Downloading")
        }
    }

    private var overallRow: some View {
        let total = downloads.index.entries.count
        let complete = downloads.downloaded.count
        let partial = progress.fractions.values.reduce(0, +)
        let fraction = total == 0 ? 0 : min((Double(complete) + partial) / Double(total), 1)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("\(complete) of \(total) songs downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if downloads.hasPausedDownloads || !downloads.failed.isEmpty {
                Button {
                    downloads.resumeAll()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Resume all downloads")
            } else {
                Button {
                    downloads.pauseAll()
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pause all downloads")
            }
        }
    }
}

private struct DownloadQueueRow: View {
    let downloads: DownloadManager
    let entry: DownloadEntry
    let fraction: Double?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.track.title)
                    .lineLimit(1)
                if entry.phase == .downloading, let fraction {
                    ProgressView(value: fraction)
                } else {
                    Text(DownloadFormatting.status(of: entry))
                        .font(.caption)
                        .foregroundStyle(entry.phase == .failed ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            primaryAction
            Button {
                downloads.removeTrack(id: entry.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel download")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch entry.phase {
        case .queued, .downloading:
            Button {
                downloads.pause(entry.id)
            } label: {
                Image(systemName: "pause.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Pause download")
        case .paused:
            Button {
                downloads.resume(entry.id)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Resume download")
        case .failed, .waitingToRetry:
            Button {
                downloads.retry(entry.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry download")
        case .complete:
            EmptyView()
        }
    }
}

// MARK: - Albums

private struct DownloadedAlbumsSection: View {
    @ObservedObject var downloads: DownloadManager
    let albums: [Album]

    var body: some View {
        if !albums.isEmpty {
            Section {
                ForEach(albums) { album in
                    NavigationLink {
                        DownloadedCollectionView(collection: .album(album.id))
                    } label: {
                        DownloadedCollectionRow(
                            artworkItemID: album.id,
                            imageTag: album.imageTag,
                            title: album.title,
                            subtitle: subtitle(for: album)
                        )
                    }
                }
                .onDelete { offsets in
                    for index in offsets { downloads.removeAlbum(id: albums[index].id) }
                }
            } header: {
                Text("Albums")
            }
        }
    }

    private func subtitle(for album: Album) -> String {
        let count = album.trackCount ?? 0
        let songs = count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
        return album.artistName.isEmpty ? songs : "\(album.artistName) · \(songs)"
    }
}

// MARK: - Playlists / artists

/// Pinned playlists or artists. Deleting removes the pin; tracks another pin
/// still needs stay on the device.
private struct DownloadedPinsSection: View {
    @ObservedObject var downloads: DownloadManager
    let kind: DownloadPin.Kind
    let title: LocalizedStringKey

    var body: some View {
        let pins = downloads.index.pins.filter { $0.kind == kind }
        if !pins.isEmpty {
            Section {
                ForEach(pins) { pin in
                    NavigationLink {
                        DownloadedCollectionView(collection: .pin(pin.id))
                    } label: {
                        DownloadedCollectionRow(
                            artworkItemID: pin.itemID,
                            imageTag: pin.imageTag,
                            title: pin.title,
                            subtitle: subtitle(for: pin)
                        )
                    }
                }
                .onDelete { offsets in
                    for index in offsets { downloads.removePin(id: pins[index].id) }
                }
            } header: {
                Text(title)
            }
        }
    }

    private func subtitle(for pin: DownloadPin) -> String {
        let progress = downloads.index.progress(forPin: pin.id)
        if progress.isComplete || progress.total == 0 {
            return progress.total == 1 ? String(localized: "1 song") : String(localized: "\(progress.total) songs")
        }
        return String(localized: "\(progress.complete) of \(progress.total) songs downloaded")
    }
}

struct DownloadedCollectionRow: View {
    let artworkItemID: String
    let imageTag: String?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: artworkItemID, imageTag: imageTag, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Songs

private struct DownloadedSongsSection: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var downloads: DownloadManager
    let songs: [Track]

    var body: some View {
        if !songs.isEmpty {
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                    DownloadedSongRow(track: track, isAutoSynced: downloads.isAutoSyncedOnly(track.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            container.player?.load(queue: PlayQueue(tracks: songs, startAt: index))
                        }
                        .trackContextActions(track)
                }
                .onDelete { offsets in
                    for index in offsets { downloads.remove(songs[index]) }
                }
            } header: {
                Text("Songs")
            }
        }
    }
}

struct DownloadedSongRow: View {
    let track: Track
    var isAutoSynced = false

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
            VStack(alignment: .leading) {
                Text(track.title)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isAutoSynced {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded by Smart Sync")
            }
            DownloadStatusBadge(trackID: track.id)
        }
    }
}

// MARK: - Formatting

enum DownloadFormatting {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// One line describing a not-yet-complete download.
    static func status(of entry: DownloadEntry) -> String {
        switch entry.phase {
        case .queued:
            return String(localized: "Waiting")
        case .downloading:
            return String(localized: "Downloading")
        case .paused:
            return String(localized: "Paused")
        case .waitingToRetry:
            let reason = entry.failure.map(message(for:)) ?? ""
            return String(localized: "Retrying soon. \(reason)")
        case .failed:
            return entry.failure.map(message(for:)) ?? String(localized: "Download failed.")
        case .complete:
            return String(localized: "Downloaded")
        }
    }

    static func message(for failure: DownloadFailure) -> String {
        switch failure {
        case .network:
            return String(localized: "The connection was interrupted.")
        case .timeout:
            return String(localized: "The server took too long to respond.")
        case .serverError:
            return String(localized: "The server reported an error.")
        case .rateLimited:
            return String(localized: "The server is busy.")
        case .unauthorized:
            return String(localized: "Sign in again to download.")
        case .forbidden:
            return String(localized: "Downloads are disabled for your account on this server.")
        case .notFound:
            return String(localized: "This track no longer exists on the server.")
        case .badResponse:
            return String(localized: "The server sent an unexpected response.")
        case .insufficientStorage:
            return String(localized: "Not enough free space on this device.")
        case .fileSystem:
            return String(localized: "The file could not be saved.")
        }
    }
}

/// `ContentUnavailableView` needs iOS 17; this is the 16-compatible stand-in.
/// Title and description are localization keys (pass string literals).
struct ContentUnavailableCompatView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey

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
