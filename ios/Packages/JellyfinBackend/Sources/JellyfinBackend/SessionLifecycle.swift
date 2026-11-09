import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What Settings → Account shows about the signed-in session. Persisted next
/// to the token; every field is optional so sessions stored by older app
/// versions (which only kept URL, device ID, token and user ID) still decode.
public struct JellyfinAccount: Codable, Equatable, Sendable {
    public var serverName: String?
    public var serverVersion: String?
    public var userName: String?

    public init(serverName: String? = nil, serverVersion: String? = nil, userName: String? = nil) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.userName = userName
    }
}

/// The single place where "the server no longer accepts our token" is
/// detected for regular API traffic. Wrap the transport handed to the API
/// clients (`MusicLibraryAPI`, `InstantMixAPI`, …) in this; it passes every
/// response through untouched and calls `onUnauthorized` when an
/// authenticated request comes back 401.
///
/// The callback is a hint, not a verdict — a misbehaving proxy can produce a
/// stray 401. The owner should confirm with
/// `JellyfinAuthenticator.validate(session:)` before signing the user out.
public struct UnauthorizedReportingTransport: HTTPTransport {
    private let base: HTTPTransport
    private let onUnauthorized: @Sendable () -> Void

    public init(base: HTTPTransport = URLSessionTransport(), onUnauthorized: @escaping @Sendable () -> Void) {
        self.base = base
        self.onUnauthorized = onUnauthorized
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        if response.statusCode == 401, Self.carriesToken(request) {
            onUnauthorized()
        }
        return (data, response)
    }

    /// Unauthenticated calls (sign-in with a wrong password, Quick Connect)
    /// answer 401 too; those say nothing about a stored token.
    static func carriesToken(_ request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"") ?? false
    }
}
