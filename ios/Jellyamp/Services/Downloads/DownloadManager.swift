import Foundation
import Combine
import OSLog
import UIKit
import JellyampCore
import JellyfinBackend

/// Live transfer progress, kept apart from `DownloadManager` so that only the
/// progress bars re-render on every tick, not every list that shows download
/// state.
@MainActor
final class DownloadProgressModel: ObservableObject {
    /// Fraction (0…1) per track id that is currently transferring.
    @Published fileprivate(set) var fractions: [String: Double] = [:]

    func fraction(for trackID: String) -> Double? { fractions[trackID] }
}

/// Download state of a set of tracks (an album, a playlist, one track) for
/// buttons and badges.
enum DownloadCollectionState: Equatable {
    case notDownloaded
    /// Some tracks are still queued / transferring.
    case inProgress(complete: Int, total: Int)
    /// Nothing is moving, but not everything is there (paused or failed).
    case incomplete(complete: Int, total: Int, hasFailures: Bool)
    case downloaded
}

/// Owns the download index and drives the queue: the decisions (what to start,
/// when to retry, what a removed pin frees) come from `DownloadIndex` in
/// JellyampCore; this class persists the index and adapts
/// `BackgroundDownloadSession` and the file system to it.
///
/// Files are the original bytes from `/Items/{id}/Download` (so quality is
/// kept); the audio engine prefers a local file via `DownloadStore`.
@MainActor
final class DownloadManager: ObservableObject, OfflineCatalogProviding {
    /// The persisted truth. Views read pins / entries from here.
    @Published private(set) var index = DownloadIndex()
    /// Fully downloaded tracks, in download order.
    @Published private(set) var downloaded: [Track] = []
    /// Tracks that are queued, transferring, paused or waiting for a retry.
    @Published private(set) var inProgress: [Track] = []
    /// Tracks whose download gave up and needs a manual retry.
    @Published private(set) var failed: Set<String> = []
    /// True once the index has been reconciled with the system's transfers.
    @Published private(set) var isReady = false

    let progress = DownloadProgressModel()
    /// Called when the server refuses a download with 401: the token may be
    /// dead, and while only downloads are running nothing else would notice.
    var onUnauthorized: (() -> Void)?

    private let session: JellyfinSession
    private let transport: BackgroundDownloadSession
    private let policy = DownloadQueuePolicy()
    /// How many transfers are handed to the system when the app leaves the
    /// foreground. A suspended app is not woken between transfers, so the
    /// in-app queue cannot feed them one by one; the session then limits
    /// concurrency itself (`httpMaximumConnectionsPerHost`).
    private let backgroundWindow = 200
    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Downloads")
    private var allowsCellular = false
    private var genreNamesByID: [String: String] = [:]
    private var cachedCatalog: OfflineCatalog?
    private var saveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(session: JellyfinSession, transport: BackgroundDownloadSession = .shared) {
        self.session = session
        self.transport = transport
        DownloadStore.ensureDirectory()
        loadIndex()
        publishDerivedState()
        transport.setEventHandler { [weak self] event in
            self?.handle(event)
        }
        // The debounced save must not be lost when the app is suspended.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pump(window: self.backgroundWindow)
                    self.saveNow()
                }
            }
            .store(in: &cancellables)
        Task { await self.reconcile() }
    }

    // MARK: State queries

    func isDownloaded(_ trackID: String) -> Bool { index.isComplete(trackID) }

    func isInProgress(_ trackID: String) -> Bool {
        guard let phase = index.entry(for: trackID)?.phase else { return false }
        return phase != .complete && phase != .failed
    }

    func phase(for trackID: String) -> DownloadPhase? { index.entry(for: trackID)?.phase }

    func state(forTrackIDs ids: [String]) -> DownloadCollectionState {
        var total = 0
        var complete = 0
        var moving = 0
        var failures = 0
        for id in ids {
            guard let entry = index.entry(for: id) else { continue }
            total += 1
            switch entry.phase {
            case .complete: complete += 1
            case .queued, .downloading, .waitingToRetry: moving += 1
            case .failed: failures += 1
            case .paused: break
            }
        }
        if total == 0 { return .notDownloaded }
        if moving > 0 { return .inProgress(complete: complete, total: total) }
        // Tracks of the collection that were never requested count as missing.
        if complete == ids.count { return .downloaded }
        return .incomplete(complete: complete, total: ids.count, hasFailures: failures > 0)
    }

    /// The browsable offline library (complete tracks only).
    var catalog: OfflineCatalog {
        if let cachedCatalog { return cachedCatalog }
        let fresh = OfflineCatalog(index: index, genreNamesByID: genreNamesByID)
        cachedCatalog = fresh
        return fresh
    }

    func offlineCatalog() async -> OfflineCatalog { catalog }

    var totalBytes: Int64 { index.totalBytes }

    /// Whether a track is on the device only because smart sync put it there.
    func isAutoSyncedOnly(_ trackID: String) -> Bool {
        let pins = index.pins(containing: trackID)
        return !pins.isEmpty && pins.allSatisfy(\.isAutomatic)
    }

    // MARK: Downloading

    /// Downloads a bare list of tracks. Several tracks of one album are kept
    /// as that album; anything else as individual songs.
    func download(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if let album = DownloadPinInference.singleAlbum(in: tracks) {
            download(album: album, tracks: tracks)
            return
        }
        let now = Date()
        var change = DownloadIndex.Change()
        for track in tracks {
            var pin = DownloadPin.track(track, now: now)
            pin.trackIDs = [track.id]
            let partial = index.setPin(pin, tracks: [track], now: now)
            change.queued.append(contentsOf: partial.queued)
            change.removed.append(contentsOf: partial.removed)
        }
        reviveStalled(tracks.map(\.id))
        apply(change)
    }

    func download(_ track: Track) { download([track]) }

    func download(album: Album, tracks: [Track]) {
        setPin(DownloadPin.album(album, now: Date()), tracks: tracks)
    }

    func download(playlist: Playlist, tracks: [Track]) {
        setPin(DownloadPin.playlist(playlist, now: Date()), tracks: tracks)
    }

    func download(artist: Artist, tracks: [Track]) {
        setPin(DownloadPin.artist(artist, now: Date()), tracks: tracks)
    }

    /// Creates or refreshes a pin so it covers exactly `tracks`. Used for
    /// downloads, for playlist re-sync and by smart sync.
    func setPin(_ pin: DownloadPin, tracks: [Track], reviveStalled revive: Bool = true) {
        let change = index.setPin(pin, tracks: tracks, now: Date())
        if revive, !pin.isAutomatic { reviveStalled(tracks.map(\.id)) }
        apply(change)
    }

    /// Executes a smart-sync plan: the smart-sync pin afterwards covers
    /// exactly the plan's desired tracks; what it no longer covers is evicted
    /// unless the user pinned it.
    func applySmartSync(plan: SmartSyncPlanner.Plan, tracksByID: [String: Track]) {
        let tracks = plan.desired.compactMap { tracksByID[$0] }
        let change = index.setPin(DownloadPin.smartSync(now: Date()), tracks: tracks, now: Date())
        log.info("smart sync: \(change.queued.count, privacy: .public) queued, \(change.removed.count, privacy: .public) evicted")
        apply(change)
    }

    // MARK: Removing

    /// "Remove Download" for one track, wherever it came from.
    func remove(_ track: Track) { removeTrack(id: track.id) }

    func removeTrack(id: String) { apply(index.removeTrack(id: id)) }

    /// Removes an album's downloads; tracks a playlist still needs stay.
    func removeAlbum(id: String) { apply(index.removeAlbum(id: id)) }

    func removePin(id: String) { apply(index.removePin(id: id)) }

    /// Removes whatever keeps the given tracks: the album if they form one,
    /// else the individual tracks.
    func remove(_ tracks: [Track]) {
        if let album = DownloadPinInference.singleAlbum(in: tracks) {
            removeAlbum(id: album.id)
        } else {
            var change = DownloadIndex.Change()
            for track in tracks {
                change.removed.append(contentsOf: index.removeTrack(id: track.id).removed)
            }
            apply(change)
        }
    }

    /// Deletes every download (sign-out, "Remove All Downloads").
    func clearAll() {
        _ = index.removeAll()
        transport.cancelAll()
        DownloadStore.wipe()
        genreNamesByID = [:]
        progress.fractions = [:]
        retryTask?.cancel()
        commit()
        saveNow()
    }

    /// The session ended but the downloads stay (expired sign-in): stops the
    /// running transfers and puts them back in the queue. Their requests
    /// carry the dead token, and so does their resume data; the manager of
    /// the next session starts them afresh.
    func suspendTransfers() {
        retryTask?.cancel()
        let running = index.orderedEntries.filter { $0.phase == .downloading }.map(\.id)
        transport.cancel(trackIDs: Set(running))
        for trackID in running {
            DownloadStore.deleteResumeData(for: trackID)
            progress.fractions[trackID] = nil
            index.requeue(id: trackID)
        }
        // Refused transfers are worth another try with the new token.
        for entry in index.orderedEntries where entry.phase == .failed && entry.failure == .unauthorized {
            index.retry(id: entry.id)
        }
        publishDerivedState()
        saveNow()
    }

    // MARK: Queue control

    func pause(_ trackID: String) {
        let wasRunning = index.pause(id: trackID)
        if wasRunning { stopKeepingProgress(trackID) }
        commit()
        pump()
    }

    func resume(_ trackID: String) {
        index.resume(id: trackID)
        commit()
        pump()
    }

    func retry(_ trackID: String) {
        index.retry(id: trackID)
        commit()
        pump()
    }

    func pauseAll() {
        for trackID in index.pauseAll() { stopKeepingProgress(trackID) }
        commit()
    }

    func resumeAll() {
        index.resumeAll()
        index.retryAllFailed()
        commit()
        pump()
    }

    var hasPausedDownloads: Bool {
        index.pendingEntries.contains { $0.phase == .paused }
    }

    // MARK: Settings

    /// Applies the cellular setting. Transfers already running were created
    /// with the old value, so they are restarted under the new one.
    func apply(settings: AppSettings) {
        guard settings.downloadsOverCellular != allowsCellular else { return }
        allowsCellular = settings.downloadsOverCellular
        let running = index.orderedEntries.filter { $0.phase == .downloading }.map(\.id)
        guard !running.isEmpty else { return }
        transport.cancel(trackIDs: Set(running))
        for trackID in running {
            // Resume data carries the old request (and its cellular flag).
            DownloadStore.deleteResumeData(for: trackID)
            progress.fractions[trackID] = nil
            index.requeue(id: trackID)
        }
        commit()
        pump()
    }

    /// Remembers the server's genre ids so genre screens opened online still
    /// resolve offline.
    func remember(genres: [Genre]) {
        var changed = false
        for genre in genres where genreNamesByID[genre.id] != genre.name {
            genreNamesByID[genre.id] = genre.name
            changed = true
        }
        guard changed else { return }
        cachedCatalog = nil
        if let data = try? JSONEncoder().encode(genreNamesByID) {
            try? data.write(to: DownloadStore.genresURL, options: .atomic)
        }
    }

    // MARK: Queue engine

    /// Starts as many transfers as the policy allows (or, with `window`, as
    /// many as should be in the system's hands at once).
    private func pump(window: Int? = nil) {
        guard isReady else { return }
        var storageWasShort = false
        var effectivePolicy = policy
        if let window { effectivePolicy.maxConcurrent = max(window, policy.maxConcurrent) }
        let started = index.startNext(now: Date(), policy: effectivePolicy)
        for entry in started {
            let expected = DownloadStorage.estimatedBytes(for: entry.track)
            guard DownloadStorage.canStart(expectedBytes: expected, freeBytes: DownloadStore.freeBytes()) else {
                index.markFailed(id: entry.id, failure: .insufficientStorage, now: Date(), policy: policy.retry)
                storageWasShort = true
                continue
            }
            transport.start(
                trackID: entry.id,
                fileName: entry.fileName,
                url: StreamURLBuilder.downloadURL(for: entry.id, session: session),
                resumeData: DownloadStore.takeResumeData(for: entry.id),
                allowsCellular: allowsCellular,
                expectedBytes: expected
            )
        }
        if !started.isEmpty { commit() }
        // Entries failed for lack of space freed their slots; the rest of the
        // queue gets the same verdict instead of silently sitting there.
        if storageWasShort { pump(window: window) }
        scheduleRetryWake()
    }

    private func handle(_ event: BackgroundDownloadSession.Event) {
        switch event {
        case .progress(let trackID, let written, let expected):
            guard expected > 0, index.entry(for: trackID)?.phase == .downloading else { return }
            let fraction = min(max(Double(written) / Double(expected), 0), 1)
            // Whole percents only: enough for a progress bar, few UI updates.
            if abs(fraction - (progress.fractions[trackID] ?? -1)) >= 0.01 {
                progress.fractions[trackID] = fraction
            }
        case .finished(let trackID, let fileName, let bytes):
            progress.fractions[trackID] = nil
            DownloadStore.deleteResumeData(for: trackID)
            guard let entry = index.entry(for: trackID), entry.fileName == fileName else {
                // Removed while the last bytes arrived.
                DownloadStore.deleteFile(named: fileName)
                return
            }
            index.markCompleted(id: trackID, bytes: bytes, now: Date())
            log.info("downloaded \(entry.track.title, privacy: .public)")
            commit()
            pump()
        case .failed(let trackID, let failure, let resumeData):
            progress.fractions[trackID] = nil
            guard index.entry(for: trackID) != nil else { return }
            if let resumeData { DownloadStore.saveResumeData(resumeData, for: trackID) }
            let decision = index.markFailed(id: trackID, failure: failure, now: Date(), policy: policy.retry)
            if failure == .unauthorized { onUnauthorized?() }
            log.error("download failed (\(failure.rawValue, privacy: .public)), \(String(describing: decision), privacy: .public)")
            commit()
            pump()
        }
    }

    /// Wakes the queue when the next automatic retry is due. While the app is
    /// suspended nothing fires; `reconcile` + `pump` on the next launch or
    /// foreground catch up.
    private func scheduleRetryWake() {
        retryTask?.cancel()
        guard let date = index.nextRetryDate else { return }
        let delay = max(date.timeIntervalSinceNow, 0) + 0.1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    /// Called when the app returns to the foreground: due retries start now.
    func wake() { pump() }

    /// A new download request for tracks that are paused or failed means
    /// "try again".
    private func reviveStalled(_ trackIDs: [String]) {
        for trackID in trackIDs {
            index.resume(id: trackID)
            index.retry(id: trackID)
        }
    }

    /// Stops a running transfer but keeps what was received for a later resume.
    private func stopKeepingProgress(_ trackID: String) {
        progress.fractions[trackID] = nil
        transport.pause(trackID: trackID) { resumeData in
            if let resumeData { DownloadStore.saveResumeData(resumeData, for: trackID) }
        }
    }

    /// Carries out what an index mutation implies on disk and in the queue.
    private func apply(_ change: DownloadIndex.Change) {
        if !change.removed.isEmpty {
            transport.cancel(trackIDs: Set(change.removed.map(\.id)))
            for entry in change.removed {
                DownloadStore.deleteFile(named: entry.fileName)
                DownloadStore.deleteResumeData(for: entry.id)
                progress.fractions[entry.id] = nil
            }
            DownloadArtworkStore.prune(keeping: index.referencedArtworkItemIDs)
        }
        if !change.queued.isEmpty {
            DownloadArtworkStore.fetchMissing(
                itemIDs: index.referencedArtworkItemIDs,
                session: session,
                allowsCellular: allowsCellular
            )
        }
        commit()
        pump()
    }

    // MARK: Persistence

    private func loadIndex() {
        if let data = try? Data(contentsOf: DownloadStore.genresURL),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            genreNamesByID = names
        }
        guard let data = try? Data(contentsOf: DownloadStore.indexURL) else { return }
        do {
            index = try DownloadIndex.decode(from: data)
        } catch {
            // Unreadable (corrupt, or written by a newer version): start over.
            // `reconcile` then removes the files nothing refers to.
            log.error("download index unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            index = DownloadIndex()
        }
    }

    /// Aligns the index with the transfers the system still runs and the
    /// files on disk, cleans up leftovers, then opens the queue.
    private func reconcile() async {
        let live = await transport.liveTrackIDs()
        let files = DownloadStore.audioFiles()
        let result = index.reconcile(liveTaskIDs: live, files: files, now: Date())
        transport.cancel(trackIDs: Set(result.strayTaskIDs))
        for fileName in result.orphanFiles {
            DownloadStore.deleteFile(named: fileName)
        }
        DownloadStore.pruneResumeData(keeping: Set(index.pendingEntries.map(\.id)))
        let artworkIDs = index.referencedArtworkItemIDs
        DownloadArtworkStore.prune(keeping: artworkIDs)
        DownloadArtworkStore.fetchMissing(itemIDs: artworkIDs, session: session, allowsCellular: allowsCellular)
        isReady = true
        commit()
        pump()
    }

    /// Publishes the derived state and schedules a save.
    private func commit() {
        cachedCatalog = nil
        publishDerivedState()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Coalesce bursts (an album finishing track by track).
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? index.encoded() else { return }
        try? data.write(to: DownloadStore.indexURL, options: .atomic)
    }

    private func publishDerivedState() {
        var complete: [Track] = []
        var pending: [Track] = []
        var failures = Set<String>()
        var fileNames: [String: String] = [:]
        for entry in index.orderedEntries {
            switch entry.phase {
            case .complete:
                complete.append(entry.track)
                fileNames[entry.id] = entry.fileName
            case .failed:
                failures.insert(entry.id)
                pending.append(entry.track)
            case .queued, .downloading, .paused, .waitingToRetry:
                pending.append(entry.track)
            }
        }
        DownloadStore.setCompleteFileNames(fileNames)
        downloaded = complete
        inProgress = pending
        failed = failures
    }
}
