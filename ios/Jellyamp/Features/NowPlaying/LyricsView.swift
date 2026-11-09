import SwiftUI
import JellyampCore

/// Full-screen lyrics. Synced lyrics highlight and follow the active line
/// (driven off the player clock) and seek when a line is tapped; plain lyrics
/// just scroll.
///
/// `track` is the track the sheet was opened for; the view then follows the
/// player, so the lyrics change with the song instead of going stale.
struct LyricsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    @State private var timeline: LyricsTimeline?
    @State private var loadState: LoadState = .loading
    @State private var autoScroll = LyricsAutoScroll()
    /// Bumped by "Retry" to re-run the load task.
    @State private var reloadToken = 0

    private var shownTrack: Track { playerState.currentTrack ?? track }

    private var activeIndex: Int? {
        timeline?.activeLineIndex(at: playerState.currentTime)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        ZStack(alignment: .top) {
            BlurredArtBackground(track: shownTrack)
            content
            header
        }
        .task(id: "\(shownTrack.id)#\(reloadToken)") {
            await load(trackID: shownTrack.id)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shownTrack.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(shownTrack.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Lyrics")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func load(trackID: String) async {
        loadState = .loading
        timeline = nil
        autoScroll.resume()
        guard let library = container.library else {
            loadState = .failed
            return
        }
        do {
            let loaded = try await library.lyrics(forTrack: trackID)
            // The song may have changed while the request was in flight.
            guard !Task.isCancelled, shownTrack.id == trackID else { return }
            timeline = loaded
            loadState = .loaded
        } catch {
            guard !Task.isCancelled, shownTrack.id == trackID else { return }
            loadState = .failed
        }
    }

    @ViewBuilder private var content: some View {
        if let timeline, !timeline.lines.isEmpty {
            lyrics(timeline)
        } else {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ContentUnavailableCompatView(
                    title: "No Lyrics",
                    systemImage: "quote.bubble",
                    description: "This track has no lyrics."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 16) {
                    ContentUnavailableCompatView(
                        title: "Lyrics Unavailable",
                        systemImage: "wifi.exclamationmark",
                        description: "The lyrics could not be loaded."
                    )
                    Button("Retry") { reloadToken += 1 }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func lyrics(_ timeline: LyricsTimeline) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy on purpose: `scrollTo` must be able to reach a line
                // that has never been on screen (seek, opening mid-song).
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(timeline.lines.enumerated()), id: \.offset) { index, line in
                        lyricLine(line, index: index, isSynced: timeline.isSynced)
                            .id(index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 84)
                .padding(.bottom, 120)
            }
            // A finger on the text means "let me read": stop following for a
            // few seconds. Simultaneous, so scrolling itself is untouched.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { _ in
                    autoScroll.userScrolled(now: now)
                }
            )
            .onChange(of: activeIndex) { index in
                follow(index, proxy: proxy, animated: true)
            }
            .onAppear {
                // Opening mid-song: start at the active line, not the top.
                follow(activeIndex, proxy: proxy, animated: false)
            }
        }
    }

    private func follow(_ index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard let index, autoScroll.shouldFollow(now: now) else { return }
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, index: Int, isSynced: Bool) -> some View {
        let isActive = activeIndex == index
        let text = Text(line.text.isEmpty ? "♪" : line.text)
            .font(.title3.weight(.bold))
            // Unsynced lyrics have no "current" line: show them all at full strength.
            .foregroundStyle(!isSynced || isActive ? Color.white : Color.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        if let start = line.start {
            Button {
                autoScroll.resume()
                container.player?.seek(to: start)
            } label: {
                text.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityHint("Jumps to this line")
        } else {
            text
        }
    }
}
