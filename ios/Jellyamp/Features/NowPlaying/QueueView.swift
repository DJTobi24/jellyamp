import SwiftUI
import JellyampCore

/// Spotify-style queue sheet: what played (optional), what is playing, and
/// what is up next. Tap a row to jump to it, swipe to remove, drag to
/// reorder, "Clear" to drop everything upcoming.
struct QueueView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @Environment(\.dismiss) private var dismiss
    @State private var showHistory = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if !playerState.history.isEmpty {
                    historySection
                }
                if let current = playerState.currentTrack {
                    Section("Now Playing") {
                        QueueRow(track: current, isCurrent: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isSelected)
                    }
                }
                upNextSection
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                        .disabled(playerState.upNext.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.Queue.done)
                }
            }
            .confirmationDialog("Clear all upcoming tracks?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Up Next", role: .destructive) {
                    container.player?.clearUpNext()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var historySection: some View {
        Section {
            if showHistory {
                // Newest first: the track you just heard is the one you want back.
                ForEach(Array(playerState.history.enumerated()).reversed(), id: \.offset) { index, track in
                    Button {
                        container.player?.playFromHistory(at: index)
                    } label: {
                        QueueRow(track: track, isCurrent: false)
                            .opacity(0.6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays this track again")
                }
            }
        } header: {
            Button {
                withAnimation { showHistory.toggle() }
            } label: {
                HStack {
                    Text("History (\(playerState.history.count))")
                    Spacer()
                    Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History, \(playerState.history.count) tracks")
            .accessibilityValue(showHistory ? "Expanded" : "Collapsed")
        }
    }

    private var upNextSection: some View {
        Section {
            if playerState.upNext.isEmpty {
                Text("Nothing queued. Autoplay adds similar tracks when it is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(playerState.upNext.enumerated()), id: \.offset) { index, track in
                    Button {
                        container.player?.playUpNext(at: index)
                    } label: {
                        QueueRow(track: track, isCurrent: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Queue.upNext(index))
                }
                .onDelete { offsets in
                    // Highest index first so earlier removals do not shift later ones.
                    for index in offsets.sorted(by: >) {
                        container.player?.removeUpNext(at: index)
                    }
                }
                .onMove { offsets, destination in
                    container.player?.moveUpNext(fromOffsets: offsets, toOffset: destination)
                }
            }
        } header: {
            HStack {
                Text("Up Next")
                Spacer()
                if !playerState.upNext.isEmpty {
                    Button("Clear") { confirmClear = true }
                        .font(.footnote.weight(.semibold))
                        .accessibilityLabel("Clear Up Next")
                }
            }
        }
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.purple : Color.primary)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
            } else {
                Text(PlaybackTimeFormat.clock(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
