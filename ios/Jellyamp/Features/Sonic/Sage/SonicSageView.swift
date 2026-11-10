import SwiftUI
import JellyampCore
import SonicClient

/// Sonic Sage builder: describe the music in words and jellyamp-server turns
/// the description into a playlist from the analyzed library (it asks a
/// language model for criteria, then matches them sonically). Needs the
/// `sage` capability — entry points are hidden without it, and the screen
/// explains itself if it is reached anyway.
///
/// Push it inside a `NavigationStack` (Home does), or present
/// `SonicSageSheet` from places that cannot push.
struct SonicSageView: View {
    /// Starting points for people who face an empty field. Kept generic so
    /// most libraries have something for at least a few of them.
    static let examplePrompts: [String] = [
        String(localized: "Rainy Sunday morning jazz"),
        String(localized: "90s rock for a road trip"),
        String(localized: "Calm electronic music for focus"),
        String(localized: "Upbeat songs to cook dinner to"),
        String(localized: "Late-night ambient to fall asleep"),
        String(localized: "Classical pieces that build slowly"),
        String(localized: "High-energy workout mix"),
        String(localized: "Mellow acoustic for a quiet evening"),
    ]

    /// The counter stays out of the way until the limit is in sight.
    private static let counterThreshold = 100

    @EnvironmentObject private var container: DependencyContainer
    @StateObject private var model = SonicSageModel()
    @FocusState private var promptFocused: Bool
    @State private var showClearRecentsConfirmation = false

    var body: some View {
        Group {
            if container.sonicCapabilities.supports(.sage) {
                builder
            } else {
                ContentUnavailableCompatView(
                    title: "Sonic Sage Unavailable",
                    systemImage: "wand.and.stars",
                    description: "Sonic Sage needs the optional jellyamp-server with an Anthropic API key configured on it. Set it up under Settings \u{2192} Sonic Server."
                )
            }
        }
        .navigationTitle("Sonic Sage")
        .navigationBarTitleDisplayMode(.inline)
        // No cancel on disappear: switching tabs while Sage works must not
        // throw the request away. The result is pushed when the user returns;
        // if the screen is gone for good its model is too, and the answer is
        // dropped.
    }

    private var builder: some View {
        Form {
            promptSection
            lengthSection
            generateSection
            if let failure = model.failure {
                failureSection(failure)
            }
            if !model.recents.isEmpty {
                recentsSection
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $model.showResult) {
            if let result = model.result {
                SonicSageResultView(
                    result: result,
                    prompt: model.resultPrompt,
                    onRegenerate: {
                        model.showResult = false
                        model.generate(container: container)
                    },
                    onEditPrompt: {
                        model.showResult = false
                        promptFocused = true
                    }
                )
            }
        }
        .confirmationDialog(
            "Clear all recent prompts?",
            isPresented: $showClearRecentsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Recent Prompts", role: .destructive) {
                model.clearRecents()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var promptSection: some View {
        Section {
            TextField("Describe the music you want to hear", text: $model.prompt, axis: .vertical)
                .lineLimit(3...8)
                .focused($promptFocused)
                .disabled(model.isGenerating)
                .accessibilityLabel("Playlist description")
                .onChange(of: model.prompt) { _ in
                    model.promptEdited()
                }
            exampleChips
        } header: {
            Text("Your Request")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let hint = lengthHint {
                    Text(hint)
                        .foregroundColor(model.excessCharacters == nil ? .secondary : .red)
                }
                Text("Privacy: your jellyamp-server sends this text and a summary of your library (genre and artist names) to Anthropic, using the API key configured on that server.")
            }
        }
    }

    private var exampleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.examplePrompts, id: \.self) { example in
                    Button {
                        model.use(prompt: example)
                    } label: {
                        Text(example)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Uses this example as your request")
                }
            }
            .padding(.horizontal, 16)
        }
        // The chips scroll edge to edge inside the form row.
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .disabled(model.isGenerating)
    }

    private var lengthSection: some View {
        Section {
            Picker("Number of Tracks", selection: $model.count) {
                ForEach(SageTrackCount.choices, id: \.self) { choice in
                    Text("\(choice)").tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isGenerating)
        } header: {
            Text("Number of Tracks")
        }
    }

    @ViewBuilder
    private var generateSection: some View {
        if let since = model.generatingSince {
            Section {
                TimelineView(.periodic(from: since, by: 0.5)) { context in
                    SageProgressRow(elapsed: context.date.timeIntervalSince(since))
                }
                Button("Cancel", role: .cancel) {
                    model.cancel()
                }
            } footer: {
                Text("Sage asks a language model and then searches your library. This usually takes 5 to 20 seconds; the bar is an estimate.")
            }
        } else {
            Section {
                Button {
                    promptFocused = false
                    model.generate(container: container)
                } label: {
                    Label("Create Playlist", systemImage: "wand.and.stars")
                }
                .disabled(!model.canGenerate)
            }
        }
    }

    private func failureSection(_ failure: SageFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.title, systemImage: failure.systemImage)
                    .font(.headline)
                    .foregroundColor(.red)
                Text(failure.message)
                    .font(.subheadline)
                if let detail = failure.serverDetail {
                    Text("Server message: \(detail)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if failure.canRetry {
                Button {
                    model.generate(container: container)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canGenerate)
            }
        }
    }

    private var recentsSection: some View {
        Section {
            ForEach(model.recents.prompts, id: \.self) { recent in
                Button {
                    model.use(prompt: recent)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(recent)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Uses this recent request")
            }
            .onDelete { offsets in
                model.removeRecents(at: offsets)
            }
            Button("Clear Recent Prompts", role: .destructive) {
                showClearRecentsConfirmation = true
            }
        } header: {
            Text("Recent")
        } footer: {
            Text("Recent prompts are stored on this device only.")
        }
        .disabled(model.isGenerating)
    }

    // MARK: - Logic

    /// Remaining characters near the limit, or how far over it the text is.
    private var lengthHint: String? {
        if let excess = model.excessCharacters {
            return String(localized: "The description is \(excess) characters too long (limit: \(SagePrompt.maxLength)).")
        }
        let remaining = SagePrompt.remainingCharacters(for: model.prompt)
        if remaining <= Self.counterThreshold {
            return String(localized: "\(remaining) characters left")
        }
        return nil
    }
}

/// The waiting state: an estimated bar and what is probably happening. The
/// estimate comes from elapsed time only (`SageProgress`) and stops short of
/// full — the server reports nothing until it answers.
private struct SageProgressRow: View {
    let elapsed: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: SageProgress.estimatedFraction(elapsed: elapsed))
                .animation(.linear(duration: 0.5), value: elapsed)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text(stageText)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text("\(Int(elapsed)) s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stageText)
    }

    private var stageText: String {
        switch SageProgress.stage(elapsed: elapsed) {
        case .sending:
            return String(localized: "Sending your request\u{2026}")
        case .interpreting:
            return String(localized: "Sage is thinking about your request\u{2026}")
        case .matching:
            return String(localized: "Finding matching tracks in your library\u{2026}")
        case .takingLong:
            return String(localized: "Still working \u{2014} this is taking longer than usual\u{2026}")
        }
    }
}

/// Sonic Sage in a sheet, for entry points that cannot push onto a
/// navigation stack.
struct SonicSageSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SonicSageView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

/// Home entry for Sonic Sage, the sibling of the Sonic Adventure banner.
/// Renders nothing unless the provider supports Sage. Must sit inside
/// Home's `NavigationStack`; `inset` is `HomeMetrics.inset`.
struct SonicSageHomeEntry: View {
    @EnvironmentObject private var container: DependencyContainer
    let inset: CGFloat

    var body: some View {
        if container.sonicCapabilities.supports(.sage) {
            NavigationLink(destination: SonicSageView()) {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sonic Sage")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Describe a mood or a moment and get a playlist from your library.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityHidden(true)
                }
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.05, green: 0.42, blue: 0.48), Color(red: 0.12, green: 0.28, blue: 0.62)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, inset)
        }
    }
}
