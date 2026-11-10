import Foundation
import SwiftUI
import JellyampCore
import SonicClient

/// Why a Sonic Sage request produced no playlist, in words for the builder
/// screen. One case per `SonicError` the endpoint can answer with, plus the
/// failures around it (network, resolving the tracks).
struct SageFailure: Equatable {
    let title: String
    let message: String
    /// The server's own explanation (English, from jellyamp-server), shown
    /// below the message when there is one.
    let serverDetail: String?
    let systemImage: String
    /// False when sending the same request again cannot help (the server
    /// has no Sage, the key is wrong).
    let canRetry: Bool

    init(
        title: String,
        message: String,
        serverDetail: String? = nil,
        systemImage: String = "exclamationmark.triangle",
        canRetry: Bool = true
    ) {
        self.title = title
        self.message = message
        self.serverDetail = serverDetail
        self.systemImage = systemImage
        self.canRetry = canRetry
    }

    /// Failure of the `POST /sage` call itself.
    static func request(_ error: Error) -> SageFailure {
        if let sonicError = error as? SonicError {
            return sonic(sonicError)
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return SageFailure(
                title: String(localized: "Sage Took Too Long"),
                message: String(localized: "Your jellyamp-server did not answer in time. The language model may be busy; try again in a moment."),
                systemImage: "clock"
            )
        }
        return SageFailure(
            title: String(localized: "Can't Reach the Sonic Server"),
            message: String(localized: "The request could not be sent. Check your connection and that jellyamp-server is running, then try again."),
            systemImage: "wifi.exclamationmark"
        )
    }

    static func sonic(_ error: SonicError) -> SageFailure {
        switch error {
        case .notFound:
            return SageFailure(
                title: String(localized: "Nothing Matched"),
                message: String(localized: "Sage found no analyzed tracks in your library that fit this request. Try a broader description, or a genre, mood or decade you know is in your library."),
                systemImage: "music.note.list"
            )
        case .unavailable(let detail):
            return SageFailure(
                title: String(localized: "Sonic Sage Isn't Ready"),
                message: String(localized: "Your jellyamp-server cannot run Sage right now: either no Anthropic API key is configured on it, or it has not analyzed any tracks yet."),
                serverDetail: cleaned(detail),
                systemImage: "hourglass",
                canRetry: false
            )
        case .upstreamFailure(let detail):
            return SageFailure(
                title: String(localized: "The Language Model Failed"),
                message: String(localized: "Your jellyamp-server could not get an answer from Anthropic. This is usually temporary; try again in a moment. If it keeps happening, check the API key and model configured on the server."),
                serverDetail: cleaned(detail),
                systemImage: "cloud.bolt"
            )
        case .unsupported:
            return SageFailure(
                title: String(localized: "Sonic Sage Unavailable"),
                message: String(localized: "The sonic provider in use does not offer Sage. It needs jellyamp-server 1.1 or later with an Anthropic API key."),
                systemImage: "xmark.circle",
                canRetry: false
            )
        case .unauthorized:
            return SageFailure(
                title: String(localized: "API Key Rejected"),
                message: String(localized: "The sonic server rejected the API key. Check Settings \u{2192} Sonic Server."),
                systemImage: "key",
                canRetry: false
            )
        case .invalidRequest(let detail):
            return SageFailure(
                title: String(localized: "Request Not Accepted"),
                message: String(localized: "The server did not accept this request. Shorten the description or choose a different number of tracks."),
                serverDetail: cleaned(detail)
            )
        case .serverError(let status):
            return SageFailure(
                title: String(localized: "Server Error"),
                message: String(localized: "Your jellyamp-server reported an error (HTTP \(status)). Check its log and try again.")
            )
        case .invalidResponse:
            return SageFailure(
                title: String(localized: "Unexpected Answer"),
                message: String(localized: "The sonic server answered in a format this version of Jellyamp does not understand. Updating the server or the app may help.")
            )
        }
    }

    /// Sage answered, but its tracks could not be loaded from Jellyfin.
    static func resolvingFailed() -> SageFailure {
        SageFailure(
            title: String(localized: "Tracks Could Not Be Loaded"),
            message: String(localized: "Sage created a playlist, but its tracks could not be loaded from your Jellyfin server. Check your connection and try again."),
            systemImage: "wifi.exclamationmark"
        )
    }

    /// Sage answered, but none of its tracks exist in the library any more.
    static func nothingResolved(picked: Int) -> SageFailure {
        SageFailure(
            title: String(localized: "Tracks No Longer in Your Library"),
            message: String(localized: "Sage picked \(picked) tracks, but none of them could be found on your Jellyfin server. The sonic server's analysis may be out of date; start a scan under Settings \u{2192} Sonic Server."),
            systemImage: "questionmark.folder"
        )
    }

    private static func cleaned(_ detail: String) -> String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// State of the Sonic Sage builder: the prompt being edited, the running
/// request, its outcome and the recent prompts. The rules (limits, recents,
/// result post-processing) live in JellyampCore (`SonicSage.swift`); this
/// class moves data between the sonic provider, the library and the view.
@MainActor
final class SonicSageModel: ObservableObject {
    /// Not a secret and not synced; prompts stay on this device.
    private static let recentsKey = "sonicSage.recentPrompts"

    private enum Outcome {
        case success(SageResult)
        case failure(SageFailure)
    }

    @Published var prompt = ""
    @Published var count = SageTrackCount.defaultCount
    /// When the running request started; nil while idle.
    @Published private(set) var generatingSince: Date?
    @Published private(set) var failure: SageFailure?
    @Published private(set) var result: SageResult?
    /// The normalized prompt `result` was generated from.
    @Published private(set) var resultPrompt = ""
    @Published var showResult = false
    @Published private(set) var recents: SageRecentPrompts

    private var task: Task<Void, Never>?
    /// Bumped on every start and cancel so an outdated request cannot
    /// publish its outcome.
    private var generation = 0

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents = SageRecentPrompts(prompts: stored)
    }

    var isGenerating: Bool { generatingSince != nil }

    var validation: Result<String, SagePrompt.ValidationError> {
        SagePrompt.validate(prompt)
    }

    var canGenerate: Bool {
        if isGenerating { return false }
        if case .success = validation { return true }
        return false
    }

    /// Characters over the server's limit, when the prompt is too long.
    var excessCharacters: Int? {
        if case .failure(.tooLong(let excess)) = validation { return excess }
        return nil
    }

    // MARK: - Editing

    func use(prompt text: String) {
        prompt = text
        failure = nil
    }

    func promptEdited() {
        // A failure describes the previous request, not the text being typed.
        if failure != nil, !isGenerating { failure = nil }
    }

    func removeRecents(at offsets: IndexSet) {
        let doomed = offsets.compactMap { index in
            recents.prompts.indices.contains(index) ? recents.prompts[index] : nil
        }
        for text in doomed {
            recents.remove(text)
        }
        persistRecents()
    }

    func clearRecents() {
        recents.removeAll()
        persistRecents()
    }

    private func persistRecents() {
        UserDefaults.standard.set(recents.prompts, forKey: Self.recentsKey)
    }

    // MARK: - Generating

    func generate(container: DependencyContainer) {
        guard !isGenerating, case .success(let text) = validation else { return }
        guard let sonic = container.sonic, let resolver = container.trackResolver else {
            failure = SageFailure.sonic(.unsupported(.sage))
            return
        }
        let requested = SageTrackCount.clamp(count)
        recents.record(text)
        persistRecents()

        generation += 1
        let token = generation
        failure = nil
        generatingSince = Date()
        task = Task { @MainActor [weak self] in
            let outcome = await SonicSageModel.run(prompt: text, count: requested, sonic: sonic, resolver: resolver)
            guard let self, self.generation == token else { return }
            self.generatingSince = nil
            self.task = nil
            switch outcome {
            case .success(let sage):
                self.result = sage
                self.resultPrompt = text
                self.showResult = true
            case .failure(let failure):
                self.failure = failure
            }
        }
    }

    /// Stops waiting for the running request. The server may still finish
    /// its work; the answer is discarded.
    func cancel() {
        guard isGenerating else { return }
        generation += 1
        task?.cancel()
        task = nil
        generatingSince = nil
    }

    private static func run(
        prompt: String,
        count: Int,
        sonic: SonicProviding,
        resolver: TrackResolver
    ) async -> Outcome {
        let playlist: SagePlaylist
        do {
            playlist = try await sonic.sagePlaylist(prompt: prompt, count: count)
        } catch {
            return .failure(SageFailure.request(error))
        }
        let resolved: [Track]
        do {
            resolved = try await resolver.tracks(byIDs: playlist.itemIDs)
        } catch {
            return .failure(SageFailure.resolvingFailed())
        }
        let sage = SageResult(
            title: playlist.title,
            description: playlist.description,
            itemIDs: playlist.itemIDs,
            resolved: resolved,
            requestedCount: count
        )
        if sage.isEmpty {
            // An empty ID list is the server's "nothing matched" in all but
            // status code.
            if sage.pickedCount == 0 {
                return .failure(SageFailure.sonic(.notFound("sage")))
            }
            return .failure(SageFailure.nothingResolved(picked: sage.pickedCount))
        }
        return .success(sage)
    }
}
