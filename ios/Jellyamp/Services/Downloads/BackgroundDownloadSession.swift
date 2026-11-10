import Foundation
import OSLog
import JellyampCore

/// Thin adapter between a background `URLSession` and the download queue in
/// JellyampCore. It knows nothing about pins or retries: it starts and stops
/// transfers, moves finished files into place and reports what happened.
///
/// Transfers run in the system's `nsurlsessiond`, so they continue while the
/// app is suspended or was terminated by the system. Because the app can be
/// relaunched in the background just to receive the results — before any UI
/// or `DownloadManager` exists — the delegate is self-sufficient: a finished
/// file is moved to its final name right here (the name travels in the task
/// description), and `DownloadIndex.reconcile` later adopts files it finds.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "dev.djtobi.Jellyamp.downloads"
    static let shared = BackgroundDownloadSession()

    enum Event: Sendable {
        case progress(trackID: String, bytesWritten: Int64, bytesExpected: Int64)
        /// The file is already at its final path.
        case finished(trackID: String, fileName: String, bytes: Int64)
        case failed(trackID: String, failure: DownloadFailure, resumeData: Data?)
    }

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "DownloadSession")
    private let lock = NSLock()
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var backgroundCompletionHandler: (() -> Void)?
    /// HTTP-level failures noticed in `didFinishDownloadingTo`, reported when
    /// the task completes. Only touched on the delegate queue.
    private var pendingFailures: [Int: DownloadFailure] = [:]
    private var finishedTasks: Set<Int> = []
    /// The one transfer per track we know about (guarded by `lock`). Commands
    /// act on this table synchronously: looking tasks up asynchronously via
    /// `getAllTasks` could hit a transfer that was restarted in the meantime
    /// (pause immediately followed by resume).
    private var tasksByTrackID: [String: URLSessionDownloadTask] = [:]

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.djtobi.Jellyamp.downloads.delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        // Downloads are user-initiated (or cheap to delay ourselves); don't let
        // the system postpone them until the device is charging.
        configuration.isDiscretionary = false
        // Cellular is decided per request from the user's setting.
        configuration.allowsCellularAccess = true
        // The bound on concurrent transfers once the app is suspended and
        // the whole queue has been handed over (see `DownloadManager`).
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        super.init()
    }

    /// Creates the session (reconnecting to transfers that outlived the last
    /// launch) and installs the receiver of events. Events are delivered on
    /// the main actor.
    func setEventHandler(_ handler: (@MainActor (Event) -> Void)?) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
        _ = session
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        // Touching the session re-creates it so the pending delegate calls arrive.
        _ = session
    }

    // MARK: Commands

    func start(
        trackID: String,
        fileName: String,
        url: URL,
        resumeData: Data?,
        allowsCellular: Bool,
        expectedBytes: Int64
    ) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowsCellular
            // Personal hotspots are cellular data too.
            request.allowsExpensiveNetworkAccess = allowsCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = TaskInfo(trackID: trackID, fileName: fileName).encoded
        if expectedBytes > 0 {
            task.countOfBytesClientExpectsToReceive = expectedBytes
        }
        lock.lock()
        let previous = tasksByTrackID.updateValue(task, forKey: trackID)
        lock.unlock()
        previous?.cancel()
        task.resume()
    }

    /// Stops a transfer and hands back resume data when the server supports
    /// ranges (Jellyfin does), so "pause" does not throw away progress.
    func pause(trackID: String, completion: @escaping @Sendable (Data?) -> Void) {
        guard let task = takeTask(for: trackID) else {
            completion(nil)
            return
        }
        task.cancel(byProducingResumeData: completion)
    }

    func cancel(trackIDs: Set<String>) {
        for trackID in trackIDs {
            takeTask(for: trackID)?.cancel()
        }
    }

    func cancelAll() {
        lock.lock()
        let known = Array(tasksByTrackID.values)
        tasksByTrackID = [:]
        lock.unlock()
        known.forEach { $0.cancel() }
        // Transfers from an earlier launch that were never adopted. Anything
        // started after this call is in the table again and is left alone.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where !self.isCurrent(task) {
                task.cancel()
            }
        }
    }

    /// Track ids that still have a transfer in the system's hands. Adopts
    /// transfers that survived from a previous launch so they can be paused
    /// and cancelled like new ones.
    func liveTrackIDs() async -> Set<String> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            session.getAllTasks { [weak self] tasks in
                var ids = Set<String>()
                for task in tasks where task.state == .running || task.state == .suspended {
                    guard let self, let download = task as? URLSessionDownloadTask, let info = TaskInfo(task: task) else {
                        task.cancel()
                        continue
                    }
                    if self.adopt(download, for: info.trackID) {
                        ids.insert(info.trackID)
                    } else {
                        // A second transfer for the same track: keep one.
                        task.cancel()
                    }
                }
                continuation.resume(returning: ids)
            }
        }
    }

    private func takeTask(for trackID: String) -> URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasksByTrackID.removeValue(forKey: trackID)
    }

    /// Registers a surviving transfer unless the track already has another one.
    private func adopt(_ task: URLSessionDownloadTask, for trackID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tasksByTrackID[trackID] {
            return existing === task
        }
        tasksByTrackID[trackID] = task
        return true
    }

    private func isCurrent(_ task: URLSessionTask) -> Bool {
        guard let info = TaskInfo(task: task) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return tasksByTrackID[info.trackID] === task
    }

    private func forget(_ task: URLSessionTask, trackID: String) {
        lock.lock()
        if tasksByTrackID[trackID] === task { tasksByTrackID[trackID] = nil }
        lock.unlock()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = TaskInfo(task: downloadTask) else { return }
        emit(.progress(trackID: info.trackID, bytesWritten: totalBytesWritten, bytesExpected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = TaskInfo(task: downloadTask) else { return }
        // A download task "succeeds" for any HTTP status; an error page must
        // not be saved as audio.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = DownloadFailure.from(httpStatus: status) {
            pendingFailures[downloadTask.taskIdentifier] = failure
            return
        }
        // `location` is deleted when this method returns: move synchronously.
        DownloadStore.ensureDirectory()
        let destination = DownloadStore.fileURL(named: info.fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            finishedTasks.insert(downloadTask.taskIdentifier)
            emit(.finished(trackID: info.trackID, fileName: info.fileName, bytes: Int64(size)))
        } catch {
            log.error("could not store download: \(error.localizedDescription, privacy: .public)")
            pendingFailures[downloadTask.taskIdentifier] = .fileSystem
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        let httpFailure = pendingFailures.removeValue(forKey: identifier)
        let didFinish = finishedTasks.remove(identifier) != nil
        guard let info = TaskInfo(task: task) else { return }
        forget(task, trackID: info.trackID)
        if let httpFailure {
            emit(.failed(trackID: info.trackID, failure: httpFailure, resumeData: nil))
            return
        }
        guard let error else {
            if !didFinish {
                // Completed without a file and without an error: treat as a
                // broken response so the queue retries or surfaces it.
                emit(.failed(trackID: info.trackID, failure: .badResponse, resumeData: nil))
            }
            return
        }
        let nsError = error as NSError
        // Cancellations are always our own doing (pause, remove, settings
        // change); the queue already knows.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        emit(.failed(trackID: info.trackID, failure: Self.failure(for: nsError), resumeData: resumeData))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        // UIKit requires the completion handler on the main thread.
        DispatchQueue.main.async(execute: handler)
    }

    // MARK: Helpers

    private func emit(_ event: Event) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        guard let handler else { return }
        Task { @MainActor in handler(event) }
    }

    static func failure(for error: NSError) -> DownloadFailure {
        guard error.domain == NSURLErrorDomain else {
            return error.domain == NSCocoaErrorDomain ? .fileSystem : .network
        }
        switch error.code {
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
            return .unauthorized
        case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile,
            NSURLErrorCannotMoveFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotCloseFile:
            return .fileSystem
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorCannotDecodeContentData:
            return .badResponse
        default:
            return .network
        }
    }

    /// Identity of a transfer, carried in `taskDescription` because that is
    /// the only per-task storage that survives an app relaunch.
    struct TaskInfo {
        let trackID: String
        let fileName: String

        init(trackID: String, fileName: String) {
            self.trackID = trackID
            self.fileName = fileName
        }

        init?(task: URLSessionTask) {
            guard let description = task.taskDescription else { return nil }
            let parts = description.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            trackID = String(parts[0])
            fileName = String(parts[1])
        }

        var encoded: String { "\(trackID)\n\(fileName)" }
    }
}
