import SwiftUI
import JellyampCore

/// Settings → Scrobbling: connect ListenBrainz and Last.fm, switch each on or
/// off, and see what is still waiting to be sent. Push it from a row:
/// `NavigationLink("Scrobbling") { ScrobblingSettingsView() }`.
struct ScrobblingSettingsView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        // The service is a separate observable object; a child view observes
        // it so queue counts and connection state update live.
        ScrobblingSettingsForm(service: container.scrobbling)
    }
}

private struct ScrobblingSettingsForm: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var service: ScrobbleService

    @State private var listenBrainzToken = ""
    @State private var listenBrainzServer = ""
    @State private var isValidatingListenBrainz = false
    @State private var listenBrainzError: String?
    @State private var isConnectingLastFM = false
    @State private var lastFMError: String?

    var body: some View {
        Form {
            listenBrainzSection
            lastFMSection
            if hasQueueSection {
                queueSection
            }
            Section {
                EmptyView()
            } footer: {
                Text("When a service is switched on, Jellyamp sends it the artist, title, album and time of each track you play, as soon as playback starts and again once you have listened to half of it (or four minutes). That information is stored in your account at that service under its own privacy policy. Nothing is sent while both services are off, and Jellyamp itself collects nothing.")
            }
        }
        .navigationTitle("Scrobbling")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            listenBrainzServer = container.settings.scrobbling.listenBrainzServerURL?.absoluteString ?? ""
        }
    }

    // MARK: - ListenBrainz

    private var isListenBrainzConnected: Bool {
        service.hasListenBrainzToken && container.settings.scrobbling.listenBrainzUsername != nil
    }

    private var listenBrainzSection: some View {
        Section {
            if isListenBrainzConnected {
                LabeledContent("Connected as", value: listenBrainzDisplayName)
                Toggle("Scrobble to ListenBrainz", isOn: listenBrainzEnabledBinding)
                Button("Disconnect", role: .destructive) {
                    disconnectListenBrainz()
                }
            } else {
                if service.status.needsReauthentication.contains(.listenBrainz) {
                    Label("ListenBrainz no longer accepts the saved token. Enter a new one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                SecureField("User token", text: $listenBrainzToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Server (optional)", text: $listenBrainzServer)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    validateListenBrainz()
                } label: {
                    HStack {
                        Text("Connect")
                        if isValidatingListenBrainz {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isValidatingListenBrainz || listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("Get your token", destination: ListenBrainzClient.tokenSettingsURL)
            }
            if let listenBrainzError {
                Text(listenBrainzError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("ListenBrainz")
        } footer: {
            if !isListenBrainzConnected {
                Text("Copy the user token from your ListenBrainz settings page and paste it here. Leave Server empty unless you run your own ListenBrainz-compatible server.")
            }
        }
    }

    private var listenBrainzDisplayName: String {
        let name = container.settings.scrobbling.listenBrainzUsername ?? ""
        return name.isEmpty ? String(localized: "Token accepted") : name
    }

    private var listenBrainzEnabledBinding: Binding<Bool> {
        Binding(
            get: { container.settings.scrobbling.listenBrainzEnabled },
            set: { newValue in
                container.settings.scrobbling.listenBrainzEnabled = newValue
                container.saveSettings()
            }
        )
    }

    private func validateListenBrainz() {
        let trimmedServer = listenBrainzServer.trimmingCharacters(in: .whitespacesAndNewlines)
        var serverURL: URL?
        if !trimmedServer.isEmpty {
            guard let parsed = URL(string: trimmedServer), parsed.scheme == "https" || parsed.scheme == "http", parsed.host != nil else {
                listenBrainzError = String(localized: "Enter the server address as a full URL, for example https://listens.example.org")
                return
            }
            serverURL = parsed
        }
        listenBrainzError = nil
        isValidatingListenBrainz = true
        let token = listenBrainzToken
        Task {
            let result = await service.connectListenBrainz(token: token, serverURL: serverURL)
            isValidatingListenBrainz = false
            switch result {
            case .success(let username):
                listenBrainzToken = ""
                container.settings.scrobbling.listenBrainzUsername = username
                container.settings.scrobbling.listenBrainzServerURL = serverURL
                container.settings.scrobbling.listenBrainzEnabled = true
                container.saveSettings()
            case .failure(let error):
                listenBrainzError = error.message
            }
        }
    }

    private func disconnectListenBrainz() {
        service.disconnectListenBrainz()
        container.settings.scrobbling.listenBrainzEnabled = false
        container.settings.scrobbling.listenBrainzUsername = nil
        container.saveSettings()
        listenBrainzError = nil
    }

    // MARK: - Last.fm

    private var lastFMSection: some View {
        Section {
            if service.lastFMCredentials == nil {
                Label("Last.fm is not available in this build.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if service.isLastFMConnected {
                LabeledContent("Connected as", value: container.settings.scrobbling.lastFMUsername ?? "Last.fm")
                Toggle("Scrobble to Last.fm", isOn: lastFMEnabledBinding)
                Button("Disconnect", role: .destructive) {
                    disconnectLastFM()
                }
            } else {
                if service.status.needsReauthentication.contains(.lastFM) {
                    Label("Last.fm no longer accepts the saved sign-in. Connect again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    connectLastFM()
                } label: {
                    HStack {
                        Text("Connect to Last.fm")
                        if isConnectingLastFM {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isConnectingLastFM)
            }
            if let lastFMError {
                Text(lastFMError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            if service.lastFMCredentials == nil {
                Text("Last.fm requires an API key that is added when the app is built. This build was made without one, so only ListenBrainz is offered.")
            } else if !service.isLastFMConnected {
                Text("Connect opens Last.fm. Sign in, choose “Yes, allow access”, then tap Done to return to Jellyamp.")
            }
        }
    }

    private var lastFMEnabledBinding: Binding<Bool> {
        Binding(
            get: { container.settings.scrobbling.lastFMEnabled },
            set: { newValue in
                container.settings.scrobbling.lastFMEnabled = newValue
                container.saveSettings()
            }
        )
    }

    private func connectLastFM() {
        lastFMError = nil
        isConnectingLastFM = true
        Task {
            let result = await service.connectLastFM()
            isConnectingLastFM = false
            switch result {
            case .success(let username):
                container.settings.scrobbling.lastFMUsername = username
                container.settings.scrobbling.lastFMEnabled = true
                container.saveSettings()
            case .failure(let error):
                lastFMError = error.message
            }
        }
    }

    private func disconnectLastFM() {
        service.disconnectLastFM()
        container.settings.scrobbling.lastFMEnabled = false
        container.settings.scrobbling.lastFMUsername = nil
        container.saveSettings()
        lastFMError = nil
    }

    // MARK: - Queue

    private var hasQueueSection: Bool {
        service.status.totalPending > 0 || !service.status.lastError.isEmpty
    }

    private var queueSection: some View {
        Section {
            ForEach(ScrobbleServiceID.allCases, id: \.self) { serviceID in
                queueRows(for: serviceID)
            }
            if service.status.totalPending > 0 {
                Button("Send Now") {
                    service.flush(ignoringBackoff: true)
                }
            }
        } header: {
            Text("Waiting to Send")
        } footer: {
            Text("Listens that could not be delivered are kept on this device and sent automatically when the service is reachable again. They are discarded after two weeks.")
        }
    }

    @ViewBuilder
    private func queueRows(for serviceID: ScrobbleServiceID) -> some View {
        let pending = service.status.pending[serviceID] ?? 0
        if pending > 0 {
            LabeledContent(serviceID.displayName, value: Self.waitingText(pending))
        }
        if let message = service.status.lastError[serviceID] {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last error (\(serviceID.displayName))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.footnote)
            }
        }
    }

    private static func waitingText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 listen waiting") : String(localized: "\(count) listens waiting")
    }
}
