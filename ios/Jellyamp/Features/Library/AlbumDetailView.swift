import SwiftUI
import JellyampCore

struct AlbumDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let album: Album
    @State private var tracks: [Track] = []
    @State private var searchText = ""

    private var displayed: [Track] { tracks.filtered(by: searchText) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 240)
                    Text(album.title)
                        .font(.title2.bold())
                    Text(album.artistName)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            play(from: 0)
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
                        .disabled(tracks.isEmpty)
                        FavoriteButton(itemID: album.id, isFavorite: album.isFavorite)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        Text("\(track.indexNumber ?? index + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(track.title)
                            .lineLimit(1)
                        Spacer()
                        Text(format(duration: track.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TrackMenuButton(track: track)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        container.player?.load(queue: PlayQueue(tracks: displayed, startAt: index))
                    }
                    .trackContextActions(track)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search in album")
        .task {
            tracks = (try? await container.library?.tracks(inAlbum: album.id)) ?? []
        }
    }

    private func play(from index: Int) {
        container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
    }

    private func format(duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
