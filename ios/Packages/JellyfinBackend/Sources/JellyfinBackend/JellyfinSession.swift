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
