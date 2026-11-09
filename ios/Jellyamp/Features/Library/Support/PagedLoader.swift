import SwiftUI
import JellyampCore

/// Drives one infinitely scrolling list: owns the `PagedListState`, runs the
/// requests it hands out and cancels the one in flight when a newer query
/// supersedes it. Views hold it as a `@StateObject`.
@MainActor
final class PagedLoader<Item: Identifiable & Sendable>: ObservableObject where Item.ID: Sendable {
    typealias Fetch = (_ startIndex: Int, _ limit: Int) async throws -> Page<Item>

    @Published private(set) var state: PagedListState<Item>

    private var fetch: Fetch?
    private var queryKey: AnyHashable?
    private var task: Task<Void, Never>?
    private var onFirstPage: (([Item]) -> Void)?

    init(pageSize: Int = 100) {
        state = PagedListState(pageSize: pageSize)
    }

    var items: [Item] { state.items }

    /// Points the loader at a query. Loads when the query (`key`) differs
    /// from the current one; calling it again with the same key — e.g. when
    /// the screen reappears — does nothing, so scroll position and loaded
    /// pages survive navigation.
    ///
    /// - Parameters:
    ///   - cached: rows to paint before the server answers (first use only).
    ///   - onFirstPage: called with the first page of a fresh load, to
    ///     refresh the on-disk cache.
    func configure(
        key: AnyHashable,
        cached: [Item]? = nil,
        onFirstPage: (([Item]) -> Void)? = nil,
        fetch: @escaping Fetch
    ) async {
        let isFirstUse = queryKey == nil
        guard queryKey != key else { return }
        queryKey = key
        self.fetch = fetch
        self.onFirstPage = onFirstPage
        if isFirstUse, let cached {
            state.seed(cached)
        }
        // A changed query makes the old rows wrong, so they are cleared; on
        // first use the cached rows stay until the answer replaces them.
        await reload(keepingItems: isFirstUse)
    }

    /// Reloads from the top (pull to refresh), keeping the rows on screen
    /// until the answer arrives.
    func refresh() async {
        await reload(fromOffset: state.baseOffset, keepingItems: true)
    }

    /// Restarts the list at a server offset (A–Z jump; 0 returns to the top).
    func jump(toOffset offset: Int) async {
        await reload(fromOffset: offset, keepingItems: false)
    }

    func reload(fromOffset offset: Int = 0, keepingItems: Bool = true) async {
        guard let fetch else { return }
        task?.cancel()
        let request = state.beginReload(fromOffset: offset, keepingItems: keepingItems)
        // Unstructured on purpose: `.refreshable` and `.task` cancel their
        // own task when the view updates, which must not abort the request.
        let work = Task { await self.run(request, fetch: fetch) }
        task = work
        await work.value
    }

    /// Call from a row's `onAppear`; loads the next page near the end.
    func loadMoreIfNeeded(showing item: Item) {
        guard state.shouldLoadMore(whenShowing: item.id) else { return }
        loadNextPage()
    }

    /// Explicit "load more" / retry after a failed page.
    func loadNextPage() {
        guard let fetch, let request = state.beginNextPage() else { return }
        task = Task { await self.run(request, fetch: fetch) }
    }

    func remove(id: Item.ID) {
        state.remove(id: id)
    }

    private func run(_ request: PageRequest, fetch: Fetch) async {
        do {
            let page = try await fetch(request.startIndex, request.limit)
            if Task.isCancelled {
                state.cancel(request)
                return
            }
            if state.receive(page, for: request), request.isReload, request.startIndex == 0 {
                onFirstPage?(page.items)
            }
        } catch {
            if LibraryErrorText.isCancellation(error) || Task.isCancelled {
                state.cancel(request)
            } else {
                state.fail(LibraryErrorText.message(for: error), for: request)
            }
        }
    }
}
