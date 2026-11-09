import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything that can go wrong while finding a server and signing in, typed
/// so the UI can show a specific, actionable message instead of a generic
/// "sign-in failed".
public enum JellyfinConnectionError: Error, Equatable, Sendable {
    /// The typed address cannot be turned into a URL (empty, spaces,
    /// unsupported scheme such as `ftp://`).
    case invalidAddress
    /// DNS failure, connection refused, timeout, no network.
    case unreachable
    /// The host answered but the TLS handshake/certificate check failed
    /// (self-signed or expired certificate, plain-HTTP port spoken to with
    /// HTTPS).
    case tlsFailure
    /// Something answered, but it is not a Jellyfin server (wrong port, a
    /// router login page, Emby, a proxy error page).
    case notJellyfin
    /// A Jellyfin server older than `JellyfinServerVersion.minimumSupported`.
    case serverTooOld(version: String, minimum: String)
    /// Jellyfin is installed but its first-run wizard has not been completed,
    /// so there are no users to sign in as yet.
    case serverNotSetUp
    /// The server (or a reverse proxy in front of it) answered 5xx.
    case serverUnavailable(status: Int)
    /// Jellyfin answers 401 for an unknown user and for a wrong password
    /// alike (deliberately indistinguishable).
    case wrongCredentials
    /// Jellyfin answers 403 when the account is disabled, locked out after
    /// too many failed attempts, or outside its allowed access schedule.
    case userDisabled
    /// Quick Connect is switched off in the server's settings.
    case quickConnectDisabled
    /// The Quick Connect code was not approved in time, or the server no
    /// longer knows it (codes are short-lived and die with a server restart).
    case quickConnectExpired
    /// An answer we could not make sense of.
    case unexpectedResponse

    /// Maps whatever an `HTTPTransport` threw to a typed error. Cancellation
    /// stays cancellation so callers can tell "user backed out" from failure.
    public static func mapping(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let already = error as? JellyfinConnectionError { return already }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return JellyfinConnectionError.tlsFailure
            default:
                return JellyfinConnectionError.unreachable
            }
        }
        return JellyfinConnectionError.unreachable
    }

    /// Network-level failures worth retrying silently (used while polling).
    var isTransient: Bool {
        switch self {
        case .unreachable, .serverUnavailable:
            return true
        default:
            return false
        }
    }
}
