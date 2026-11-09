import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A completed sign-in: the authenticated session plus what the server told
/// us about the user (shown in Settings → Account).
public struct JellyfinSignInResult: Equatable, Sendable {
    public var session: JellyfinSession
    public var userName: String

    public init(session: JellyfinSession, userName: String) {
        self.session = session
        self.userName = userName
    }
}

/// Outcome of checking a stored token against the server.
public enum JellyfinSessionValidity: Equatable, Sendable {
    /// The server accepted the token.
    case valid(userName: String?)
    /// The server answered 401: the token was revoked, the device was removed
    /// in the dashboard, or the user was deleted. Signing in again is the
    /// only way forward.
    case rejected
    /// No verdict (offline, server down, proxy error). The stored session
    /// must be kept so downloaded music stays playable.
    case indeterminate
}

/// Authentication flows (`/Users/AuthenticateByName`, Quick Connect) and the
/// token's lifecycle (validation, logout).
public struct JellyfinAuthenticator: Sendable {
    private let transport: HTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Sign-in requests fail faster than the 60 s URLSession default: the
    /// server was reachable a moment ago, so a long hang means "gone".
    static let requestTimeout: TimeInterval = 20

    /// - Parameter sleep: injected so Quick Connect polling is testable
    ///   without real waiting.
    public init(
        transport: HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.sleep = sleep
    }

    struct AuthenticationResult: Codable {
        struct User: Codable {
            var Id: String
            var Name: String
        }
        var AccessToken: String
        var User: User
    }

    // MARK: - Password

    /// Password login with typed errors (`JellyfinConnectionError`).
    public func signIn(session: JellyfinSession, username: String, password: String) async throws -> JellyfinSignInResult {
        struct Body: Codable {
            var Username: String
            var Pw: String
        }
        let body = try JSONEncoder().encode(Body(Username: username, Pw: password))
        let (data, response) = try await send(session.request(path: "Users/AuthenticateByName", method: "POST", body: body))
        switch response.statusCode {
        case 200:
            return try signInResult(from: data, session: session)
        case 401:
            throw JellyfinConnectionError.wrongCredentials
        case 403:
            throw JellyfinConnectionError.userDisabled
        case 500...599:
            throw JellyfinConnectionError.serverUnavailable(status: response.statusCode)
        default:
            throw JellyfinConnectionError.unexpectedResponse
        }
    }

    /// Password login. Returns the session updated with token + user ID.
    /// Kept for existing callers; new code should prefer `signIn`, whose
    /// errors say *why* it failed.
    public func authenticateByName(session: JellyfinSession, username: String, password: String) async throws -> JellyfinSession {
        do {
            return try await signIn(session: session, username: username, password: password).session
        } catch let error as JellyfinConnectionError {
            switch error {
            case .wrongCredentials, .userDisabled:
                throw JellyfinError.unauthorized
            case .serverUnavailable(let status):
                throw JellyfinError.serverError(status: status)
            default:
                throw JellyfinError.invalidResponse
            }
        }
    }

    // MARK: - Quick Connect

    public struct QuickConnectState: Equatable, Sendable {
        public var secret: String
        /// Code the user enters in another signed-in Jellyfin client.
        public var code: String

        public init(secret: String, code: String) {
            self.secret = secret
            self.code = code
        }
    }

    /// Whether the server offers Quick Connect at all (admins can switch it
    /// off). Any failure counts as "no" — the password form always works.
    public func isQuickConnectEnabled(session: JellyfinSession) async -> Bool {
        guard let (data, response) = try? await send(session.request(path: "QuickConnect/Enabled")),
              response.statusCode == 200 else {
            return false
        }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    public func initiateQuickConnect(session: JellyfinSession) async throws -> QuickConnectState {
        struct Response: Codable {
            var Secret: String
            var Code: String
        }
        let (data, response) = try await send(session.request(path: "QuickConnect/Initiate", method: "POST"))
        switch response.statusCode {
        case 200:
            guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
                throw JellyfinConnectionError.unexpectedResponse
            }
            return QuickConnectState(secret: result.Secret, code: result.Code)
        case 401, 403:
            // Jellyfin answers 401 "Quick connect is not active on this server".
            throw JellyfinConnectionError.quickConnectDisabled
        case 500...599:
            throw JellyfinConnectionError.serverUnavailable(status: response.statusCode)
        default:
            throw JellyfinConnectionError.unexpectedResponse
        }
    }

    /// One poll. True once the code was approved in another client; then call
    /// `signInWithQuickConnect`.
    public func isQuickConnectApproved(session: JellyfinSession, state: QuickConnectState) async throws -> Bool {
        struct Response: Codable {
            var Authenticated: Bool
        }
        let request = session.request(path: "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: state.secret)])
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
                throw JellyfinConnectionError.unexpectedResponse
            }
            return result.Authenticated
        case 404:
            // "Unknown secret": the code expired or the server restarted.
            throw JellyfinConnectionError.quickConnectExpired
        case 401, 403:
            throw JellyfinConnectionError.quickConnectDisabled
        case 500...599:
            throw JellyfinConnectionError.serverUnavailable(status: response.statusCode)
        default:
            throw JellyfinConnectionError.unexpectedResponse
        }
    }

    /// Polls until the code is approved. Throws `quickConnectExpired` after
    /// `timeout`, `CancellationError` when the surrounding task is cancelled
    /// (the user backed out). Brief network hiccups are ridden out — the user
    /// is typically switching apps or devices to approve the code.
    public func waitForQuickConnectApproval(
        session: JellyfinSession,
        state: QuickConnectState,
        pollInterval: TimeInterval = 2,
        timeout: TimeInterval = 300
    ) async throws {
        var waited: TimeInterval = 0
        while true {
            try Task.checkCancellation()
            do {
                if try await isQuickConnectApproved(session: session, state: state) { return }
            } catch let error as JellyfinConnectionError where error.isTransient {
                // Keep polling until the timeout.
            }
            guard waited < timeout else { throw JellyfinConnectionError.quickConnectExpired }
            try await sleep(pollInterval)
            waited += pollInterval
        }
    }

    /// Exchanges an approved Quick Connect secret for a token.
    public func signInWithQuickConnect(session: JellyfinSession, state: QuickConnectState) async throws -> JellyfinSignInResult {
        struct Body: Codable {
            var Secret: String
        }
        let body = try JSONEncoder().encode(Body(Secret: state.secret))
        let (data, response) = try await send(session.request(path: "Users/AuthenticateWithQuickConnect", method: "POST", body: body))
        switch response.statusCode {
        case 200:
            return try signInResult(from: data, session: session)
        case 401, 404:
            // Not approved (any more) / unknown secret.
            throw JellyfinConnectionError.quickConnectExpired
        case 403:
            throw JellyfinConnectionError.userDisabled
        case 500...599:
            throw JellyfinConnectionError.serverUnavailable(status: response.statusCode)
        default:
            throw JellyfinConnectionError.unexpectedResponse
        }
    }

    public func authenticateWithQuickConnect(session: JellyfinSession, state: QuickConnectState) async throws -> JellyfinSession {
        try await signInWithQuickConnect(session: session, state: state).session
    }

    // MARK: - Token lifecycle

    /// Checks a stored token with `GET /Users/Me`. Only an explicit 401 is a
    /// rejection; everything else (offline, 5xx, a captive portal's HTML) is
    /// `indeterminate` so a flaky network never signs anyone out.
    public func validate(session: JellyfinSession) async -> JellyfinSessionValidity {
        guard session.isAuthenticated else { return .rejected }
        struct User: Codable {
            var Name: String?
        }
        guard let (data, response) = try? await send(session.request(path: "Users/Me")) else {
            return .indeterminate
        }
        switch response.statusCode {
        case 200:
            // A captive portal can answer 200 with HTML; that is no verdict.
            guard let user = try? JSONDecoder().decode(User.self, from: data) else { return .indeterminate }
            return .valid(userName: user.Name)
        case 401:
            return .rejected
        default:
            return .indeterminate
        }
    }

    /// Revokes the token server-side (`POST /Sessions/Logout`) so the device
    /// disappears from the dashboard. Best effort: signing out locally must
    /// work offline too, so failures are ignored.
    public func logout(session: JellyfinSession) async {
        guard session.isAuthenticated else { return }
        var request = session.request(path: "Sessions/Logout", method: "POST")
        request.timeoutInterval = 10
        _ = try? await transport.send(request)
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = Self.requestTimeout
        do {
            return try await transport.send(request)
        } catch {
            throw JellyfinConnectionError.mapping(error)
        }
    }

    private func signInResult(from data: Data, session: JellyfinSession) throws -> JellyfinSignInResult {
        guard let result = try? JSONDecoder().decode(AuthenticationResult.self, from: data) else {
            throw JellyfinConnectionError.unexpectedResponse
        }
        var authenticated = session
        authenticated.accessToken = result.AccessToken
        authenticated.userID = result.User.Id
        return JellyfinSignInResult(session: authenticated, userName: result.User.Name)
    }
}
