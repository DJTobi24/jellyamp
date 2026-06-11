import SwiftUI
import JellyampCore

/// Persistent bottom bar above the tab bar; tap to expand into NowPlayingView.
struct MiniPlayerView: View {
    @EnvironmentObject private var container: DependencyContainer
    @EnvironmentObject private var playerState: PlayerStateModel
    @State private var showNowPlaying = false

    var body: some View {
        if let track = playerState.currentTrack {
            // Two sibling buttons (not nested): the info area opens the full
            // player, the play/pause button toggles playback. Nesting them
            // would let the outer button swallow the pause tap.
            HStack(spacing: 12) {
                Button {
                    showNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                        VStack(alignment: .leading) {
                            Text(track.title)
                                .font(.callout)
                                .lineLimit(1)
                            if let errorMessage = playerState.errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text(track.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    playerState.isPlaying ? container.player?.pause() : container.player?.play()
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 16)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(playerState: playerState)
                    .environmentObject(container)
            }
        }
    }
}
