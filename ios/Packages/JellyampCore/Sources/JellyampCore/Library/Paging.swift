import Foundation

/// One slice of a server-side list. `totalCount` is the size of the whole
/// list when the server reports it (Jellyfin's `TotalRecordCount`).
public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var totalCount: Int?

    public init(items: [Item], totalCount: Int? = nil) {
        self.items = items
        self.totalCount = totalCount
    }
}

extension Page: Equatable where Item: Equatable {}

/// A request handed out by `PagedListState`. The result must be given back
/// together with the request so answers to superseded requests are dropped.
public struct PageRequest: Equatable, Sendable {
    public let generation: Int
    public let startIndex: Int
    public let limit: Int
    /// True when the answer replaces the list instead of extending it.
    public let isReload: Bool
}

/// State machine behind every infinitely scrolling list.
///
/// The rules it enforces, so that views cannot get them wrong:
/// - only one request is in flight; a reload supersedes everything before it
///   (answers carrying an older `generation` are ignored),
/// - a row never appears twice, even when the library changes between two
///   page requests and the server shifts items across the page boundary,
/// - paging continues from the *server* offset, not from the number of rows
///   shown, so dropped duplicates do not make the list re-request a page,
/// - a failed next page keeps the rows that are already on screen.
public struct PagedListState<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing requested yet.
        case idle
        /// First page (or a reload that cleared the list) is in flight.
        case loadingFirstPage
        /// A reload is in flight while the previous rows stay visible.
        case refreshing
        /// A further page is in flight.
        case loadingNextPage
        /// At rest.
        case loaded
    }

    public enum Failure: Equatable, Sendable {
        /// The first page / a reload failed.
        case reload(String)
        /// A later page failed; the rows shown so far are still valid.
        case nextPage(String)

        public var message: String {
            switch self {
            case .reload(let message), .nextPage(let message): return message
            }
        }
    }

    public let pageSize: Int
    public private(set) var items: [Item] = []
    public private(set) var phase: Phase = .idle
    public private(set) var failure: Failure?
    public private(set) var totalCount: Int?
    public private(set) var reachedEnd = false
    /// Server index of the first row. Non-zero after jumping into the middle
    /// of the list (A–Z index).
    public private(set) var baseOffset = 0
    /// True while the rows come from the on-disk cache and no server answer
    /// has replaced them yet.
    public private(set) var isShowingCachedItems = false

    private var generation = 0
    private var nextServerIndex = 0
    private var seen: Set<Item.ID> = []

    public init(pageSize: Int = 100) {
        self.pageSize = max(1, pageSize)
    }

    // MARK: - Derived state

    /// Show a skeleton: nothing to display yet and a request is running.
    public var isInitialLoading: Bool {
        items.isEmpty && (phase == .loadingFirstPage || phase == .refreshing || phase == .idle) && failure == nil
    }

    /// Show the empty state: the server answered and there is nothing.
    public var isEmpty: Bool {
        items.isEmpty && phase == .loaded && failure == nil
    }

    /// Show the full-screen error state: the reload failed and there is
    /// nothing (not even cached rows) to fall back on.
    public var blockingError: String? {
        guard items.isEmpty, case .reload(let message)? = failure else { return nil }
        return message
    }

    public var isLoadingMore: Bool { phase == .loadingNextPage }

    public var isBusy: Bool { phase == .loadingFirstPage || phase == .refreshing || phase == .loadingNextPage }

    // MARK: - Transitions

    /// Paints cached rows before the first server answer. Ignored once
    /// anything else is on screen.
    public mutating func seed(_ cached: [Item]) {
        guard items.isEmpty, totalCount == nil, !cached.isEmpty else { return }
        setItems(cached)
        isShowingCachedItems = true
    }

    /// Starts over. `keepingItems` leaves the current rows visible until the
    /// answer arrives (pull to refresh); otherwise the list is cleared (sort
    /// or filter changed, so the old rows would be misleading).
    public mutating func beginReload(fromOffset offset: Int = 0, keepingItems: Bool = true) -> PageRequest {
        generation += 1
        failure = nil
        if !keepingItems {
            items = []
            seen = []
            totalCount = nil
            isShowingCachedItems = false
        }
        phase = items.isEmpty ? .loadingFirstPage : .refreshing
        return PageRequest(generation: generation, startIndex: max(0, offset), limit: pageSize, isReload: true)
    }

    /// The next page, or nil when one is already running, the end is reached
    /// or the list was never loaded.
    public mutating func beginNextPage() -> PageRequest? {
        guard phase == .loaded, !reachedEnd, !isShowingCachedItems else { return nil }
        if case .reload? = failure { return nil }
        failure = nil
        phase = .loadingNextPage
        return PageRequest(generation: generation, startIndex: nextServerIndex, limit: pageSize, isReload: false)
    }

    /// Applies an answer. Returns false when it belonged to a superseded
    /// request and was dropped.
    @discardableResult
    public mutating func receive(_ page: Page<Item>, for request: PageRequest) -> Bool {
        guard request.generation == generation else { return false }
        if request.isReload {
            items = []
            seen = []
            baseOffset = request.startIndex
            isShowingCachedItems = false
        }
        for item in page.items where seen.insert(item.id).inserted {
            items.append(item)
        }
        nextServerIndex = request.startIndex + page.items.count
        if let total = page.totalCount { totalCount = total }
        if page.items.isEmpty {
            reachedEnd = true
        } else if let total = page.totalCount {
            reachedEnd = nextServerIndex >= total
        } else {
            reachedEnd = page.items.count < request.limit
        }
        failure = nil
        phase = .loaded
        return true
    }

    /// Records a failure. Returns false when the request was superseded.
    @discardableResult
    public mutating func fail(_ message: String, for request: PageRequest) -> Bool {
        guard request.generation == generation else { return false }
        failure = request.isReload ? .reload(message) : .nextPage(message)
        phase = .loaded
        return true
    }

    /// Abandons the request in flight without recording an error (the view
    /// went away or the task was cancelled).
    public mutating func cancel(_ request: PageRequest) {
        guard request.generation == generation, isBusy else { return }
        phase = (items.isEmpty && totalCount == nil) ? .idle : .loaded
    }

    /// Whether showing this row should trigger the next page: true for the
    /// last `threshold` rows. Only the tail is inspected, so the check stays
    /// cheap on lists with tens of thousands of rows.
    public func shouldLoadMore(whenShowing id: Item.ID, threshold: Int = 15) -> Bool {
        guard phase == .loaded, !reachedEnd, failure == nil, !isShowingCachedItems else { return false }
        return items.suffix(max(1, threshold)).contains { $0.id == id }
    }

    // MARK: - Local edits

    /// Removes a row locally (item deleted or un-favorited elsewhere).
    public mutating func remove(id: Item.ID) {
        guard seen.remove(id) != nil else { return }
        items.removeAll { $0.id == id }
        if let total = totalCount { totalCount = max(0, total - 1) }
        // The server list shrank by one as well, so the next page starts one
        // earlier — otherwise one row would be skipped.
        nextServerIndex = max(baseOffset, nextServerIndex - 1)
    }

    private mutating func setItems(_ newItems: [Item]) {
        items = []
        seen = []
        for item in newItems where seen.insert(item.id).inserted {
            items.append(item)
        }
    }
}
