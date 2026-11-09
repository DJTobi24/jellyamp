import Foundation

/// Turns what people actually type into a server field — `jellyfin.local`,
/// `192.168.1.5:8096`, a URL copied from the browser's address bar including
/// `/web/index.html#/home.html` — into the base URLs worth probing.
public enum ServerAddress {
    /// Jellyfin's default plain-HTTP port; tried when no port was typed.
    public static let defaultHTTPPort = 8096

    /// Candidate base URLs in order of preference. With an explicit scheme
    /// there is exactly one; without, HTTPS is preferred over HTTP so
    /// credentials are not sent in clear text when the server offers TLS.
    public static func candidates(for input: String) throws -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinConnectionError.invalidAddress }

        var explicitScheme: String?
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { throw JellyfinConnectionError.invalidAddress }
            explicitScheme = scheme
            text = String(text[separator.upperBound...])
        }

        // The web client keeps its state in the fragment (`#/home.html`);
        // neither it nor a query string is part of the server's base URL.
        if let cut = text.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            text = String(text[..<cut])
        }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else {
            throw JellyfinConnectionError.invalidAddress
        }

        guard var components = URLComponents(string: "http://" + text),
              let host = components.host, !host.isEmpty else {
            throw JellyfinConnectionError.invalidAddress
        }
        components.user = nil
        components.password = nil
        if host != host.lowercased() { components.host = host.lowercased() }
        components.path = basePath(from: components.path)
        let typedPort = components.port

        func url(scheme: String, port: Int?) throws -> URL {
            var candidate = components
            candidate.scheme = scheme
            candidate.port = port
            guard let url = candidate.url else { throw JellyfinConnectionError.invalidAddress }
            return url
        }

        if let explicitScheme {
            return [try url(scheme: explicitScheme, port: typedPort)]
        }
        if let typedPort {
            return [try url(scheme: "https", port: typedPort), try url(scheme: "http", port: typedPort)]
        }
        return [
            try url(scheme: "https", port: nil),
            try url(scheme: "http", port: defaultHTTPPort),
            try url(scheme: "http", port: nil),
        ]
    }

    /// Drops trailing slashes and the web client's `/web/index.html` suffix
    /// but keeps a reverse-proxy base path such as `/jellyfin`.
    static func basePath(from path: String) -> String {
        var segments = path.split(separator: "/").map(String.init)
        if let last = segments.last, last.lowercased() == "index.html" { segments.removeLast() }
        if let last = segments.last, last.lowercased() == "web" { segments.removeLast() }
        return segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }
}
