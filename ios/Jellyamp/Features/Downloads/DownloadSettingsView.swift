import SwiftUI
import JellyampCore

/// Settings for offline use: offline mode, cellular downloads, smart sync
/// rules and storage. Self-contained destination — push it from a Settings
/// row (`NavigationLink("Downloads & Offline") { DownloadSettingsView() }`).
/// Reads and writes `container.settings` and saves on every change.
struct DownloadSettingsView: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        DownloadSettingsForm(
            status: container.offline.status,
            syncState: container.offline.syncState
        )
    }
}

private struct DownloadSettingsForm: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var status: OfflineStatus
    @ObservedObject var syncState: SmartSyncState
    @State private var confirmsRemoveAll = false

    /// Storage limits offered for smart sync, in megabytes (0 = unlimited).
    private let storageLimits = [0, 1024, 2048, 5120, 10240, 20480, 51200]

    var body: some View {
        Form {
            offlineSection
            networkSection
            smartSyncSection
            if let downloads = container.downloads {
                DownloadStorageSection(downloads: downloads, confirmsRemoveAll: $confirmsRemoveAll)
            }
        }
        .navigationTitle("Downloads & Offline")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: container.settings) { _ in
            container.saveSettings()
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All Downloads", role: .destructive) {
                container.downloads?.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded music is deleted from this device. Nothing changes on your server.")
        }
    }

    private var offlineSection: some View {
        Section {
            Toggle("Offline Mode", isOn: $container.settings.offlineModeEnabled)
            if let reason = status.reason, reason != .userEnabled {
                Label(OfflineBanner.message(for: reason), systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Browse and play only downloaded music, without contacting your server. Jellyamp also switches to your downloads automatically when the server can't be reached.")
        }
    }

    private var networkSection: some View {
        Section {
            Toggle("Download over Cellular", isOn: $container.settings.downloadsOverCellular)
        } footer: {
            Text("When off, downloads and Smart Sync wait for Wi-Fi.")
        }
    }

    private var smartSyncSection: some View {
        let supportsMixes = container.sonicCapabilities.supports(.mixes)
        return Section {
            Toggle("Favorite Songs", isOn: $container.settings.smartSync.autoDownloadFavorites)
            Toggle("Favorite Albums", isOn: $container.settings.smartSync.autoDownloadFavoriteAlbums)
            Stepper(value: $container.settings.smartSync.keepLatestMixes, in: 0...10) {
                LabeledContent("Mixes for You", value: mixesLabel)
            }
            .disabled(!supportsMixes)
            Picker("Storage Limit", selection: $container.settings.smartSync.maxStorageMB) {
                ForEach(storageLimits, id: \.self) { megabytes in
                    Text(storageLimitLabel(megabytes)).tag(megabytes)
                }
            }
            Button {
                container.offline.syncNow()
            } label: {
                HStack {
                    Text("Sync Now")
                    Spacer()
                    if syncState.isRunning {
                        ProgressView()
                    }
                }
            }
            .disabled(syncState.isRunning || status.isOffline)
        } header: {
            Text("Smart Sync")
        } footer: {
            Text(smartSyncFooter(supportsMixes: supportsMixes))
        }
    }

    private var mixesLabel: String {
        let count = container.settings.smartSync.keepLatestMixes
        if count == 0 { return String(localized: "Off") }
        return count == 1 ? String(localized: "Newest mix") : String(localized: "Newest \(count) mixes")
    }

    private func storageLimitLabel(_ megabytes: Int) -> String {
        if megabytes == 0 { return String(localized: "Unlimited") }
        return DownloadFormatting.bytes(Int64(megabytes) * 1_048_576)
    }

    private func smartSyncFooter(supportsMixes: Bool) -> String {
        var lines = [
            String(localized: "Smart Sync keeps this music downloaded automatically and removes it again when it no longer matches. Music you download yourself is never removed.")
        ]
        if !supportsMixes {
            lines.append(String(localized: "Mixes for You needs the optional Sonic server."))
        }
        switch syncState.lastResult {
        case .done(let date)?:
            let time = date.formatted(date: .abbreviated, time: .shortened)
            lines.append(String(localized: "Last synced \(time)."))
            if syncState.skippedForStorage > 0 {
                lines.append(String(localized: "\(syncState.skippedForStorage) songs were left out because of the storage limit."))
            }
        case .skippedOffline?:
            lines.append(String(localized: "Sync is waiting until your server is reachable."))
        case .skippedCellular?:
            lines.append(String(localized: "Sync is waiting for Wi-Fi."))
        case .failed?:
            lines.append(String(localized: "The last sync could not be completed."))
        case nil:
            break
        }
        return lines.joined(separator: "\n")
    }
}

private struct DownloadStorageSection: View {
    @ObservedObject var downloads: DownloadManager
    @Binding var confirmsRemoveAll: Bool

    var body: some View {
        Section {
            LabeledContent("Downloaded", value: summary)
            if let free = DownloadStore.freeBytes() {
                LabeledContent("Free on This Device", value: DownloadFormatting.bytes(free))
            }
            Button("Remove All Downloads", role: .destructive) {
                confirmsRemoveAll = true
            }
            .disabled(downloads.index.entries.isEmpty)
        } header: {
            Text("Storage")
        }
    }

    private var summary: String {
        let count = downloads.downloaded.count
        let songs = count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
        return "\(songs) · \(DownloadFormatting.bytes(downloads.totalBytes))"
    }
}
