import SwiftUI
import JellyampCore
import JellyfinBackend
import SonicClient

/// Sonic Adventure builder: pick a start and an end track and a length, and
/// jellyamp-server finds a path of tracks that morphs from one into the
/// other. Needs the `adventure` capability — entry points are hidden without
/// it, and the screen explains itself if it is reached anyway.
///
/// Push it inside a `NavigationStack` (Home does), or present
/// `SonicAdventureSheet` from places that cannot push.
struct SonicAdventureView: View {
    private enum PickerTarget: String, Identifiable {
        case start
        case end
        var id: String { rawValue }
    }

    @EnvironmentObject private var container: DependencyContainer
    @State private var start: Track?
    @State private var end: Track?
    @State private var steps = AdventureRequest.defaultSteps
    @State private var pickerTarget: PickerTarget?
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var path: [Track] = []
    @State private var showResult = false

    init(start: Track? = nil) {
        _start = State(initialValue: start)
    }

    var body: some View {
        Group {
            if container.sonicCapabilities.supports(.adventure) {
                builder
            } else {
                ContentUnavailableCompatView(
                    title: "Sonic Adventure Unavailable",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    description: "Sonic Adventure needs the optional jellyamp-server. Set it up under Settings \u{2192} Sonic Server."
                )
            }
        }
        .navigationTitle("Sonic Adventure")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var builder: some View {
        Form {
            Section {
                endpointRow(title: "Start", track: start, target: .start)
                endpointRow(title: "Destination", track: end, target: .end)
                if start != nil, end != nil {
                    Button {
                        let previousStart = start
                        start = end
                        end = previousStart
                    } label: {
                        Label("Swap Start and Destination", systemImage: "arrow.up.arrow.down")
                    }
                }
            } header: {
                Text("Route")
            } footer: {
                Text("The adventure begins with the start track and gradually moves toward the destination, one sonically close track at a time.")
            }

            Section("Length") {
                Picker("Tracks in Between", selection: $steps) {
                    ForEach(AdventureRequest.stepChoices, id: \.self) { choice in
                        Text("\(choice)").tag(choice)
                    }
                }
            }

            Section {
                Button {
                    build()
                } label: {
                    HStack {
                        Label("Create Adventure", systemImage: "sparkles")
                        Spacer()
                        if isBuilding { ProgressView() }
                    }
                }
                .disabled(validatedRequest == nil || isBuilding)
            } footer: {
                if let hint = validationHint {
                    Text(hint)
                } else if let errorMessage {
                    Text(errorMessage).foregroundColor(.red)
                }
            }
        }
        .sheet(item: $pickerTarget) { target in
            TrackPickerView(title: target == .start ? "Start Track" : "Destination Track") { picked in
                switch target {
                case .start: start = picked
                case .end: end = picked
                }
                errorMessage = nil
            }
            .environmentObject(container)
        }
        .navigationDestination(isPresented: $showResult) {
            AdventureResultView(tracks: path, playlistName: playlistName)
        }
    }

    private func endpointRow(title: LocalizedStringKey, track: Track?, target: PickerTarget) -> some View {
        Button {
            pickerTarget = target
        } label: {
            HStack(spacing: 12) {
                if let track {
                    ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "plus").foregroundStyle(.secondary)
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let track {
                        Text(track.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Choose a Track")
                            .foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    private var validation: Result<AdventureRequest, AdventureRequest.ValidationError> {
        AdventureRequest.validate(startID: start?.id, endID: end?.id, steps: steps)
    }

    private var validatedRequest: AdventureRequest? {
        try? validation.get()
    }

    /// Only the "same track" case needs words; missing picks are obvious
    /// from the empty rows.
    private var validationHint: LocalizedStringKey? {
        if case .failure(.sameTrack) = validation {
            return "Start and destination must be different tracks."
        }
        return nil
    }

    private var playlistName: String {
        guard let start, let end else { return String(localized: "Sonic Adventure") }
        return AdventurePath.defaultPlaylistName(start: start, end: end)
    }

    private func build() {
        guard let request = validatedRequest,
              let sonic = container.sonic,
              let resolver = container.trackResolver else { return }
        isBuilding = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBuilding = false }
            do {
                let rawIDs = try await sonic.adventure(from: request.startID, to: request.endID, steps: request.steps)
                let ids = AdventurePath.normalizedIDs(rawIDs, request: request)
                let resolved = try await resolver.tracks(byIDs: ids)
                let ordered = AdventurePath.orderedTracks(resolved, alongIDs: ids)
                // Two tracks means only the endpoints came back: no path.
                guard ordered.count > 2 else {
                    errorMessage = String(localized: "No path was found between these two tracks. Try a different pair.")
                    return
                }
                path = ordered
                showResult = true
            } catch SonicError.notFound {
                errorMessage = String(localized: "One of these tracks has not been analyzed yet. Try again once the analysis has caught up.")
            } catch SonicError.unauthorized {
                errorMessage = String(localized: "The sonic server rejected the API key. Check Settings \u{2192} Sonic Server.")
            } catch {
                errorMessage = String(localized: "The adventure could not be created. Check your connection and try again.")
            }
        }
    }
}

/// The computed path: preview in the house track-list style, Play from the
/// top (or from any row), Save as Playlist.
struct AdventureResultView: View {
    let tracks: [Track]
    let playlistName: String
    @State private var showSavePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            TrackListContent(tracks: tracks, isLoaded: true, emptyMessage: "No tracks.")
                .listStyle(.plain)
        }
        .navigationTitle("Your Adventure")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSavePrompt = true
                } label: {
                    Label("Save as Playlist", systemImage: "text.badge.plus")
                }
                .disabled(tracks.isEmpty)
            }
        }
        .saveAsPlaylistPrompt(isPresented: $showSavePrompt, tracks: tracks, suggestedName: playlistName)
    }

    private var summary: String {
        let minutes = Int((AdventurePath.totalDuration(of: tracks) / 60).rounded())
        return String(localized: "\(tracks.count) tracks \u{00B7} \(minutes) min")
    }
}

/// Sonic Adventure in a sheet, for entry points that cannot push onto a
/// navigation stack (the track ⋯ menu via `pendingAdventureStart`).
struct SonicAdventureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let start: Track?

    var body: some View {
        NavigationStack {
            SonicAdventureView(start: start)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

/// Track ⋯ menu entry: "Start Sonic Adventure from Here". Renders nothing
/// unless the provider supports adventures.
struct SonicAdventureMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track

    var body: some View {
        if container.sonicCapabilities.supports(.adventure) {
            Button {
                container.pendingAdventureStart = track
            } label: {
                Label("Start Sonic Adventure from Here", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }
        }
    }
}

/// Track ⋯ menu entry: endless radio seeded by this track, topped up as it
/// plays. Works with jellyamp-server (sonic similarity) and with plain
/// Jellyfin (Instant Mix); hidden when the provider has no similarity.
struct TrackRadioMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track

    var body: some View {
        if container.sonicCapabilities.supports(.similar) {
            Button {
                container.stations.start(.trackRadio(for: track), container: container)
            } label: {
                Label("Start Track Radio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }
}

/// Search-backed track picker (reuses the library search). Shows the playing
/// track and recently played ones until the user types.
struct TrackPickerView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let onPick: (Track) -> Void

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var suggestions: [Track] = []
    @State private var hasSearched = false

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    if results.isEmpty, hasSearched {
                        Text("No songs found.").foregroundStyle(.secondary)
                    }
                    ForEach(results) { track in
                        row(track)
                    }
                } else {
                    if let playing = container.playerState.currentTrack {
                        Section("Now Playing") {
                            row(playing)
                        }
                    }
                    if !suggestions.isEmpty {
                        Section("Recently Played") {
                            ForEach(suggestions) { track in
                                row(track)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) { await runSearch() }
            .task {
                if suggestions.isEmpty {
                    suggestions = (try? await container.library?.recentlyPlayedTracks(limit: 30)) ?? []
                }
            }
        }
    }

    private func row(_ track: Track) -> some View {
        Button {
            onPick(track)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
                VStack(alignment: .leading) {
                    Text(track.title).lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runSearch() async {
        guard isSearching, let library = container.library else {
            results = []
            hasSearched = false
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce
        guard !Task.isCancelled else { return }
        if let found = try? await library.search(query: query, limit: 30) {
            results = found.tracks
        }
        hasSearched = true
    }
}
