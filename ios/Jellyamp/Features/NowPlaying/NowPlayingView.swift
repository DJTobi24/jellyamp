import SwiftUI
import JellyampCore

/// Plexamp signature look: huge artwork over a blurred-art background.
/// Queue sheet, lyrics, and visualizer attach here in later phases.
struct NowPlayingView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel

    var body: some View {
        ZStack {
            BlurredArtBackground(track: playerState.currentTrack)
            VStack(spacing: 24) {
                Spacer()
                if let track = playerState.currentTrack {
                    ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 320)
                        .shadow(radius: 20)
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.title2.bold())
                            .lineLimit(1)
                        Text(track.artistName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                PlayerControlsView(playerState: playerState)
                Spacer()
            }
            .padding()
        }
    }
}

struct BlurredArtBackground: View {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track?

    var body: some View {
        Group {
            if let track {
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 400)
                    .blur(radius: 60)
                    .opacity(0.6)
                    .scaleEffect(1.5)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

struct PlayerControlsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel

    var body: some View {
        HStack(spacing: 48) {
            Button {
                container.player?.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            Button {
                playerState.isPlaying ? container.player?.pause() : container.player?.play()
            } label: {
                Image(systemName: playerState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            Button {
                container.player?.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Observable bridge between `PlayerEngine` state and SwiftUI.
@MainActor
final class PlayerStateModel: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
}
