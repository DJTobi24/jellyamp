import Foundation

/// Parsing/validation for the optional jellyamp-server settings form.
public enum SonicServerConfig {
    public enum URLInput: Equatable, Sendable {
        /// Field left empty: the companion server is not configured.
        case empty
        case valid(URL)
        case invalid
    }

    /// Accepts what people actually type: `server:8095`, `192.168.1.5:8095/`,
    /// `https://sonic.example.com`. A missing scheme defaults to http (LAN
    /// servers rarely have TLS); trailing slashes and a pasted `/api/v1`
    /// suffix are removed because the client appends the API path itself.
    public static func parseURL(_ input: String) -> URLInput {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard !text.contains(" ") else { return .invalid }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return .invalid
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api/v1") { path.removeLast("/api/v1".count) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { return .invalid }
        return .valid(url)
    }

    /// The `GET /api/v1/info` URL for a configured base URL.
    public static func infoURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api/v1/info")
    }

    /// Server implementation version from an `/api/v1/info` body, for display.
    public static func version(fromInfoBody data: Data) -> String? {
        struct Info: Decodable { var version: String? }
        guard let version = (try? JSONDecoder().decode(Info.self, from: data))?.version,
              !version.isEmpty else { return nil }
        return version
    }
}

/// Library analysis progress as shown in the Sonic settings.
public struct AnalysisProgressSummary: Equatable, Sendable {
    public let tracksAnalyzed: Int
    public let tracksTotal: Int

    public init(tracksAnalyzed: Int, tracksTotal: Int) {
        self.tracksAnalyzed = max(tracksAnalyzed, 0)
        self.tracksTotal = max(tracksTotal, 0)
    }

    /// 0…1; an empty library counts as nothing to do, not as "0 % done".
    public var fraction: Double {
        guard tracksTotal > 0 else { return 1 }
        return min(Double(tracksAnalyzed) / Double(tracksTotal), 1)
    }

    public var isComplete: Bool { tracksAnalyzed >= tracksTotal }

    /// Whole percent, rounded down so "100 %" only shows when really done.
    public var percent: Int {
        isComplete ? 100 : min(Int(fraction * 100), 99)
    }
}
