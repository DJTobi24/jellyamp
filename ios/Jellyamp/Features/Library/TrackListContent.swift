import SwiftUI
import JellyampCore

/// Shared track list with Play/Shuffle header, tap-to-play, ⋯ and context
/// actions — used by genre / playlist / liked / artist detail views.
struct TrackListContent: View {
    @EnvironmentObject private var container: DependencyContainer
    let tracks: [Track]
    var isLoaded: Bool = true
    var emptyMessage: String = "No tracks."

    var body: some View {
        List {
            if !tracks.isEmpty {
                HStack {
                    Button {
                        container.player?.load(queue: PlayQueue(tracks: tracks, startAt: 0))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        container.player?.playShuffled(tracks)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    CollectionMenuButton(tracks: tracks)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
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
                    TrackMenuButton(track: track)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
                }
                .trackContextActions(track)
            }
            if isLoaded, tracks.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
    }
}

extension Array where Element == Track {
    /// Case-insensitive filter over title + artist; empty query keeps all.
    func filtered(by query: String) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return self }
        return filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.artistName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
