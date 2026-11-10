import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Probes a configured jellyamp-server and reports whether the app should
/// use it. Called at launch and when the user edits the sonic server settings.
public struct SonicServerDiscovery: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Server reachable, authorized, contract version compatible. The
        /// capability set may be empty while the first analysis is running —
        /// `analysisProgress` and `scan` then tell the user why.
        case available(SonicCapabilities)
        case unauthorized
        case incompatibleVersion(String)
        case unreachable
    }

    /// The contract major version this client implements (docs/SONIC-API.md).
    public static let supportedMajorVersion = "1"

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func probe(baseURL: URL, apiKey: String) async -> Outcome {
        switch await probeInfo(baseURL: baseURL, apiKey: apiKey) {
        case .success(let info):
            return .available(info.capabilities)
        case .failure(let outcome):
            return outcome
        }
    }

    /// Like `probe`, but also returns the server's version and the ID of the
    /// Jellyfin server it analyzes, so the app can warn when the sonic server
    /// belongs to a different Jellyfin than the one signed in to.
    public func probeDetails(baseURL: URL, apiKey: String) async -> (outcome: Outcome, info: SonicServerInfo?) {
        switch await probeInfo(baseURL: baseURL, apiKey: apiKey) {
        case .success(let info):
            return (.available(info.capabilities), info)
        case .failure(let outcome):
            return (outcome, nil)
        }
    }

    private enum ProbeResult {
        case success(SonicServerInfo)
        case failure(Outcome)
    }

    private func probeInfo(baseURL: URL, apiKey: String) async -> ProbeResult {
        let client = SonicAPIClient(baseURL: baseURL, apiKey: apiKey, transport: transport)
        do {
            let info = try await client.serverInfo()
            // Minor versions are additive; only the major must match.
            guard info.version.split(separator: ".").first.map(String.init) == Self.supportedMajorVersion else {
                return .failure(.incompatibleVersion(info.version))
            }
            return .success(info)
        } catch SonicError.unauthorized {
            return .failure(.unauthorized)
        } catch {
            return .failure(.unreachable)
        }
    }
}
