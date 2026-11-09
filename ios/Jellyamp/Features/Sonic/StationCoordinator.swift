import Combine
import Foundation
import JellyampCore
import JellyfinBackend
import SonicClient

extension DependencyContainer {
    /// True when jellyamp-server answers the sonic calls; false on the
    /// Jellyfin-only fallback (or before a session exists).
    var isSonicServerActive: Bool { sonic is SonicAPIClient }

    /// Batched ID lookups / random picks straight from Jellyfin.
    var libraryLookup: LibraryLookupAPI? {
        guard let session else { return nil }
        return LibraryLookupAPI(session: session)
    }

    /// Resolves track IDs from sonic results to library tracks.
    var trackResolver: TrackResolver? {
        guard let library, let lookup = libraryLookup else { return nil }
        return TrackResolver(library: library, lookup: lookup)
    }
}

/// Resolves ID lists to tracks: through the (possibly decorated) library for
/// ordinary lists, in chunked requests for long ones — a mix or a ranked
/// station can carry hundreds of IDs, too many for one query string.
struct TrackResolver: Sendable {
    let library: MusicLibraryProviding
    let lookup: LibraryLookupAPI

    func tracks(byIDs ids: [String]) async throws -> [Track] {
        if ids.count <= 80 {
            return try await library.tracks(byIDs: ids)
        }
        return try await lookup.tracks(byIDs: ids)
    }
}

/// Runs the station that is currently playing: starts it with an initial
/// batch and tops the queue up as it plays. The selection logic (dedupe,
/// artist spacing, thresholds) is `StationSession` in JellyampCore; this
/// class only moves tracks between the source and the player.
///
/// `DependencyContainer` forwards track changes and asks `refillIfNeeded`
/// before its plain autoplay, so a station and autoplay never both refill.
@MainActor
final class StationCoordinator: ObservableObject {
    /// The station in charge of the queue, if any.
    @Published private(set) var activeStation: StationDefinition?
    /// Set while a tapped station loads its first batch (spinner on the card).
    @Published private(set) var startingStationID: String?
    /// User-facing reason the last start failed; cleared by the alert.
    @Published var failureMessage: String?

    private var session: StationSession?
    private var source: RadioSource?
    private var isRefilling = false
    /// Bumped on every start/stop so results of an outdated fetch are dropped.
    private var generation = 0

    func start(_ station: StationDefinition, container: DependencyContainer) {
        guard let player = container.player,
              let source = StationSourceFactory.makeSource(for: station, container: container) else { return }
        generation += 1
        let token = generation
        // A refill of the previous station that is still in flight is
        // discarded by the generation check and must not block new refills.
        isRefilling = false
        startingStationID = station.id
        failureMessage = nil

        Task { @MainActor in
            var fresh = StationSession(station: station)
            let tracks: [Track]
            do {
                tracks = try await StationRefill.nextTracks(session: &fresh, source: source, queued: [], currentTrackID: nil)
            } catch {
                guard token == self.generation else { return }
                self.startingStationID = nil
                self.failureMessage = String(localized: "The station could not be loaded. Check your connection and try again.")
                return
            }
            guard token == self.generation else { return }
            self.startingStationID = nil
            guard !tracks.isEmpty else {
                self.failureMessage = String(localized: "No tracks were found for this station.")
                return
            }
            // Install the session before loading: the player publishes the
            // new current track right away and `trackChanged` must find it.
            self.session = fresh
            self.source = source
            self.activeStation = station
            player.load(queue: PlayQueue(tracks: tracks))
        }
    }

    func stop() {
        generation += 1
        session = nil
        source = nil
        activeStation = nil
        startingStationID = nil
        isRefilling = false
    }

    /// Called by the container whenever the playing track changes. Ends the
    /// station once neither the current nor any queued track came from it
    /// (the user started something else).
    func trackChanged(to trackID: String, upNext: [Track]) {
        guard var current = session else { return }
        if current.isStillPlaying(currentTrackID: trackID, upNextIDs: upNext.map(\.id)) {
            current.notePlayed(trackID: trackID)
            session = current
        } else {
            stop()
        }
    }

    /// Tops the queue up when it runs low. Returns true while a station is
    /// active — the caller then skips its own autoplay refill.
    func refillIfNeeded(container: DependencyContainer) -> Bool {
        guard let current = session, let source else { return false }
        let playerState = container.playerState
        guard !isRefilling,
              current.needsRefill(remaining: playerState.upNext.count),
              let player = container.player else { return true }

        var queued = playerState.upNext
        if let playing = playerState.currentTrack { queued.insert(playing, at: 0) }
        let currentTrackID = playerState.currentTrack?.id
        let token = generation
        isRefilling = true

        Task { @MainActor in
            // Select on a copy: the live session keeps recording plays while
            // the fetch is in flight.
            var working = current
            let tracks = (try? await StationRefill.nextTracks(
                session: &working,
                source: source,
                queued: queued,
                currentTrackID: currentTrackID
            )) ?? []
            guard token == self.generation else { return }
            self.isRefilling = false
            guard !tracks.isEmpty else { return }
            self.session?.markIssued(tracks.map(\.id))
            player.enqueue(tracks)
        }
        return true
    }
}

/// Builds the candidate source for a station from what is available:
/// jellyamp-server's sonically ranked stations/similarity when it is
/// connected, Jellyfin's random-by-genre/decade and Instant Mix otherwise —
/// so every station on Home works against a plain Jellyfin server.
enum StationSourceFactory {
    /// Random Jellyfin queries need no deep paging; cap what one asks for.
    private static let randomLimit = 100

    @MainActor
    static func makeSource(for station: StationDefinition, container: DependencyContainer) -> RadioSource? {
        guard let library = container.library, let lookup = container.libraryLookup else { return nil }
        let resolver = TrackResolver(library: library, lookup: lookup)
        let sonic = container.sonic
        let capabilities = container.sonicCapabilities
        // Server stations are ranked by sound; the fallback provider would
        // only wrap the same random Jellyfin query in an extra ID round-trip.
        let rankedStations: SonicProviding? =
            (container.isSonicServerActive && capabilities.supports(.stations)) ? sonic : nil
        let similarProvider: SonicProviding? = capabilities.supports(.similar) ? sonic : nil

        switch station.seed {
        case .library:
            return RadioSource { request in
                try await lookup.randomTracks(limit: min(request.count, randomLimit))
            }

        case .genre(let name):
            return RadioSource { request in
                if let ranked = await rankedTracks(rankedStations, type: .genre, seed: name, count: request.count, resolver: resolver) {
                    return ranked
                }
                return try await lookup.randomTracks(genre: name, limit: min(request.count, randomLimit))
            }

        case .decade(let decade):
            return RadioSource { request in
                if let ranked = await rankedTracks(rankedStations, type: .decade, seed: decade.seed, count: request.count, resolver: resolver) {
                    return ranked
                }
                return try await lookup.randomTracks(years: decade.yearRange, limit: min(request.count, randomLimit))
            }

        case .artist(let artistID):
            return RadioSource { request in
                let own = try await library.tracks(byArtist: artistID).shuffled()
                // Similarity is seeded by one of the artist's tracks: track
                // IDs work with both the server and Jellyfin's Instant Mix.
                var similar: [Track] = []
                if let seedID = own.first?.id {
                    similar = await similarTracks(similarProvider, seedID: seedID, count: request.count, resolver: resolver)
                }
                return RadioBlend.interleave(primary: similar, secondary: own)
            }

        case .track(let trackID):
            return RadioSource { request in
                let seedID = request.currentTrackID ?? trackID
                let similar = await similarTracks(similarProvider, seedID: seedID, count: request.count, resolver: resolver)
                guard request.currentTrackID == nil else { return similar }
                // First batch: the seed track itself opens the station.
                let seed = try await library.tracks(byIDs: [trackID])
                return seed + similar
            }
        }
    }

    /// Server-ranked station tracks, or nil when the server is not in use,
    /// fails, or knows no analyzed track for the seed (then the caller falls
    /// back to Jellyfin).
    private static func rankedTracks(
        _ provider: SonicProviding?,
        type: StationType,
        seed: String,
        count: Int,
        resolver: TrackResolver
    ) async -> [Track]? {
        guard let provider else { return nil }
        guard let ids = try? await provider.station(type: type, seed: seed, count: count), !ids.isEmpty else { return nil }
        guard let tracks = try? await resolver.tracks(byIDs: ids), !tracks.isEmpty else { return nil }
        return tracks
    }

    private static func similarTracks(
        _ provider: SonicProviding?,
        seedID: String,
        count: Int,
        resolver: TrackResolver
    ) async -> [Track] {
        guard let provider else { return [] }
        guard let results = try? await provider.similarTracks(to: seedID, limit: count) else { return [] }
        let ids = SimilarRanking.orderedIDs(
            from: results.map { (itemID: $0.itemID, distance: $0.distance) },
            excluding: seedID,
            limit: count
        )
        return (try? await resolver.tracks(byIDs: ids)) ?? []
    }
}
