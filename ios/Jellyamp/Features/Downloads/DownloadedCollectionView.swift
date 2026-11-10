import SwiftUI
import JellyampCore

/// Detail screen of a downloaded album, playlist or artist: what is on the
/// device (and what is still coming), with Play / Shuffle and removal. Works
/// entirely from the download index, so it is the same online and offline.
struct DownloadedCollectionView: View {
    enum Collection: Hashable {
        /// All downloaded tracks of an album, whatever pinned them.
        case album(String)
        /// A pin id (`DownloadPin.id`): a downloaded playlist or artist.
        case pin(String)
    }

    @EnvironmentObject private var container: DependencyContainer
    let collection: Collection

    var body: some View {
        if let downloads = container.downloads {
            DownloadedCollectionContent(downloads: downloads, collection: collection)
        }
    }
}

private struct DownloadedCollectionContent: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloads: DownloadManager
    let collection: DownloadedCollectionView.Collection
    @State private var confirmsRemoval = false

    /// Everything the header and list need, resolved from the index.
    private struct Model {
        var title: String
        var subtitle: String
        var artworkItemID: String
        var imageTag: String?
        var entries: [DownloadEntry]
        var showsTrackNumbers: Bool
    }

    private var model: Model? {
        switch collection {
        case .album(let albumID):
            let entries = downloads.index.orderedEntries.filter { $0.track.albumID == albumID }
            guard !entries.isEmpty else { return nil }
            let order = OfflineCatalog.albumOrder(entries.map(\.track)).map(\.id)
            var byID: [String: DownloadEntry] = [:]
            for entry in entries { byID[entry.id] = entry }
            let album = downloads.catalog.album(id: albumID)
                ?? OfflineCatalog.derivedAlbum(id: albumID, tracks: entries.map(\.track))
            return Model(
                title: album.title,
                subtitle: album.artistName,
                artworkItemID: albumID,
                imageTag: album.imageTag,
                entries: order.compactMap { byID[$0] },
                showsTrackNumbers: true
            )
        case .pin(let pinID):
            guard let pin = downloads.index.pin(id: pinID) else { return nil }
            return Model(
                title: pin.title,
                subtitle: pin.subtitle ?? "",
                artworkItemID: pin.itemID,
                imageTag: pin.imageTag,
                entries: downloads.index.entries(forPin: pinID),
                showsTrackNumbers: false
            )
        }
    }

    var body: some View {
        if let model {
            list(model)
        } else {
            ContentUnavailableCompatView(
                title: "Not Downloaded",
                systemImage: "arrow.down.circle",
                description: "This download was removed."
            )
        }
    }

    private func list(_ model: Model) -> some View {
        let playable = model.entries.filter { $0.phase == .complete }.map(\.track)
        return List {
            Section {
                header(model, playable: playable)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, number: index + 1, showsNumber: model.showsTrackNumbers)
                        .contentShape(Rectangle())
                        .onTapGesture { play(entry, in: playable) }
                        .trackContextActions(entry.track)
                }
                .onDelete { offsets in
                    for index in offsets { downloads.removeTrack(id: model.entries[index].id) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove Download")
            }
        }
        .confirmationDialog("Remove this download?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                removeCollection()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Songs that another downloaded playlist or album still needs stay on this device.")
        }
    }

    private func header(_ model: Model, playable: [Track]) -> some View {
        let bytes = model.entries.reduce(Int64(0)) { $0 + ($1.phase == .complete ? $1.bytes : 0) }
        return VStack(spacing: 12) {
            ArtworkView(itemID: model.artworkItemID, imageTag: model.imageTag, size: 200)
            Text(model.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .foregroundStyle(.secondary)
            }
            Text("\(playable.count) of \(model.entries.count) songs downloaded · \(DownloadFormatting.bytes(bytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    container.player?.load(queue: PlayQueue(tracks: playable, startAt: 0))
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    container.player?.playShuffled(playable)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(playable.isEmpty)
        }
    }

    private func row(_ entry: DownloadEntry, number: Int, showsNumber: Bool) -> some View {
        HStack(spacing: 8) {
            if showsNumber {
                Text("\(entry.track.indexNumber ?? number)")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            } else {
                ArtworkView(itemID: entry.track.albumID ?? entry.id, imageTag: entry.track.imageTag, size: 40)
            }
            VStack(alignment: .leading) {
                Text(entry.track.title)
                    .lineLimit(1)
                    .foregroundStyle(entry.phase == .complete ? Color.primary : Color.secondary)
                Text(entry.phase == .complete ? entry.track.artistName : DownloadFormatting.status(of: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            DownloadStatusBadge(trackID: entry.id)
            TrackMenuButton(track: entry.track)
        }
    }

    private func play(_ entry: DownloadEntry, in playable: [Track]) {
        guard let index = playable.firstIndex(where: { $0.id == entry.id }) else { return }
        container.player?.load(queue: PlayQueue(tracks: playable, startAt: index))
    }

    private func removeCollection() {
        switch collection {
        case .album(let albumID):
            downloads.removeAlbum(id: albumID)
        case .pin(let pinID):
            downloads.removePin(id: pinID)
        }
    }
}
