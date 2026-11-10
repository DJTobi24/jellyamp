import SwiftUI
import JellyampCore

/// What Sage came up with: the server's title and description, the tracks in
/// the house track-list style (Play / Shuffle from its bar, or tap any row),
/// Save as Playlist, and the two ways back: the same request again, or the
/// prompt for refining.
struct SonicSageResultView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: SageResult
    /// The request this result answers, shown so a saved screenshot or a
    /// later look still says what was asked.
    let prompt: String
    /// Pops back to the builder and sends the same request again.
    let onRegenerate: () -> Void
    /// Pops back to the builder with the prompt ready for editing.
    let onEditPrompt: () -> Void

    @State private var showSavePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 10)
            TrackListContent(tracks: result.tracks, isLoaded: true, emptyMessage: String(localized: "No tracks."))
                .listStyle(.plain)
        }
        .navigationTitle("Sonic Sage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSavePrompt = true
                } label: {
                    Label("Save as Playlist", systemImage: "text.badge.plus")
                }
                .disabled(result.tracks.isEmpty)
            }
        }
        .saveAsPlaylistPrompt(isPresented: $showSavePrompt, tracks: result.tracks, suggestedName: result.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.title3.bold())
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            if !result.description.isEmpty {
                // The list below needs room too; at the largest text sizes
                // an unbounded description would push it off screen.
                Text(result.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 6)
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let notice = noticeText {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            actions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        // Side by side the two labels do not fit at accessibility sizes.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                regenerateButton
                editButton
            }
        } else {
            HStack(spacing: 10) {
                regenerateButton
                editButton
            }
        }
    }

    private var regenerateButton: some View {
        Button {
            onRegenerate()
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Creates a new playlist from the same request")
    }

    private var editButton: some View {
        Button {
            onEditPrompt()
        } label: {
            Label("Refine Request", systemImage: "pencil")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Goes back to edit the request")
    }

    private var summary: String {
        let minutes = Int((result.totalDuration / 60).rounded())
        return String(localized: "\(result.tracks.count) tracks \u{00B7} \(minutes) min \u{00B7} \u{201C}\(prompt)\u{201D}")
    }

    private var noticeText: String? {
        switch result.notice {
        case .none:
            return nil
        case .some(.fewerMatches(let found, let requested)):
            return String(localized: "Sage found \(found) of the \(requested) tracks you asked for.")
        case .some(.missingFromLibrary(let found, let picked)):
            return String(localized: "Found \(found) of \(picked) tracks. The others are no longer in your Jellyfin library.")
        }
    }
}
