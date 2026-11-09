import SwiftUI
import JellyampCore

/// Shared list for an already-loaded set of tracks: Play/Shuffle header,
/// tap-to-play rows with ⋯ / context / VoiceOver actions, a skeleton while
/// loading and an empty message. For lists that can be large use
/// `TrackBrowser` (paged) instead.
struct TrackListContent: View {
    @EnvironmentObject private var container: DependencyContainer
    let tracks: [Track]
    var isLoaded: Bool = true
    var emptyMessage: String = String(localized: "No tracks.")

    var body: some View {
        List {
            if !isLoaded, tracks.isEmpty {
                SkeletonRows()
            }
            if !tracks.isEmpty {
                PlayShuffleBar(
                    isEnabled: true,
                    play: { container.player?.load(queue: PlayQueue(tracks: tracks, startAt: 0)) },
                    shuffle: { container.player?.playShuffled(tracks) }
                ) {
                    CollectionMenuButton(tracks: tracks)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                TrackRow(track: track) {
                    container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
                }
            }
            if isLoaded, tracks.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
    }
}

extension Array where Element == Track {
    /// Case-insensitive, diacritic-insensitive filter over title, artist and
    /// album; an empty query keeps all.
    func filtered(by query: String) -> [Track] {
        let needle = SearchRanker.normalize(query)
        guard !needle.isEmpty else { return self }
        return filter {
            SearchRanker.normalize($0.title).contains(needle)
                || SearchRanker.normalize($0.artistName).contains(needle)
                || SearchRanker.normalize($0.albumName ?? "").contains(needle)
        }
    }
}
