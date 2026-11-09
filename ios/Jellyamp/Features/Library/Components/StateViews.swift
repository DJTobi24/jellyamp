import SwiftUI
import JellyampCore

// MARK: - Loading placeholders

/// Grey placeholder that gently pulses (static with Reduce Motion).
private struct SkeletonBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.12))
            .opacity(dimmed ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// Placeholder rows for a list that is loading its first page. Use inside a
/// `List` (it produces rows) — the screen keeps its final layout instead of
/// flashing a blank view or a lone spinner.
struct SkeletonRows: View {
    enum Artwork {
        case none, square, circle
    }

    var count = 10
    var artwork: Artwork = .square

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            HStack(spacing: 12) {
                if artwork != .none {
                    SkeletonBlock(cornerRadius: artwork == .circle ? 22 : 6)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 6) {
                    // Varying widths read as text rather than as a table.
                    SkeletonBlock().frame(width: index.isMultiple(of: 3) ? 180 : 140, height: 12)
                    SkeletonBlock().frame(width: index.isMultiple(of: 2) ? 90 : 120, height: 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
            .accessibilityHidden(index != 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading"))
        }
    }
}

/// Placeholder tiles for an artwork grid that is loading its first page.
struct SkeletonGrid: View {
    var count = 8
    var minimumItemWidth: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(cornerRadius: 8).aspectRatio(1, contentMode: .fit)
                    SkeletonBlock().frame(width: 110, height: 12)
                    SkeletonBlock().frame(width: 70, height: 10)
                }
            }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }
}

// MARK: - Error and empty states

/// Full-screen error with a retry button, for when there is nothing else to
/// show. (When rows are already on screen, use a banner instead.)
struct ErrorStateView: View {
    var title = String(localized: "Could Not Load")
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(minHeight: 28)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Empty state with an optional call to action.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Without a button there is nothing to tap, so touches fall through
        // to the list underneath and pull-to-refresh keeps working.
        .allowsHitTesting(action != nil)
    }
}

/// Last row of a paged list: a spinner while the next page loads, or the
/// error with a retry button when it failed. Renders nothing otherwise.
struct PagingFooter: View {
    let isLoadingMore: Bool
    let failureMessage: String?
    let retry: () -> Void

    var body: some View {
        if isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading more"))
        } else if let failureMessage {
            VStack(spacing: 8) {
                Text(failureMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: retry) {
                    Label("Load More", systemImage: "arrow.clockwise")
                        .frame(minHeight: 28)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        }
    }
}

extension PagingFooter {
    /// Footer for a `PagedLoader`.
    @MainActor
    init<Item: Identifiable & Sendable>(_ loader: PagedLoader<Item>) where Item.ID: Sendable {
        var message: String?
        if case .nextPage(let text)? = loader.state.failure { message = text }
        self.init(isLoadingMore: loader.state.isLoadingMore, failureMessage: message, retry: { loader.loadNextPage() })
    }
}

/// Overlays the blocking error / empty state of a paged list and reports a
/// failed refresh (rows still on screen) as a banner.
private struct PagedListStatus<Item: Identifiable & Sendable, Empty: View>: ViewModifier where Item.ID: Sendable {
    @ObservedObject var loader: PagedLoader<Item>
    let isActive: Bool
    let empty: Empty

    func body(content: Content) -> some View {
        content
            .overlay {
                if !isActive {
                    EmptyView()
                } else if let message = loader.state.blockingError {
                    ErrorStateView(message: message) {
                        Task { await loader.reload(keepingItems: false) }
                    }
                } else if loader.state.isEmpty {
                    empty
                }
            }
            .onChange(of: loader.state.failure) { failure in
                if isActive, case .reload(let message)? = failure, !loader.state.items.isEmpty {
                    ToastCenter.shared.show(String(localized: "Could not refresh"), detail: message, style: .error)
                }
            }
    }
}

extension View {
    /// Adds the error / empty overlays for a paged list. Pass
    /// `isActive: false` while the screen shows something other than the
    /// loader's rows (e.g. a local "downloaded only" view).
    func pagedListStatus<Item: Identifiable & Sendable, Empty: View>(
        _ loader: PagedLoader<Item>,
        isActive: Bool = true,
        @ViewBuilder empty: () -> Empty
    ) -> some View where Item.ID: Sendable {
        modifier(PagedListStatus(loader: loader, isActive: isActive, empty: empty()))
    }

    /// Caps the width on large screens so rows stay scannable, centered in
    /// the available space. No effect on phones.
    func readableContentWidth() -> some View {
        frame(maxWidth: CGFloat(AdaptiveGrid.readableContentWidth))
            .frame(maxWidth: .infinity)
    }
}
