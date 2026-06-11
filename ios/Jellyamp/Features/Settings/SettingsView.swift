import SwiftUI
import JellyampCore

struct SettingsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var sonicServerURL = ""
    @State private var sonicAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    VStack(alignment: .leading) {
                        Text("Crossfade: \(Int(container.settings.crossfadeDuration)) s")
                        Slider(value: $container.settings.crossfadeDuration, in: 0...12, step: 1)
                    }
                    Toggle("Loudness Leveling", isOn: $container.settings.loudnessLevelingEnabled)
                    Toggle("Silence Compression", isOn: $container.settings.silenceCompressionEnabled)
                }

                Section {
                    TextField("http://server:8095", text: $sonicServerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $sonicAPIKey)
                    LabeledContent("Status") {
                        if container.sonicCapabilities.supports(.adventure) {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Jellyfin fallback")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sonic Server")
                } footer: {
                    Text("Optional jellyamp-server for Sonic Adventure, Mixes for You and true sonic similarity. Without it, Jellyamp uses Jellyfin's built-in Instant Mix.")
                }

                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        container.signOut()
                    }
                }
            }
            .navigationTitle("Settings")
            .onDisappear {
                container.saveSettings()
                Task { await container.rewireSonicProvider() }
            }
        }
    }
}
