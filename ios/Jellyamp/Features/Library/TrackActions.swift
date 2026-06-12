import SwiftUI
import JellyampCore

/// Spotify-style track actions. Apply `.trackContextActions(track)` to any row
/// for a long-press menu, or drop a `TrackMenuButton(track:)` in a row's
/// trailing edge for a visible "⋯" menu.
extension View {
    func trackContextActions(_ track: Track) -> some View {
        modifier(TrackContextActions(track: track))
    }

    /// Long-press menu for an album cover (Play / Shuffle / Add to Queue).
    func albumContextActions(_ album: Album) -> some View {
        modifier(AlbumContextActions(album: album))
    }

    /// Long-press menu for an artist row (Play / Shuffle / Add to Queue).
    func artistContextActions(_ artist: Artist) -> some View {
        modifier(ArtistContextActions(artist: artist))
    }
}

private struct AlbumContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    let album: Album

    func body(content: Content) -> some View {
        content.contextMenu {
            CollectionActionButtons { try await container.library?.tracks(inAlbum: album.id) ?? [] }
        }
    }
}

private struct ArtistContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    let artist: Artist

    func body(content: Content) -> some View {
        content.contextMenu {
            CollectionActionButtons { try await container.library?.tracks(byArtist: artist.id) ?? [] }
        }
    }
}

/// Play / Shuffle / Add-to-Queue for a lazily-fetched set of tracks (album,
/// artist, …). The tracks are fetched only when an action is chosen.
private struct CollectionActionButtons: View {
    @EnvironmentObject private var container: DependencyContainer
    let tracks: () async throws -> [Track]

    var body: some View {
        Button {
            run { container.player?.load(queue: PlayQueue(tracks: $0)) }
        } label: { Label("Play", systemImage: "play.fill") }
        Button {
            run { container.player?.playShuffled($0) }
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Button {
            run { container.player?.enqueue($0) }
        } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button {
            run { container.downloads?.download($0) }
        } label: { Label("Download", systemImage: "arrow.down.circle") }
    }

    private func run(_ action: @escaping ([Track]) -> Void) {
        Task {
            guard let tracks = try? await tracks(), !tracks.isEmpty else { return }
            action(tracks)
        }
    }
}

private struct TrackContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track

    func body(content: Content) -> some View {
        content.contextMenu {
            TrackActionButtons(track: track, includePlay: true)
        }
    }
}

/// Visible "⋯" menu for an already-loaded collection (genre / liked / …):
/// Play Next, Add to Queue, Download the whole set.
struct CollectionMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    let tracks: [Track]

    var body: some View {
        Menu {
            Button {
                container.player?.playNext(tracks)
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                container.player?.enqueue(tracks)
            } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button {
                container.downloads?.download(tracks)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Visible "⋯" menu for a track row.
struct TrackMenuButton: View {
    let track: Track

    var body: some View {
        Menu {
            TrackActionButtons(track: track, includePlay: false)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The shared set of queue actions, used by both the context menu and the
/// inline "⋯" menu.
private struct TrackActionButtons: View {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track
    let includePlay: Bool

    var body: some View {
        Group {
            if includePlay {
                Button {
                    container.player?.load(queue: PlayQueue(tracks: [track]))
                } label: { Label("Play", systemImage: "play.fill") }
            }
            Button {
                container.player?.playNext([track])
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                container.player?.enqueue([track])
            } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button {
                startInstantMix()
            } label: { Label("Instant Mix", systemImage: "wand.and.stars") }
            Button {
                container.pendingPlaylistTrack = track
            } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            if let downloads = container.downloads {
                if downloads.isDownloaded(track.id) {
                    Button(role: .destructive) {
                        downloads.remove(track)
                    } label: { Label("Remove Download", systemImage: "trash") }
                } else {
                    Button {
                        downloads.download(track)
                    } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
            }
        }
    }

    /// Endless-radio feel from one track: with jellyamp-server this is true
    /// sonic similarity, against plain Jellyfin it's the metadata Instant Mix.
    private func startInstantMix() {
        Task {
            guard let sonic = container.sonic, let library = container.library else { return }
            guard let similar = try? await sonic.similarTracks(to: track.id, limit: 50), !similar.isEmpty else { return }
            let ids = similar.map(\.itemID)
            guard let mixTracks = try? await library.tracks(byIDs: ids), !mixTracks.isEmpty else { return }
            container.player?.load(queue: PlayQueue(tracks: [track] + mixTracks))
        }
    }
}
