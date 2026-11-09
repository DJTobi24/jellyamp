import SwiftUI
import UIKit

/// A short, non-blocking message ("Added to Road Trip", "Could not load
/// albums"). Reusable from any screen:
///
///     ToastCenter.shared.show("Download failed", detail: "You appear to be offline.", style: .error)
///
/// The banner is drawn by `.toastHost()`, which the app shell applies once
/// at the root; sheets and covers that should show banners apply it too.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case info, success, error
    }

    let id = UUID()
    var message: String
    var detail: String?
    var style: Style
    /// Optional action, e.g. "Retry" or "Undo".
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    /// Shows a banner, replacing the one on screen. It disappears on its own
    /// (later when VoiceOver is running or an action is offered) and is
    /// announced to VoiceOver, so it never needs to be found by touch.
    func show(
        _ message: String,
        detail: String? = nil,
        style: Toast.Style = .info,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        let toast = Toast(message: message, detail: detail, style: style, actionTitle: actionTitle, action: action)
        current = toast
        let spoken = detail.map { "\(message) \($0)" } ?? message
        UIAccessibility.post(notification: .announcement, argument: spoken)

        var seconds: UInt64 = style == .error ? 5 : 3
        if actionTitle != nil { seconds += 3 }
        if UIAccessibility.isVoiceOverRunning { seconds += 6 }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// Convenience for the common "an operation failed" case.
    func showError(_ message: String, error: Error) {
        guard !LibraryErrorText.isCancellation(error) else { return }
        show(message, detail: LibraryErrorText.message(for: error), style: .error)
    }

    func dismiss(_ id: UUID? = nil) {
        guard id == nil || current?.id == id else { return }
        current = nil
    }
}

extension View {
    /// Draws `ToastCenter.shared`'s banner over this view, below the top
    /// safe area. Apply once per presentation (root, sheet, cover).
    func toastHost() -> some View {
        modifier(ToastHostModifier())
    }
}

private struct ToastHostModifier: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = center.current {
                    ToastBannerView(toast: toast) { center.dismiss(toast.id) }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85), value: center.current)
    }
}

private struct ToastBannerView: View {
    let toast: Toast
    let dismiss: () -> Void

    private var iconName: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.style {
        case .info: return .white
        case .success: return .green
        case .error: return .yellow
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        // An opaque dark surface keeps the text readable over any artwork.
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: Text("Dismiss"), dismiss)
    }
}
