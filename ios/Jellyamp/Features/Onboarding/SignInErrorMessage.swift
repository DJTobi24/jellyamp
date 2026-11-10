import Foundation
import JellyfinBackend

/// User-facing wording for sign-in failures. Each message says what went
/// wrong *and* what to try, because the person reading it usually runs the
/// server themselves.
enum SignInErrorMessage {
    /// `nil` for cancellation — backing out of a flow is not an error.
    static func text(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let connectionError = error as? JellyfinConnectionError {
            return text(for: connectionError)
        }
        return String(localized: "Something went wrong. Please try again.")
    }

    static func text(for error: JellyfinConnectionError) -> String {
        switch error {
        case .invalidAddress:
            return String(localized: "That doesn't look like a server address. Try something like jellyfin.example.com or 192.168.1.5:8096.")
        case .unreachable:
            return String(localized: "Can't reach a server at this address. Check the spelling and port, and that this device is on the same network or VPN as the server.")
        case .tlsFailure:
            return String(localized: "The secure connection to this server failed. Its certificate may be self-signed or expired. If the server only speaks HTTP, start the address with http://")
        case .notJellyfin:
            return String(localized: "Something answered at this address, but it isn't a Jellyfin server. Check the port (Jellyfin uses 8096 by default) and any path your reverse proxy needs.")
        case .serverTooOld(let version, let minimum):
            return String(localized: "This server runs Jellyfin \(version). Jellyamp needs Jellyfin \(minimum) or newer — please update the server.")
        case .serverNotSetUp:
            return String(localized: "This Jellyfin server hasn't finished its first-time setup. Open it in a browser and complete the setup wizard, then try again.")
        case .serverUnavailable(let status):
            return String(localized: "The server is having trouble right now (error \(status)). Try again in a moment.")
        case .wrongCredentials:
            return String(localized: "Wrong username or password.")
        case .userDisabled:
            return String(localized: "This account is disabled or temporarily locked after too many failed attempts. Ask the server's administrator to unlock it.")
        case .quickConnectDisabled:
            return String(localized: "Quick Connect is turned off on this server. Sign in with your password instead.")
        case .quickConnectExpired:
            return String(localized: "The Quick Connect code expired before it was approved.")
        case .unexpectedResponse:
            return String(localized: "The server sent an unexpected answer. Check that the address points directly at Jellyfin and try again.")
        }
    }
}
