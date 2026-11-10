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
    /// What the saved server said about itself in the last probe.
    @State private var serverInfo: SonicServerInfo?
    @State private var isStartingScan = false
    @State private var scanError: String?

    var body: some View {
        Form {
            statusSection
            serverSection
            if let capabilities = serverCapabilities {
                analysisSection(capabilities)
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

    private func analysisSection(_ capabilities: SonicCapabilities) -> some View {
        let scan = capabilities.scan
        let isScanning = scan?.isScanning ?? false
        return Section {
            if let progress = analysisSummary(capabilities) {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fraction)
                    Text("\(progress.tracksAnalyzed) of \(progress.tracksTotal) tracks analyzed (\(progress.percent.formatted(.percent)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            if let scan {
                LabeledContent("Scan", value: scanStateText(scan))
                if scan.tracksFailed > 0 {
                    LabeledContent("Could Not Be Analyzed", value: "\(scan.tracksFailed)")
                }
                if let lastError = scan.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if let backend = capabilities.analysisBackend {
                LabeledContent("Analysis Engine", value: backendName(backend))
            }
            Button {
                Task { await startScan(retryFailed: false) }
            } label: {
                HStack {
                    Text("Scan Now")
                    Spacer()
                    if isStartingScan { ProgressView() }
                }
            }
            .disabled(isStartingScan || isScanning)
            if let scan, scan.tracksFailed > 0 {
                Button("Retry Failed Tracks") {
                    Task { await startScan(retryFailed: true) }
                }
                .disabled(isStartingScan || isScanning)
            }
        } header: {
            Text("Library Analysis")
        } footer: {
            if let scanError {
                Text(scanError).foregroundColor(.red)
            } else if isScanning {
                Text("The server is analyzing your library. Sonic features only cover analyzed tracks; pull down to update.")
            } else if analysisSummary(capabilities)?.isComplete == true {
                Text("Your whole library has been analyzed. New music is picked up by the server's regular scans, or right away with Scan Now.")
            } else {
                Text("Analysis runs in the background on the server. Sonic features only cover analyzed tracks; pull down to update.")
            }
        }
    }

    private func scanStateText(_ scan: SonicScanStatus) -> String {
        if scan.isScanning {
            return scan.tracksPending > 0
                ? String(localized: "Running, \(scan.tracksPending) tracks to go")
                : String(localized: "Running")
        }
        if let finishedAt = scan.finishedAt {
            return String(localized: "Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Not run yet")
    }

    private func backendName(_ backend: SonicAnalysisBackend) -> String {
        let name: String
        switch backend.name {
        case "dsp": name = String(localized: "Built-in DSP")
        case "musicnn": name = "Essentia MusiCNN"
        default: name = backend.name
        }
        return backend.version.isEmpty ? name : "\(name) \(backend.version)"
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

    /// The server's own picture of its analysis: from the last probe when
    /// there is one, else from the active provider. Not simply
    /// `container.sonicCapabilities` — while the first analysis runs the
    /// server offers no capabilities yet and the app is on the Jellyfin
    /// fallback, which is exactly when the progress matters.
    private var serverCapabilities: SonicCapabilities? {
        if let serverInfo { return serverInfo.capabilities }
        return container.isSonicServerActive ? container.sonicCapabilities : nil
    }

    private func analysisSummary(_ capabilities: SonicCapabilities) -> AnalysisProgressSummary? {
        guard let progress = capabilities.analysisProgress else { return nil }
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
        case .connected:
            // Reachable, but it offers nothing yet.
            return String(localized: "The server is reachable but has not finished its first library analysis. Jellyfin fallback is active until then.")
        case .unreachable, .invalidURL, .none:
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
        case .sage: return "Sonic Sage"
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
        case .sage:
            return "Playlists from a text description, using the language model configured on the server."
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
        let probed = await probe(url: url, apiKey: key)
        serverInfo = probed.info
        if case .connected(let version) = probed.result {
            connectedVersion = version
        }
        if !container.isSonicServerActive {
            probeResult = probed.result
        }
    }

    /// Asks the server to scan now and shows the status it answers with.
    private func startScan(retryFailed: Bool) async {
        guard let url = container.settings.sonicServerURL, let key = container.storedSonicAPIKey else { return }
        isStartingScan = true
        scanError = nil
        defer { isStartingScan = false }
        // The active provider when the server is in use; while it is still
        // on its first analysis the app runs on the fallback provider, which
        // has no scan — then talk to the configured server directly.
        let provider: SonicProviding
        if container.isSonicServerActive, let active = container.sonic {
            provider = active
        } else {
            provider = SonicAPIClient(baseURL: url, apiKey: key)
        }
        do {
            let status = try await provider.startScan(retryFailed: retryFailed)
            serverInfo?.capabilities.scan = status
        } catch {
            scanError = String(localized: "The scan could not be started. Check that the server is running and reachable.")
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
        probeResult = await probe(url: values.url, apiKey: values.apiKey).result
        isWorking = false
    }

    private func save() async {
        guard let values = formValues() else { return }
        isWorking = true
        let typedKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        await container.updateSonicServer(url: values.url, newAPIKey: typedKey.isEmpty ? nil : typedKey)
        let probed = await probe(url: values.url, apiKey: values.apiKey)
        probeResult = probed.result
        serverInfo = probed.info
        if case .connected(let version) = probed.result { connectedVersion = version }
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
            serverInfo = nil
            scanError = nil
            isWorking = false
        }
    }

    /// One request tells everything: reachability, authorization, contract
    /// version, and — in the server's info — analysis progress and scan state.
    private func probe(url: URL, apiKey: String) async -> (result: ProbeResult, info: SonicServerInfo?) {
        let details = await SonicServerDiscovery().probeDetails(baseURL: url, apiKey: apiKey)
        switch details.outcome {
        case .available:
            return (.connected(version: details.info?.version), details.info)
        case .unauthorized:
            return (.unauthorized, nil)
        case .incompatibleVersion(let version):
            return (.incompatible(version: version), nil)
        case .unreachable:
            return (.unreachable, nil)
        @unknown default:
            return (.unreachable, nil)
        }
    }
}
