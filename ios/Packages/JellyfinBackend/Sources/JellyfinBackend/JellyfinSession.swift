import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connection state for one Jellyfin server: base URL, device identity, and
/// (after auth) the access token + user. Builds the `Authorization:
/// MediaBrowser …` header Jellyfin expects on every call.
public struct JellyfinSession: Equatable, Sendable {
    public var serverURL: URL
    public var deviceID: String
    public var deviceName: String
    public var clientName: String
    public var clientVersion: String
    public var accessToken: String?
    public var userID: String?

    public init(
        serverURL: URL,
        deviceID: String,
        deviceName: String = "iPhone",
        clientName: String = "Jellyamp",
        clientVersion: String = "0.1.0",
        accessToken: String? = nil,
        userID: String? = nil
    ) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.accessToken = accessToken
        self.userID = userID
    }

    public var isAuthenticated: Bool { accessToken != nil && userID != nil }

    public var authorizationHeader: String {
        var parts = [
            "MediaBrowser Client=\"\(clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(clientVersion)\"",
        ]
        if let token = accessToken {
            parts.append("Token=\"\(token)\"")
        }
        return parts.joined(separator: ", ")
    }

    public func request(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

public enum JellyfinError: Error, Equatable {
    case unauthorized
    case notFound
    case serverError(status: Int)
    case invalidResponse
    case notAuthenticated
}

/// Authentication flows (`/Users/AuthenticateByName`, Quick Connect).
public struct JellyfinAuthenticator: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    struct AuthenticationResult: Codable {
        struct User: Codable {
            var Id: String
            var Name: String
        }
        var AccessToken: String
        var User: User
    }

    /// Password login. Returns the session updated with token + user ID.
    public func authenticateByName(session: JellyfinSession, username: String, password: String) async throws -> JellyfinSession {
        struct Body: Codable {
            var Username: String
            var Pw: String
        }
        let body = try JSONEncoder().encode(Body(Username: username, Pw: password))
        let request = session.request(path: "Users/AuthenticateByName", method: "POST", body: body)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200:
            guard let result = try? JSONDecoder().decode(AuthenticationResult.self, from: data) else {
                throw JellyfinError.invalidResponse
            }
            var authenticated = session
            authenticated.accessToken = result.AccessToken
            authenticated.userID = result.User.Id
            return authenticated
        case 401, 403:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.serverError(status: response.statusCode)
        }
    }

    // MARK: - Quick Connect

    public struct QuickConnectState: Equatable, Sendable {
        public var secret: String
        /// Code the user enters in another signed-in Jellyfin client.
        public var code: String
    }

    public func initiateQuickConnect(session: JellyfinSession) async throws -> QuickConnectState {
        struct Response: Codable {
            var Secret: String
            var Code: String
        }
        let request = session.request(path: "QuickConnect/Initiate", method: "POST")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw JellyfinError.invalidResponse
        }
        return QuickConnectState(secret: result.Secret, code: result.Code)
    }

    /// Poll until this returns true, then call `authenticateWithQuickConnect`.
    public func isQuickConnectApproved(session: JellyfinSession, state: QuickConnectState) async throws -> Bool {
        struct Response: Codable {
            var Authenticated: Bool
        }
        let request = session.request(path: "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: state.secret)])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw JellyfinError.invalidResponse
        }
        return result.Authenticated
    }

    public func authenticateWithQuickConnect(session: JellyfinSession, state: QuickConnectState) async throws -> JellyfinSession {
        struct Body: Codable {
            var Secret: String
        }
        let body = try JSONEncoder().encode(Body(Secret: state.secret))
        let request = session.request(path: "Users/AuthenticateWithQuickConnect", method: "POST", body: body)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, let result = try? JSONDecoder().decode(AuthenticationResult.self, from: data) else {
            throw JellyfinError.invalidResponse
        }
        var authenticated = session
        authenticated.accessToken = result.AccessToken
        authenticated.userID = result.User.Id
        return authenticated
    }
}
