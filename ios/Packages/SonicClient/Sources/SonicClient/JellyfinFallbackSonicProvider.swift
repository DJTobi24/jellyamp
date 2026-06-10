import Foundation
import JellyampCore

/// The Jellyfin endpoints the fallback needs. Implemented by
/// `JellyfinBackend.InstantMixAPI` in the app; faked in tests.
public protocol JellyfinSmartSource: Sendable {
    /// `/Items/{id}/InstantMix` — metadata-based mix, any seed kind.
    func instantMix(seedID: String, limit: Int) async throws -> [String]
    /// `/Items/{id}/Similar` — similar artists/albums by metadata.
    func similarItems(to itemID: String, limit: Int) async throws -> [String]
    /// `/Items?genres=…` or `?years=…` with random sort.
    func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String]
}

/// `SonicProviding` backed only by a plain Jellyfin server: Instant Mix and
/// metadata similarity. Adventure, mixes-for-you and measured loudness are
/// not available — UI hides them via `capabilities`.
public struct JellyfinFallbackSonicProvider: SonicProviding {
    private let source: JellyfinSmartSource

    public init(source: JellyfinSmartSource) {
        self.source = source
    }

    public var capabilities: SonicCapabilities {
        SonicCapabilities(capabilities: [.similar, .stations])
    }

    public func similarTracks(to itemID: String, limit: Int) async throws -> [SimilarItem] {
        // Instant Mix is Jellyfin's closest notion of track similarity; it has
        // no distance metric, so rank order stands in for distance.
        let ids = try await source.instantMix(seedID: itemID, limit: limit + 1)
        return rankedItems(ids: ids, excluding: itemID, limit: limit)
    }

    public func similarArtists(to artistID: String, limit: Int) async throws -> [SimilarItem] {
        let ids = try await source.similarItems(to: artistID, limit: limit)
        return rankedItems(ids: ids, excluding: artistID, limit: limit)
    }

    public func similarAlbums(to albumID: String, limit: Int) async throws -> [SimilarItem] {
        let ids = try await source.similarItems(to: albumID, limit: limit)
        return rankedItems(ids: ids, excluding: albumID, limit: limit)
    }

    private func rankedItems(ids: [String], excluding seedID: String, limit: Int) -> [SimilarItem] {
        ids.filter { $0 != seedID }
            .prefix(limit)
            .enumerated()
            .map { SimilarItem(itemID: $0.element, distance: Double($0.offset)) }
    }

    public func adventure(from: String, to: String, steps: Int) async throws -> [String] {
        throw SonicError.unsupported(.adventure)
    }

    public func mixes(forUser userID: String) async throws -> [MixDescriptor] {
        throw SonicError.unsupported(.mixes)
    }

    public func station(type: StationType, seed: String, count: Int) async throws -> [String] {
        switch type {
        case .genre, .style:
            return try await source.randomTracks(genre: seed, yearRange: nil, limit: count)
        case .decade:
            guard let start = Int(seed.prefix(4)) else { throw SonicError.notFound(seed) }
            return try await source.randomTracks(genre: nil, yearRange: start...(start + 9), limit: count)
        case .mood:
            // Best metadata-only approximation of a mood station: an instant
            // mix seeded by the mood's seed track.
            return try await source.instantMix(seedID: seed, limit: count)
        }
    }

    public func loudness(forTrack itemID: String) async throws -> (integratedLufs: Double, truePeak: Double) {
        throw SonicError.unsupported(.loudness)
    }
}
