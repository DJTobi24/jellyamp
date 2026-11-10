import SwiftUI
import JellyampCore
import SonicClient

/// Settings for the optional jellyamp-server: URL + API key (the key lives in
/// the Keychain), connection test, analysis progress and which sonic
/// features are active. Push it from a Settings row:
///
///     NavigationLink("Sonic Server") { SonicSettingsView() }
///
/// Saving re-wires the provider (`DependencyContainer.updateSonicServer`), so
/// the rest of the app follows the new capabilities immediately.
struct SonicSettingsView: View {
    /// Result of the last probe of the values in the form.
    private enum ProbeResult: Equatable {
        case connected(version: String?)
        case unauthorized
        case incompatible(version: String)
        case unreachable
        case invalidURL
        case missingKey
    }

    static let serverGuideURL = URL(string: "https://github.com/DJTobi24/jellyamp/blob/main/server/README.md")!

    @EnvironmentObject private var container: DependencyContainer
    @State private var urlText = ""
    @State private var keyText = ""
    @State private var hasStoredKey = false
    @State private var isWorking = false
    @State private var probeResult: ProbeResult?
    @State private var connectedVersion: String?
    @State private var showRemoveConfirmation = false

    var body: some View {
        Form {
            statusSection
            serverSection
            if let progress = analysisSummary {
                analysisSection(progress)
            }
            featuresSection
            aboutSection
        }
        .navigationTitle("Sonic Server")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCurrent() }
        .refreshable { await refreshStatus() }
        .confirmationDialog("Remove the sonic server?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jellyamp goes back to Jellyfin's built-in Instant Mix. The API key is deleted from this device.")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var serverSection: some View {
        Section {
            TextField("http://server:8095", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(hasStoredKey ? "API Key (saved \u{2014} enter to replace)" : "API Key", text: $keyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isWorking { ProgressView() }
                }
            }
            .disabled(isWorking || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Save") {
                Task { await save() }
            }
            .disabled(isWorking || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            if container.settings.sonicServerURL != nil {
                Button("Remove Server", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Server")
        } footer: {
            if let probeResult {
                Text(message(for: probeResult))
                    .foregroundColor(isSuccess(probeResult) ? .green : .red)
            } else {
                Text("The address of your jellyamp-server and the SONIC_API_KEY you configured for it.")
            }
        }
    }

    private func analysisSection(_ progress: AnalysisProgressSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction)
                Text("\(progress.tracksAnalyzed) of \(progress.tracksTotal) tracks analyzed (\(progress.percent.formatted(.percent)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Library Analysis")
        } footer: {
            if progress.isComplete {
                Text("Your whole library has been analyzed.")
            } else {
                Text("Analysis runs in the background on the server. Sonic features only cover analyzed tracks; pull down to update.")
            }
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(SonicCapability.allCases, id: \.self) { capability in
                featureRow(capability)
            }
        } header: {
            Text("Features")
        } footer: {
            Text("Features marked \u{201C}Jellyfin\u{201D} work without the sonic server, using Jellyfin's metadata instead of audio analysis.")
        }
    }

    private func featureRow(_ capability: SonicCapability) -> some View {
        let active = container.sonicCapabilities.supports(capability)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(active ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(featureName(capability))
                Text(featureDescription(capability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(featureState(active: active))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var aboutSection: some View {
        Section {
            Text("jellyamp-server is an optional, self-hosted companion. It listens to your library once and then finds music that actually sounds alike: Sonic Adventure, weekly Mixes for You, sonically ranked stations and loudness for untagged tracks. Without it Jellyamp keeps working with Jellyfin's Instant Mix and genre or decade stations.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(destination: Self.serverGuideURL) {
                Label("Set Up jellyamp-server", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Status

    private var analysisSummary: AnalysisProgressSummary? {
        guard container.isSonicServerActive, let progress = container.sonicCapabilities.analysisProgress else { return nil }
        return AnalysisProgressSummary(tracksAnalyzed: progress.tracksAnalyzed, tracksTotal: progress.tracksTotal)
    }

    private var isConfigured: Bool {
        container.settings.sonicServerURL != nil
    }

    private var statusSymbol: String {
        if container.isSonicServerActive { return "checkmark.circle.fill" }
        return isConfigured ? "exclamationmark.triangle.fill" : "circle.dashed"
    }

    private var statusColor: Color {
        if container.isSonicServerActive { return .green }
        return isConfigured ? .orange : .secondary
    }

    private var statusTitle: LocalizedStringKey {
        if container.isSonicServerActive { return "Connected" }
        return isConfigured ? "Server Not In Use" : "Jellyfin Fallback Active"
    }

    private var statusDetail: String {
        if container.isSonicServerActive {
            if let connectedVersion {
                return String(localized: "jellyamp-server \(connectedVersion)")
            }
            return String(localized: "jellyamp-server is providing the sonic features.")
        }
        guard isConfigured else {
            return String(localized: "No sonic server configured. Similar music and stations come from Jellyfin.")
        }
        // Configured but the provider fell back: say why, if we know.
        switch probeResult {
        case .unauthorized:
            return String(localized: "The server rejected the API key. Jellyfin fallback is active.")
        case .incompatible(let version):
            return String(localized: "Server version \(version) is not supported by this app. Jellyfin fallback is active.")
        case .missingKey:
            return String(localized: "No API key is saved. Jellyfin fallback is active.")
        case .unreachable, .invalidURL, .connected, .none:
            return String(localized: "The server could not be reached. Jellyfin fallback is active.")
        }
    }

    private func isSuccess(_ result: ProbeResult) -> Bool {
        if case .connected = result { return true }
        return false
    }

    private func message(for result: ProbeResult) -> String {
        switch result {
        case .connected(let version):
            if let version {
                return String(localized: "Connection OK \u{2014} jellyamp-server \(version).")
            }
            return String(localized: "Connection OK.")
        case .unauthorized:
            return String(localized: "The server answered, but rejected the API key.")
        case .incompatible(let version):
            return String(localized: "Server version \(version) is not compatible with this app (version 1.x required).")
        case .unreachable:
            return String(localized: "The server could not be reached. Check the address and that it is running.")
        case .invalidURL:
            return String(localized: "That does not look like a server address. Example: http://192.168.1.10:8095")
        case .missingKey:
            return String(localized: "Enter the API key of your jellyamp-server.")
        }
    }

    private func featureName(_ capability: SonicCapability) -> LocalizedStringKey {
        switch capability {
        case .similar: return "Similar Music"
        case .adventure: return "Sonic Adventure"
        case .mixes: return "Mixes for You"
        case .stations: return "Stations"
        case .loudness: return "Measured Loudness"
        @unknown default: return LocalizedStringKey(capability.rawValue.capitalized)
        }
    }

    private func featureDescription(_ capability: SonicCapability) -> LocalizedStringKey {
        let server = container.isSonicServerActive
        switch capability {
        case .similar:
            return server ? "Similar tracks, albums and artists by sound." : "Similar items and Instant Mix from Jellyfin's metadata."
        case .adventure:
            return "A path of tracks from one song to another."
        case .mixes:
            return "Weekly mixes built around your listening."
        case .stations:
            return server ? "Genre and decade stations ranked by sound." : "Random genre and decade stations from Jellyfin."
        case .loudness:
            return "Loudness leveling for tracks without gain tags."
        @unknown default:
            return ""
        }
    }

    private func featureState(active: Bool) -> LocalizedStringKey {
        guard active else { return "Needs Server" }
        return container.isSonicServerActive ? "Active" : "Jellyfin"
    }

    // MARK: - Actions

    private func loadCurrent() async {
        if urlText.isEmpty, let url = container.settings.sonicServerURL {
            urlText = url.absoluteString
        }
        hasStoredKey = container.storedSonicAPIKey != nil
        await refreshStatus()
    }

    /// Re-probes the saved configuration: refreshes capabilities and analysis
    /// progress, and finds out why a configured server is not in use.
    private func refreshStatus() async {
        guard let url = container.settings.sonicServerURL else { return }
        await container.rewireSonicProvider()
        guard let key = container.storedSonicAPIKey else {
            if !container.isSonicServerActive { probeResult = .missingKey }
            return
        }
        let result = await probe(url: url, apiKey: key)
        if case .connected(let version) = result {
            connectedVersion = version
        } else if !container.isSonicServerActive {
            probeResult = result
        }
    }

    /// The values to act on: the typed URL, and the typed key or — when the
    /// field was left empty — the one already in the Keychain.
    private func formValues() -> (url: URL, apiKey: String)? {
        guard case .valid(let url) = SonicServerConfig.parseURL(urlText) else {
            probeResult = .invalidURL
            return nil
        }
        let typedKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = typedKey.isEmpty ? container.storedSonicAPIKey : typedKey, !apiKey.isEmpty else {
            probeResult = .missingKey
            return nil
        }
        return (url, apiKey)
    }

    private func testConnection() async {
        guard let values = formValues() else { return }
        isWorking = true
        probeResult = await probe(url: values.url, apiKey: values.apiKey)
        isWorking = false
    }

    private func save() async {
        guard let values = formValues() else { return }
        isWorking = true
        let typedKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        await container.updateSonicServer(url: values.url, newAPIKey: typedKey.isEmpty ? nil : typedKey)
        let result = await probe(url: values.url, apiKey: values.apiKey)
        probeResult = result
        if case .connected(let version) = result { connectedVersion = version }
        urlText = values.url.absoluteString
        keyText = ""
        hasStoredKey = container.storedSonicAPIKey != nil
        isWorking = false
    }

    private func remove() {
        isWorking = true
        Task { @MainActor in
            await container.updateSonicServer(url: nil, newAPIKey: nil)
            urlText = ""
            keyText = ""
            hasStoredKey = false
            probeResult = nil
            connectedVersion = nil
            isWorking = false
        }
    }

    private func probe(url: URL, apiKey: String) async -> ProbeResult {
        switch await SonicServerDiscovery().probe(baseURL: url, apiKey: apiKey) {
        case .available:
            return .connected(version: await Self.fetchVersion(baseURL: url, apiKey: apiKey))
        case .unauthorized:
            return .unauthorized
        case .incompatibleVersion(let version):
            return .incompatible(version: version)
        case .unreachable:
            return .unreachable
        @unknown default:
            return .unreachable
        }
    }

    /// The discovery outcome carries capabilities but not the version string,
    /// so read it from `/api/v1/info` for display.
    private static func fetchVersion(baseURL: URL, apiKey: String) async -> String? {
        var request = URLRequest(url: SonicServerConfig.infoURL(baseURL: baseURL))
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSessionTransport().send(request),
              response.statusCode == 200 else { return nil }
        return SonicServerConfig.version(fromInfoBody: data)
    }
}
