import SwiftUI
import JellyampCore

/// What a `DownloadButton` downloads. Naming the collection (instead of only
/// passing tracks) lets the downloads list show it as that album / playlist
/// and lets playlists follow later changes on the server.
enum DownloadTarget {
    case tracks([Track])
    case album(Album, tracks: [Track])
    case playlist(Playlist, tracks: [Track])
    case artist(Artist, tracks: [Track])

    var tracks: [Track] {
        switch self {
        case .tracks(let tracks): return tracks
        case .album(_, let tracks): return tracks
        case .playlist(_, let tracks): return tracks
        case .artist(_, let tracks): return tracks
        }
    }
}

/// Download control for an album / playlist header or a track row: shows the
/// current state (not downloaded, progress, downloaded) and downloads,
/// retries or — after confirmation — removes on tap.
///
///     DownloadButton(tracks: tracks)
///     DownloadButton(album: album, tracks: tracks)
///     DownloadButton(playlist: playlist, tracks: tracks)
struct DownloadButton: View {
    @EnvironmentObject private var container: DependencyContainer
    let target: DownloadTarget

    init(tracks: [Track]) { target = .tracks(tracks) }
    init(album: Album, tracks: [Track]) { target = .album(album, tracks: tracks) }
    init(playlist: Playlist, tracks: [Track]) { target = .playlist(playlist, tracks: tracks) }
    init(artist: Artist, tracks: [Track]) { target = .artist(artist, tracks: tracks) }

    var body: some View {
        if let downloads = container.downloads {
            DownloadButtonContent(downloads: downloads, progress: downloads.progress, target: target)
        }
    }
}

private struct DownloadButtonContent: View {
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var progress: DownloadProgressModel
    let target: DownloadTarget
    @State private var confirmsRemoval = false

    private var trackIDs: [String] { target.tracks.map(\.id) }

    var body: some View {
        let state = downloads.state(forTrackIDs: trackIDs)
        Button {
            tapped(state)
        } label: {
            icon(for: state)
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target.tracks.isEmpty)
        .accessibilityLabel(accessibilityLabel(for: state))
        .confirmationDialog("Remove this download?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func icon(for state: DownloadCollectionState) -> some View {
        switch state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .inProgress(let complete, let total):
            DownloadProgressRing(fraction: fraction(complete: complete, total: total))
        case .incomplete(_, _, let hasFailures):
            Image(systemName: hasFailures ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                .foregroundStyle(hasFailures ? Color.orange : Color.secondary)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Finished tracks plus the partial progress of the running ones.
    private func fraction(complete: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        var done = Double(complete)
        for id in trackIDs {
            done += progress.fraction(for: id) ?? 0
        }
        return min(done / Double(total), 1)
    }

    private func accessibilityLabel(for state: DownloadCollectionState) -> Text {
        switch state {
        case .notDownloaded: return Text("Download")
        case .inProgress: return Text("Downloading. Cancel download")
        case .incomplete(_, _, let hasFailures): return hasFailures ? Text("Retry download") : Text("Continue download")
        case .downloaded: return Text("Downloaded. Remove download")
        }
    }

    private func tapped(_ state: DownloadCollectionState) {
        switch state {
        case .notDownloaded, .incomplete:
            start()
        case .inProgress, .downloaded:
            confirmsRemoval = true
        }
    }

    private func start() {
        switch target {
        case .tracks(let tracks): downloads.download(tracks)
        case .album(let album, let tracks): downloads.download(album: album, tracks: tracks)
        case .playlist(let playlist, let tracks): downloads.download(playlist: playlist, tracks: tracks)
        case .artist(let artist, let tracks): downloads.download(artist: artist, tracks: tracks)
        }
    }

    private func remove() {
        switch target {
        case .tracks(let tracks):
            downloads.remove(tracks)
        case .album(let album, _):
            downloads.removeAlbum(id: album.id)
        case .playlist(let playlist, _):
            downloads.removePin(id: DownloadPin.id(kind: .playlist, itemID: playlist.id))
        case .artist(let artist, _):
            downloads.removePin(id: DownloadPin.id(kind: .artist, itemID: artist.id))
        }
    }
}

/// Download control for an artist header. An artist's complete track list is
/// not part of the artist page and can be long, so it is fetched only when
/// the user asks for the download. Once the artist is pinned the pin knows
/// its tracks and the regular `DownloadButton` (state, progress, remove)
/// takes over.
///
///     ArtistDownloadButton(artist: artist)
struct ArtistDownloadButton: View {
    @EnvironmentObject private var container: DependencyContainer
    let artist: Artist

    var body: some View {
        if let downloads = container.downloads {
            ArtistDownloadButtonContent(downloads: downloads, artist: artist)
        }
    }
}

private struct ArtistDownloadButtonContent: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var downloads: DownloadManager
    let artist: Artist
    @State private var isLoading = false

    var body: some View {
        let pinned = downloads.index.entries(forPin: DownloadPin.id(kind: .artist, itemID: artist.id)).map(\.track)
        if !pinned.isEmpty {
            DownloadButton(artist: artist, tracks: pinned)
        } else {
            Button {
                fetchAndDownload()
            } label: {
                ZStack {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(Text("Download"))
        }
    }

    private func fetchAndDownload() {
        guard let library = container.library else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let tracks = try await library.tracks(byArtist: artist.id)
                if tracks.isEmpty {
                    ToastCenter.shared.show(String(localized: "Nothing to download here"), style: .info)
                } else {
                    downloads.download(artist: artist, tracks: tracks)
                }
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not load the tracks"), error: error)
            }
        }
    }
}

/// Small state icon for a track row: nothing when the track is not
/// downloaded, otherwise queued / progress / downloaded / failed.
///
///     DownloadStatusBadge(trackID: track.id)
struct DownloadStatusBadge: View {
    @EnvironmentObject private var container: DependencyContainer
    let trackID: String

    var body: some View {
        if let downloads = container.downloads {
            DownloadStatusBadgeContent(downloads: downloads, progress: downloads.progress, trackID: trackID)
        }
    }
}

private struct DownloadStatusBadgeContent: View {
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var progress: DownloadProgressModel
    let trackID: String

    var body: some View {
        if let phase = downloads.phase(for: trackID) {
            badge(for: phase)
                .font(.caption)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private func badge(for phase: DownloadPhase) -> some View {
        switch phase {
        case .complete:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        case .downloading:
            DownloadProgressRing(fraction: progress.fraction(for: trackID) ?? 0, showsStop: false, size: 14)
                .accessibilityLabel("Downloading")
        case .queued, .waitingToRetry:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting to download")
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Download paused")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        }
    }
}

/// Circular determinate progress, optionally with a stop square in the middle
/// (the "tap to cancel" affordance of a download button).
struct DownloadProgressRing: View {
    let fraction: Double
    var showsStop = true
    var size: CGFloat = 24

    var body: some View {
        let lineWidth = max(size * 0.1, 1.5)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0.02), 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsStop {
                RoundedRectangle(cornerRadius: size * 0.06)
                    .fill(Color.accentColor)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}
