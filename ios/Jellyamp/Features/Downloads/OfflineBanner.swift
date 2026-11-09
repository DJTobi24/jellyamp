import SwiftUI
import JellyampCore
import JellyfinBackend

/// Slim banner telling the user the app is showing downloaded music only.
/// Renders nothing while online, so it can be placed unconditionally, e.g.
/// `.safeAreaInset(edge: .top, spacing: 0) { OfflineBanner() }`.
struct OfflineBanner: View {
    @EnvironmentObject private var container: DependencyContainer

    var body: some View {
        OfflineBannerContent(status: container.offline.status)
    }

    static func message(for reason: OfflineReason) -> String {
        switch reason {
        case .userEnabled:
            return String(localized: "Offline Mode — showing downloads only")
        case .noNetwork:
            return String(localized: "No internet connection — showing downloads only")
        case .serverUnreachable:
            return String(localized: "Server unreachable — showing downloads only")
        }
    }
}

private struct OfflineBannerContent: View {
    @ObservedObject var status: OfflineStatus

    var body: some View {
        if let reason = status.reason {
            Label(OfflineBanner.message(for: reason), systemImage: "wifi.slash")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .accessibilityAddTraits(.isStaticText)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Maps the typed "can't do this offline" error of `OfflineLibrary` to a
/// message for an alert; nil for every other error.
///
///     } catch {
///         alertMessage = OfflineErrorMessage.text(for: error) ?? error.localizedDescription
///     }
enum OfflineErrorMessage {
    static func text(for error: Error) -> String? {
        guard let offline = error as? OfflineLibraryError else { return nil }
        switch offline {
        case .unavailableOffline(.changeFavorite):
            return String(localized: "You're offline. Favorites can be changed again once your server is reachable.")
        case .unavailableOffline(.editPlaylist):
            return String(localized: "You're offline. Playlists can be edited again once your server is reachable.")
        }
    }
}
