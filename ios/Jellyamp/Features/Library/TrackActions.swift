import SwiftUI
import JellyampCore

/// Spotify-style track actions. Apply `.trackContextActions(track)` to any row
/// for a long-press menu, or drop a `TrackMenuButton(track:)` in a row's
/// trailing edge for a visible "⋯" menu.
extension View {
    func trackContextActions(_ track: Track) -> some View {
        modifier(TrackContextActions(track: track))
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
