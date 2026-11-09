import Combine
import Foundation
import JellyampCore
import JellyfinBackend
import SonicClient

/// Cache keys for the Home payloads that `LibraryCacheKey` does not cover.
enum HomeCacheKey {
    static let favoriteAlbums = "home.favoriteAlbums"
    static let genres = "home.genres"
    static let years = "home.years"
    static let jumpBackIn = "home.jumpBackIn"
}

/// Loads the Home shelves: paints the cached payloads immediately, then
/// refreshes every shelf independently. A failed request keeps what is on
/// screen — shelves are only ever replaced by a successful response, never
/// cleared, so the screen cannot blank during a refresh.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var mixes: [MixDescriptor] = []
    @Published private(set) var recentAlbums: [Album] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var favoriteAlbums: [Album] = []
    @Published private(set) var genres: [Genre] = []
    @Published private(set) var years: [Int] = []
    /// Full album items behind "Jump Back In" (the shelf itself is derived
    /// from the recently played tracks and shows before these arrive).
    @Published private(set) var jumpBackInDetails: [Album] = []
    @Published private(set) var hasFinishedRefresh = false
    @Published private(set) var anyRequestSucceeded = false

    private var didLoadCache = false
    private var isRefreshing = false
    private var lastRefresh: Date?
    /// Re-appearing (tab switches, popping back) refreshes at most this often;
    /// pull-to-refresh always goes through.
    private let minimumRefreshInterval: TimeInterval = 120

    // MARK: - Derived shelves

    var jumpBackIn: [Album] {
        HomeShelves.preferring(
            resolved: jumpBackInDetails,
            over: HomeShelves.jumpBackInAlbums(fromRecentTracks: recentTracks)
        )
    }

    var stationShelves: StationCatalog.Shelves {
        StationCatalog.shelves(
            hasTracks: !recentAlbums.isEmpty || !recentTracks.isEmpty || !genres.isEmpty || !years.isEmpty,
            genres: genres,
            years: years,
            recentTracks: recentTracks
        )
    }

    var contentState: HomeContentState {
        // Mixes don't count: cached ones are hidden while the sonic server is
        // away, and a library with mixes has albums anyway.
        let hasContent = !recentAlbums.isEmpty || !recentTracks.isEmpty || !favoriteAlbums.isEmpty
            || !genres.isEmpty || !years.isEmpty
        return HomeContentState.resolve(
            hasAnyContent: hasContent,
            hasFinishedRefresh: hasFinishedRefresh,
            anyRequestSucceeded: anyRequestSucceeded
        )
    }

    // MARK: - Loading

    /// Called when Home appears: cached paint once, then a throttled refresh.
    func loadIfNeeded(container: DependencyContainer) async {
        loadCache(from: container.libraryCache)
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < minimumRefreshInterval {
            return
        }
        await refresh(container: container)
    }

    /// Refreshes every shelf; each request succeeds or fails on its own.
    func refresh(container: DependencyContainer) async {
        guard !isRefreshing, let library = container.library else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cache = container.libraryCache
        let lookup = container.libraryLookup

        async let albumsRequest = library.recentlyAddedAlbums(limit: 20)
        async let tracksRequest = library.recentlyPlayedTracks(limit: 30)
        async let favoritesRequest = library.favoriteAlbums(limit: 20)
        async let genresRequest = library.genres()
        async let yearsRequest = Self.productionYears(lookup)

        var succeeded = false
        if let albums = try? await albumsRequest {
            recentAlbums = albums
            cache?.save(albums, for: LibraryCacheKey.recentAlbums)
            succeeded = true
        }
        if let tracks = try? await tracksRequest {
            recentTracks = tracks
            cache?.save(tracks, for: LibraryCacheKey.recentTracks)
            succeeded = true
        }
        if let favorites = try? await favoritesRequest {
            favoriteAlbums = favorites
            cache?.save(favorites, for: HomeCacheKey.favoriteAlbums)
            succeeded = true
        }
        if let fetchedGenres = try? await genresRequest {
            genres = fetchedGenres
            cache?.save(fetchedGenres, for: HomeCacheKey.genres)
            succeeded = true
        }
        if let fetchedYears = try? await yearsRequest {
            years = fetchedYears
            cache?.save(fetchedYears, for: HomeCacheKey.years)
            succeeded = true
        }
        await refreshMixes(container: container)

        let jumpBackInIDs = HomeShelves.jumpBackInAlbums(fromRecentTracks: recentTracks).map(\.id)
        if let lookup, !jumpBackInIDs.isEmpty, let albums = try? await lookup.albums(byIDs: jumpBackInIDs) {
            jumpBackInDetails = albums
            cache?.save(albums, for: HomeCacheKey.jumpBackIn)
        }

        if succeeded {
            anyRequestSucceeded = true
            lastRefresh = Date()
        }
        // Leaving Home cancels the task and with it the requests; that is
        // not a verdict on the server, so keep showing the loading state.
        if succeeded || !Task.isCancelled {
            hasFinishedRefresh = true
        }
    }

    /// Mixes for You exist only with jellyamp-server; also called on its own
    /// when the capabilities change (the server is probed after launch).
    func refreshMixes(container: DependencyContainer) async {
        guard container.sonicCapabilities.supports(.mixes),
              let sonic = container.sonic,
              let userID = container.session?.userID else { return }
        guard let fresh = try? await sonic.mixes(forUser: userID) else { return }
        let usable = fresh.filter { !$0.itemIDs.isEmpty }
        mixes = usable
        container.libraryCache?.save(usable, for: LibraryCacheKey.mixes)
    }

    private func loadCache(from cache: LibraryCache?) {
        guard !didLoadCache, let cache else { return }
        didLoadCache = true
        if let cached = cache.load([Album].self, for: LibraryCacheKey.recentAlbums) { recentAlbums = cached }
        if let cached = cache.load([Track].self, for: LibraryCacheKey.recentTracks) { recentTracks = cached }
        if let cached = cache.load([MixDescriptor].self, for: LibraryCacheKey.mixes) { mixes = cached }
        if let cached = cache.load([Album].self, for: HomeCacheKey.favoriteAlbums) { favoriteAlbums = cached }
        if let cached = cache.load([Genre].self, for: HomeCacheKey.genres) { genres = cached }
        if let cached = cache.load([Int].self, for: HomeCacheKey.years) { years = cached }
        if let cached = cache.load([Album].self, for: HomeCacheKey.jumpBackIn) { jumpBackInDetails = cached }
    }

    nonisolated private static func productionYears(_ lookup: LibraryLookupAPI?) async throws -> [Int] {
        guard let lookup else { throw JellyfinError.notAuthenticated }
        return try await lookup.productionYears()
    }
}
