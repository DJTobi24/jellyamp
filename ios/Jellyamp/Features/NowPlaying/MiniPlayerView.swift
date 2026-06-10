import SwiftUI
import JellyampCore

/// Persistent bottom bar above the tab bar; tap to expand into NowPlayingView.
struct MiniPlayerView: View {
    @EnvironmentObject private var container: DependencyContainer
    @StateObject private var playerState = PlayerStateModel()
    @State private var showNowPlaying = false

    var body: some View {
        if let track = playerState.currentTrack {
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                    VStack(alignment: .leading) {
                        Text(track.title)
                            .font(.callout)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        playerState.isPlaying ? container.player?.pause() : container.player?.play()
                    } label: {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView(playerState: playerState)
            }
        }
    }
}
