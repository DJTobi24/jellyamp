import SwiftUI

/// Liquid-Glass adoption helpers (iOS 26 design language).
///
/// The app deploys back to iOS 16, so every new-design API is gated behind
/// `#available(iOS 26, *)` with the pre-26 material look as fallback. System
/// chrome (tab bar, navigation bars, sheets) picks up Liquid Glass
/// automatically once the app is built with the iOS 26 SDK — only our custom
/// surfaces need these helpers.
extension View {
    /// Floating panel surface (mini player, overlays): Liquid Glass on
    /// iOS 26, ultra-thin material before.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Capsule glass surface for control clusters (transport controls).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Glass button chrome where the platform supports it.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain)
        }
    }

    /// iOS 26 tab bar that minimizes while scrolling content.
    @ViewBuilder
    func tabBarMinimizesOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
