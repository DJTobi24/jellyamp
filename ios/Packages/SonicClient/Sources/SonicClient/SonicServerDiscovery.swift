import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Probes a configured jellyamp-server and reports whether the app should
/// use it. Called at launch and when the user edits the sonic server settings.
public struct SonicServerDiscovery: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Server reachable, authorized, contract version compatible.
        case available(SonicCapabilities)
        case unauthorized
        case incompatibleVersion(String)
        case unreachable
    }

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func probe(baseURL: URL, apiKey: String) async -> Outcome {
        let client = SonicAPIClient(baseURL: baseURL, apiKey: apiKey, transport: transport)
        do {
            let info = try await client.fetchInfo()
            guard info.version.split(separator: ".").first == "1" else {
                return .incompatibleVersion(info.version)
            }
            return .available(
                SonicCapabilities(
                    capabilities: Set(info.capabilities.compactMap(SonicCapability.init(rawValue:))),
                    analysisProgress: .init(tracksAnalyzed: info.tracksAnalyzed, tracksTotal: info.tracksTotal)
                )
            )
        } catch SonicError.unauthorized {
            return .unauthorized
        } catch {
            return .unreachable
        }
    }
}
