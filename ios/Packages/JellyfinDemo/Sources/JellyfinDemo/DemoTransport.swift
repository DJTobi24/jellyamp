import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers `URLRequest`s straight from a `DemoBackend`, without a socket.
/// For tests and previews of code that takes an `HTTPTransport`; the app
/// itself goes through `DemoHTTPServer`, because images, streams and
/// downloads are fetched by URL outside any transport.
public struct DemoTransport: HTTPTransport {
    private let backend: DemoBackend

    public init(backend: DemoBackend) {
        self.backend = backend
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let demoRequest = Self.demoRequest(from: request) else {
            throw URLError(.badURL)
        }
        let response = backend.respond(to: demoRequest)
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            throw HTTPTransportError.notHTTP
        }
        return (demoRequest.method == "HEAD" ? Data() : response.body, http)
    }

    static func demoRequest(from request: URLRequest) -> DemoHTTPRequest? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        return DemoHTTPRequest(method: request.httpMethod ?? "GET", target: target, headers: headers, body: request.httpBody ?? Data())
    }
}
