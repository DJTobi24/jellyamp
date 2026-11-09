import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `major.minor.patch` of a Jellyfin server, comparable.
public struct JellyfinServerVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    /// Oldest server the app works with. The lyrics endpoint
    /// (`/Audio/{id}/Lyrics`) and the POST form of `/QuickConnect/Initiate`
    /// both arrived in 10.9; everything else the app calls is older.
    public static let minimumSupported = JellyfinServerVersion(major: 10, minor: 9, patch: 0)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `10.10.7`, `10.9` and pre-release strings like `10.11.0-rc2`.
    public init?(_ string: String) {
        let numbers = string.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isASCII && $0.isNumber }))
        }
        guard numbers.count >= 2, let major = numbers[0], let minor = numbers[1] else { return nil }
        self.major = major
        self.minor = minor
        self.patch = numbers.count > 2 ? (numbers[2] ?? 0) : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: JellyfinServerVersion, rhs: JellyfinServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A server that answered the public-info probe and is usable by the app.
public struct JellyfinServerInfo: Equatable, Sendable {
    /// Base URL to build API requests on (scheme resolved, redirects followed).
    public var url: URL
    public var name: String
    public var version: String
    public var id: String

    public init(url: URL, name: String, version: String, id: String) {
        self.url = url
        self.name = name
        self.version = version
        self.id = id
    }
}

/// Finds the Jellyfin server behind a user-typed address via the
/// unauthenticated `GET /System/Info/Public`.
public struct JellyfinServerDiscovery: Sendable {
    private let transport: HTTPTransport
    private let timeout: TimeInterval

    /// - Parameter timeout: per-candidate request timeout. Short, because a
    ///   mistyped LAN address should fail while the user is still looking.
    public init(transport: HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 8) {
        self.transport = transport
        self.timeout = timeout
    }

    private enum Outcome: Sendable {
        case found(JellyfinServerInfo)
        case failed(JellyfinConnectionError)
        case cancelled
    }

    /// Normalizes `address` and probes its candidates concurrently. The
    /// preferred candidate (HTTPS first) wins even if a later one answers
    /// sooner; a later one is only accepted once every earlier one failed.
    public func discover(address: String) async throws -> JellyfinServerInfo {
        let candidates = try ServerAddress.candidates(for: address)

        let outcomes: [Outcome?] = await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    do {
                        return (index, .found(try await self.probe(url: url)))
                    } catch let error as JellyfinConnectionError {
                        return (index, .failed(error))
                    } catch {
                        return (index, .cancelled)
                    }
                }
            }
            var outcomes = [Outcome?](repeating: nil, count: candidates.count)
            for await (index, outcome) in group {
                outcomes[index] = outcome
                if Self.winner(in: outcomes) != nil {
                    group.cancelAll()
                    break
                }
            }
            return outcomes
        }

        if let winner = Self.winner(in: outcomes) { return winner }
        try Task.checkCancellation()
        var failures: [JellyfinConnectionError] = []
        for outcome in outcomes {
            if case .failed(let error)? = outcome { failures.append(error) }
        }
        throw Self.mostInformative(failures) ?? JellyfinConnectionError.unreachable
    }

    /// The first success that is not preceded by a still-pending candidate.
    private static func winner(in outcomes: [Outcome?]) -> JellyfinServerInfo? {
        for outcome in outcomes {
            guard let outcome else { return nil }
            if case .found(let info) = outcome { return info }
        }
        return nil
    }

    /// Probes exactly one base URL.
    public func probe(url: URL) async throws -> JellyfinServerInfo {
        var request = URLRequest(url: url.appendingPathComponent("System/Info/Public"))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw JellyfinConnectionError.mapping(error)
        }

        switch response.statusCode {
        case 200:
            break
        case 500...599:
            throw JellyfinConnectionError.serverUnavailable(status: response.statusCode)
        default:
            throw JellyfinConnectionError.notJellyfin
        }

        struct PublicSystemInfo: Decodable {
            var ServerName: String?
            var Version: String?
            var ProductName: String?
            var Id: String?
            var StartupWizardCompleted: Bool?
        }
        // Emby answers the same path with the same shape but no ProductName;
        // its API has diverged too far to treat it as a Jellyfin server.
        guard let info = try? JSONDecoder().decode(PublicSystemInfo.self, from: data),
              let version = info.Version, let id = info.Id,
              let product = info.ProductName, product.lowercased().contains("jellyfin") else {
            throw JellyfinConnectionError.notJellyfin
        }
        if let parsed = JellyfinServerVersion(version), parsed < .minimumSupported {
            let minimum = JellyfinServerVersion.minimumSupported
            throw JellyfinConnectionError.serverTooOld(version: version, minimum: "\(minimum.major).\(minimum.minor)")
        }
        if info.StartupWizardCompleted == false {
            throw JellyfinConnectionError.serverNotSetUp
        }

        let name = info.ServerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return JellyfinServerInfo(
            url: Self.baseURL(afterRedirectTo: response.url, requested: url),
            name: name.isEmpty ? (url.host ?? "Jellyfin") : name,
            version: version,
            id: id
        )
    }

    /// A reverse proxy commonly redirects `http://` to `https://`. GETs
    /// follow that silently, but a redirected POST loses its body, so later
    /// sign-in requests must go straight to where the probe ended up.
    static func baseURL(afterRedirectTo final: URL?, requested: URL) -> URL {
        let suffix = "/System/Info/Public"
        guard let final, var components = URLComponents(url: final, resolvingAgainstBaseURL: false),
              components.path.lowercased().hasSuffix(suffix.lowercased()) else {
            return requested
        }
        components.path = ServerAddress.basePath(from: String(components.path.dropLast(suffix.count)))
        components.query = nil
        components.fragment = nil
        return components.url ?? requested
    }

    /// When every candidate failed, report the failure that tells the user
    /// most: "that Jellyfin is too old" beats "something else answered" beats
    /// "certificate problem" beats "nothing there".
    static func mostInformative(_ failures: [JellyfinConnectionError]) -> JellyfinConnectionError? {
        func rank(_ error: JellyfinConnectionError) -> Int {
            switch error {
            case .serverTooOld, .serverNotSetUp: return 5
            case .serverUnavailable: return 4
            case .notJellyfin: return 3
            case .tlsFailure: return 2
            default: return 1
            }
        }
        var best: JellyfinConnectionError?
        for failure in failures {
            if let current = best, rank(failure) <= rank(current) { continue }
            best = failure
        }
        return best
    }
}
