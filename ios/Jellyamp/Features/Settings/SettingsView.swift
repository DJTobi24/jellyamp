import SwiftUI
import JellyampCore

struct SettingsView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("Playback", systemImage: "waveform")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.playback)
                }

                Section {
                    NavigationLink {
                        DownloadSettingsView()
                    } label: {
                        Label("Downloads & Offline", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.downloads)
                }

                Section {
                    NavigationLink {
                        SonicSettingsView()
                    } label: {
                        LabeledContent("Sonic Server", value: container.isSonicServerActive ? String(localized: "Connected") : String(localized: "Jellyfin fallback"))
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.sonic)
                    NavigationLink {
                        ScrobblingSettingsView()
                    } label: {
                        Label("Scrobbling", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.scrobbling)
                } header: {
                    Text("Services")
                }

                Section("Account") {
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        AccountSettingsRow()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.account)
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.about)
                }
            }
            .navigationTitle("Settings")
            .onDisappear {
                container.saveSettings()
            }
        }
    }
}

/// Picks a built-in equalizer preset; applies it live and persists the choice.
struct EqualizerView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var selectedID: String = "flat"

    var body: some View {
        List {
            Section {
                EQGraph(bands: selectedPreset.bands)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section("Presets") {
                ForEach(EQPreset.builtIns) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        HStack {
                            Text(preset.localizedName).foregroundStyle(.primary)
                            Spacer()
                            if preset.id == selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Equalizer")
        .onAppear { selectedID = container.settings.activeEQPresetID ?? "flat" }
    }

    private var selectedPreset: EQPreset { EQPreset.builtIn(id: selectedID) ?? .flat }

    private func apply(_ preset: EQPreset) {
        selectedID = preset.id
        container.settings.activeEQPresetID = preset.id
        container.player?.apply(eqPreset: preset)
        container.saveSettings()
    }
}

/// A compact bar graph of an EQ preset: each band rises above (boost) or drops
/// below (cut) the center line.
struct EQGraph: View {
    let bands: [EQPreset.Band]
    private let maxGain = 8.0

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.height / 2 - 14   // leave room for the label
            HStack(alignment: .center, spacing: 6) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    VStack(spacing: 4) {
                        bar(gain: band.gainDB, half: half)
                        Text(label(band.frequency))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func bar(gain: Double, half: CGFloat) -> some View {
        let frac = CGFloat(max(-1, min(1, gain / maxGain)))
        let barHeight = abs(frac) * half
        return ZStack {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 5, height: half * 2)
            Capsule()
                .fill(.tint)
                .frame(width: 5, height: max(barHeight, frac == 0 ? 5 : barHeight))
                .offset(y: frac >= 0 ? -barHeight / 2 : barHeight / 2)
        }
        .frame(height: half * 2)
    }

    private func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}
