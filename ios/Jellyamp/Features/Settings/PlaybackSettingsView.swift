import SwiftUI
import JellyampCore

/// Settings → Playback. Self-contained: push it from a row inside the
/// Settings navigation stack. Every change is saved and handed to the engine
/// immediately, so sliders can be judged by ear while music plays.
struct PlaybackSettingsView: View {
    @EnvironmentObject private var container: DependencyContainer

    /// Bitrate caps offered for streaming; nil = the original file.
    private static let bitrateOptions: [Int?] = [nil, 320_000, 256_000, 192_000, 128_000, 96_000]

    var body: some View {
        Form {
            transitionsSection
            loudnessSection
            silenceSection
            streamingSection
            sleepTimerSection
            visualizerSection
            queueSection
            equalizerSection
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: container.settings) { _ in
            container.saveSettings()
        }
    }

    // MARK: - Sections

    private var transitionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Crossfade") {
                    Text(container.settings.crossfadeDuration > 0
                         ? String(localized: "\(Int(container.settings.crossfadeDuration)) s")
                         : String(localized: "Off"))
                        .monospacedDigit()
                }
                Slider(value: $container.settings.crossfadeDuration, in: 0...12, step: 1) {
                    Text("Crossfade")
                } minimumValueLabel: {
                    Text("0").font(.caption2)
                } maximumValueLabel: {
                    Text("12").font(.caption2)
                }
                .accessibilityValue(container.settings.crossfadeDuration > 0
                                    ? "\(Int(container.settings.crossfadeDuration)) seconds"
                                    : "Off")
            }
        } header: {
            Text("Transitions")
        } footer: {
            Text("Overlaps the end of a track with the start of the next. Consecutive tracks of the same album are never crossfaded, so live albums and DJ mixes play through uninterrupted.")
        }
    }

    private var loudnessSection: some View {
        Section {
            Toggle("Loudness Leveling", isOn: $container.settings.loudnessLevelingEnabled)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Preamp") {
                    Text(Self.decibels(container.settings.loudnessPreampDB))
                        .monospacedDigit()
                }
                Slider(value: $container.settings.loudnessPreampDB, in: -12...6, step: 0.5) {
                    Text("Preamp")
                } minimumValueLabel: {
                    Text("−12").font(.caption2)
                } maximumValueLabel: {
                    Text("+6").font(.caption2)
                }
                .accessibilityValue(Self.decibels(container.settings.loudnessPreampDB))
            }
        } header: {
            Text("Volume")
        } footer: {
            Text(loudnessFooter)
        }
    }

    private var loudnessFooter: String {
        var text = String(localized: "Plays every track at a similar loudness using the gain Jellyfin stores for it. Tracks of one album that follow each other share a single gain, so the album keeps its own dynamics.")
        if container.sonicCapabilities.supports(.loudness) {
            text += " " + String(localized: "Tracks without a stored gain are measured by your sonic server.")
        } else {
            text += " " + String(localized: "Tracks without a stored gain play unchanged.")
        }
        text += " " + String(localized: "Quiet tracks are only raised when their measured peak leaves room, so a positive preamp never causes clipping.")
        return text
    }

    private var silenceSection: some View {
        Section {
            Toggle("Silence Compression", isOn: $container.settings.silenceCompressionEnabled)
        } footer: {
            Text("Skips digital silence: lead-ins are shortened to half a second, and silent stretches inside or at the end of a track to two seconds. Hidden tracks and long fade-outs start sooner; nothing audible is removed. Takes effect from the next track or seek.")
        }
    }

    private var streamingSection: some View {
        Section {
            Picker("Wi-Fi", selection: $container.settings.playbackProfile.maxBitrateWifi) {
                ForEach(Self.bitrateOptions, id: \.self) { option in
                    Text(Self.bitrateLabel(option)).tag(option)
                }
            }
            Picker("Cellular", selection: $container.settings.playbackProfile.maxBitrateCellular) {
                ForEach(Self.bitrateOptions, id: \.self) { option in
                    Text(Self.bitrateLabel(option)).tag(option)
                }
            }
            Toggle("Always Transcode on Cellular", isOn: $container.settings.playbackProfile.forceTranscodeOnCellular)
        } header: {
            Text("Streaming Quality")
        } footer: {
            Text("Tracks above the limit are converted by the server to MP3 at that bitrate; everything else streams as the original file. Personal hotspots count as cellular. Downloaded tracks always play in original quality.")
        }
    }

    private var sleepTimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Fade Out") {
                    Text(container.settings.sleepTimerFadeOut > 0
                         ? String(localized: "\(Int(container.settings.sleepTimerFadeOut)) s")
                         : String(localized: "Off"))
                        .monospacedDigit()
                }
                Slider(value: $container.settings.sleepTimerFadeOut, in: 0...60, step: 5) {
                    Text("Sleep timer fade out")
                }
                .accessibilityValue(container.settings.sleepTimerFadeOut > 0
                                    ? "\(Int(container.settings.sleepTimerFadeOut)) seconds"
                                    : "Off")
            }
        } header: {
            Text("Sleep Timer")
        } footer: {
            Text("How long the music fades before a timed sleep timer pauses playback. Start a timer from the moon button in the player.")
        }
    }

    private var visualizerSection: some View {
        Section {
            Picker("Visualizer", selection: $container.settings.visualizerStyle) {
                Text("Off").tag(VisualizerStyle.off)
                Text("Bars").tag(VisualizerStyle.bars)
                Text("Wave").tag(VisualizerStyle.wave)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Visualizer")
        } footer: {
            Text("Shown over the artwork in the player; tap the artwork to switch styles. It pauses in Low Power Mode, with Reduce Motion, and whenever the player is not on screen.")
        }
    }

    private var queueSection: some View {
        Section {
            Toggle("Autoplay", isOn: $container.settings.autoplayEnabled)
        } footer: {
            Text("When the queue runs out, keep playing similar music. Stations from Home always keep going, whatever this is set to.")
        }
    }

    private var equalizerSection: some View {
        Section {
            NavigationLink {
                EqualizerView()
            } label: {
                LabeledContent("Equalizer", value: EQPreset.builtIn(id: container.settings.activeEQPresetID)?.localizedName ?? String(localized: "Off"))
            }
        }
    }

    // MARK: - Formatting

    private static func bitrateLabel(_ bitrate: Int?) -> String {
        guard let bitrate else { return String(localized: "Original") }
        return "\(bitrate / 1000) kbps"
    }

    private static func decibels(_ value: Double) -> String {
        if value == 0 { return "0 dB" }
        // A real minus sign, and one decimal only when it is needed.
        let magnitude = abs(value)
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : String(format: "%.1f", magnitude)
        return (value > 0 ? "+" : "−") + number + " dB"
    }
}
