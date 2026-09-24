#if DEBUG
import Foundation

/// Drives the app into a reproducible, populated state for App Store screenshots. Only compiled
/// into DEBUG builds and never surfaced in the UI — activated by launching with `--screenshots`
/// (e.g. `xcrun simctl launch <udid> com.erichermanson.upnext --screenshots --tab tvShows`).
///
/// `ContentView` is the only caller: `configureProviders()` runs synchronously before the
/// first-launch provider sheet check, and `seed(library:lists:)` runs once both view models are
/// configured. Everything here talks to the view models' normal add/watch/rating APIs so seeded
/// rows are indistinguishable from ones a real user created.
enum ScreenshotMode {
    /// True when launched with `--screenshots`. The real user store is never touched in this mode —
    /// `Watch_ListApp` swaps in an in-memory, non-CloudKit `ModelConfiguration` instead.
    static let isEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--screenshots")

    /// Value following `--tab` (`tvShows` / `movies` / `collections` / `discover`), if present.
    static let requestedTab: String? = value(after: "--tab")

    /// TMDB id following `--open`, as a string to match `MediaItemProtocol.id`.
    static let requestedDetailID: String? = value(after: "--open")

    /// Collection name following `--collection`. Currently unused — see `seed`'s doc comment.
    static let requestedCollectionName: String? = value(after: "--collection")

    /// Set once `seed(library:lists:)` finishes so a second call (there shouldn't be one) is a no-op.
    private(set) static var isReady = false

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Selects a populated set of streaming services and turns off the Discover "only my services"
    /// filter so the provider chips read as a real user's setup and Discover shows everything. Runs
    /// before `ContentView`'s first-launch onboarding check so the provider sheet never appears.
    /// Netflix (8), Hulu (15), HBO Max (1899), Apple TV+ (350), Disney+ (337), Prime Video (9).
    static func configureProviders() {
        guard isEnabled else { return }
        let settings = ProviderSettings.shared
        settings.hasCompletedProviderOnboarding = true
        settings.selectProviders([8, 15, 1899, 350, 337, 9])
        settings.onlyMyServicesInDiscover = false
    }

    // MARK: - Seeding

    private struct TVSeed {
        let id: Int
        /// Marks each season from 1 through this number watched. Takes priority over
        /// `fullyWatched` when both are set (they aren't, in practice).
        let watchedThroughSeason: Int?
        /// Marks every season watched — used by the "Watched" seeds below.
        let fullyWatched: Bool
        let rating: Int?
    }

    private static let upNextTVSeeds: [TVSeed] = [
        TVSeed(id: 95396, watchedThroughSeason: nil, fullyWatched: false, rating: nil),   // Severance
        TVSeed(id: 136315, watchedThroughSeason: nil, fullyWatched: false, rating: nil),  // The Bear
        TVSeed(id: 95480, watchedThroughSeason: nil, fullyWatched: false, rating: nil),   // Slow Horses
        TVSeed(id: 126308, watchedThroughSeason: nil, fullyWatched: false, rating: nil),  // Shōgun
        TVSeed(id: 111803, watchedThroughSeason: nil, fullyWatched: false, rating: nil),  // The White Lotus
        TVSeed(id: 97546, watchedThroughSeason: 2, fullyWatched: false, rating: nil),     // Ted Lasso (S1–2)
        TVSeed(id: 1396, watchedThroughSeason: 3, fullyWatched: false, rating: nil),      // Breaking Bad (S1–3)
    ]

    private static let watchedTVSeeds: [TVSeed] = [
        TVSeed(id: 2316, watchedThroughSeason: nil, fullyWatched: true, rating: 1),   // The Office
        TVSeed(id: 76331, watchedThroughSeason: nil, fullyWatched: true, rating: 1),  // Succession
    ]

    private struct MovieSeed {
        let id: Int
        let watched: Bool
        let rating: Int?
    }

    private static let upNextMovieSeeds: [MovieSeed] = [
        MovieSeed(id: 693134, watched: false, rating: nil),  // Dune: Part Two
        MovieSeed(id: 872585, watched: false, rating: nil),  // Oppenheimer
        MovieSeed(id: 666277, watched: false, rating: nil),  // Past Lives
        MovieSeed(id: 840430, watched: false, rating: nil),  // The Holdovers
        MovieSeed(id: 569094, watched: false, rating: nil),  // Spider-Man: Across the Spider-Verse
        MovieSeed(id: 915935, watched: false, rating: nil),  // Anatomy of a Fall
    ]

    private static let watchedMovieSeeds: [MovieSeed] = [
        MovieSeed(id: 545611, watched: true, rating: 1),  // Everything Everywhere All at Once
        MovieSeed(id: 346698, watched: true, rating: nil),  // Barbie
    ]

    private struct CollectionSeed {
        let name: String
        let movieIDs: [Int]
    }

    private static let collectionSeeds: [CollectionSeed] = [
        CollectionSeed(name: "Christmas", movieIDs: [10719, 771, 508, 1581, 508965]),
        CollectionSeed(name: "Halloween", movieIDs: [9479, 4011, 14836]),
    ]

    /// Fetches the curated titles above from TMDB and adds them through `library`/`lists`' normal
    /// APIs so the resulting rows are canonical (same code path as search/Discover). Network fetches
    /// run concurrently (capped at 6, TMDB rate-limits) but every insert happens in the fixed order
    /// declared above, so the screenshots are reproducible regardless of fetch completion order. A
    /// title that fails to fetch is skipped rather than aborting the whole run.
    @MainActor
    static func seed(library: MediaLibraryViewModel, lists: CustomListViewModel) async {
        guard isEnabled, !isReady else { return }
        // Curated demo titles aren't activity; the Activity screen stays empty in screenshots.
        PersistenceController.shared.isSuppressingActivity = true
        defer { PersistenceController.shared.isSuppressingActivity = false }

        // The in-memory store starts empty, which trips `MediaLibraryViewModel.loadItems`'s DEBUG
        // demo-data fallback (`seedStubData`) before this function ever runs — including its own
        // "Christmas Stuff" collection. None of that is part of the curated set below, so purge
        // anything that doesn't belong before adding our own — otherwise screenshots show a mix.
        purgeNonCuratedItems(from: library, lists: lists)

        let allTVIDs = (upNextTVSeeds + watchedTVSeeds).map(\.id)
        let allMovieIDs = (upNextMovieSeeds + watchedMovieSeeds).map(\.id)
            + collectionSeeds.flatMap(\.movieIDs)

        // Fetch raw (Sendable, Codable) TMDB responses concurrently, then map to the SwiftData
        // model classes back on the main actor — mirrors `MediaLibraryViewModel.refreshAllItems`,
        // which keeps model objects from ever crossing a concurrency domain.
        async let tvDetails = fetchTVDetails(ids: allTVIDs)
        async let movieDetails = fetchMovieDetails(ids: allMovieIDs)
        let (fetchedTVDetails, fetchedMovieDetails) = await (tvDetails, movieDetails)

        let service = TMDBService.shared
        var fetchedTVShows: [Int: TVShow] = [:]
        for (id, detail) in fetchedTVDetails {
            let providers = detail.watchProviders?.results?[service.currentRegion]
            fetchedTVShows[id] = await service.mapToTVShow(detail, providers: providers)
        }
        var fetchedMovies: [Int: Movie] = [:]
        for (id, detail) in fetchedMovieDetails {
            let providers = detail.watchProviders?.results?[service.currentRegion]
            fetchedMovies[id] = await service.mapToMovie(detail, providers: providers)
        }

        for seed in upNextTVSeeds {
            addTVSeed(seed, from: fetchedTVShows, to: library)
        }
        for seed in watchedTVSeeds {
            addTVSeed(seed, from: fetchedTVShows, to: library)
        }

        for seed in upNextMovieSeeds {
            addMovieSeed(seed, from: fetchedMovies, to: library)
        }
        for seed in watchedMovieSeeds {
            addMovieSeed(seed, from: fetchedMovies, to: library)
        }

        for collectionSeed in collectionSeeds {
            if lists.customLists.first(where: { $0.name == collectionSeed.name }) == nil {
                lists.createList(name: collectionSeed.name)
            }
            guard let list = lists.customLists.first(where: { $0.name == collectionSeed.name }) else { continue }
            for movieID in collectionSeed.movieIDs {
                guard let movie = fetchedMovies[movieID] else { continue }
                lists.addItem(movie: movie, to: list)
            }
        }

        isReady = true
        // Polled by the capture script (`simctl launch --console` / `log stream`) to know seeding
        // has finished before taking a screenshot.
        print("SCREENSHOT_SEED_DONE")
    }

    /// Removes anything already in `library`/`lists` (e.g. DEBUG demo data seeded into the fresh
    /// in-memory store, including its own "Christmas Stuff" collection) whose id/name isn't part of
    /// the curated set, using the same deferred-delete API a swipe removes with, then commits
    /// immediately rather than waiting for the undo window.
    @MainActor
    private static func purgeNonCuratedItems(from library: MediaLibraryViewModel, lists: CustomListViewModel) {
        let keepTVIDs = Set((upNextTVSeeds + watchedTVSeeds).map { String($0.id) })
        let keepMovieIDs = Set((upNextMovieSeeds + watchedMovieSeeds).map { String($0.id) })
        let keepListNames = Set(collectionSeeds.map(\.name))

        for item in library.tvShows {
            guard let id = item.media?.id, !keepTVIDs.contains(id) else { continue }
            library.removeItem(withID: id, mediaType: .tvShow)
        }
        for item in library.movies {
            guard let id = item.media?.id, !keepMovieIDs.contains(id) else { continue }
            library.removeItem(withID: id, mediaType: .movie)
        }
        library.commitPendingDeletion()

        for list in lists.customLists where !keepListNames.contains(list.name) {
            lists.deleteList(list)
        }
    }

    @MainActor
    private static func addTVSeed(_ seed: TVSeed, from fetched: [Int: TVShow], to library: MediaLibraryViewModel) {
        guard let tvShow = fetched[seed.id] else { return }
        library.addTVShow(tvShow)
        guard let item = library.tvShows.first(where: { $0.media?.id == tvShow.id }) else { return }
        if let watchedThroughSeason = seed.watchedThroughSeason {
            if watchedThroughSeason > 0 {
                for season in 1...watchedThroughSeason where !item.watchedSeasons.contains(season) {
                    item.toggleSeason(season)
                }
            }
        } else if seed.fullyWatched {
            if !item.isWatched {
                item.toggleWatched()
            }
        }
        item.userRating = seed.rating
        library.persistChanges(for: .tvShow)
    }

    @MainActor
    private static func addMovieSeed(_ seed: MovieSeed, from fetched: [Int: Movie], to library: MediaLibraryViewModel) {
        guard let movie = fetched[seed.id] else { return }
        library.addMovie(movie)
        guard let item = library.movies.first(where: { $0.media?.id == movie.id }) else { return }
        if seed.watched {
            item.toggleWatched()
        }
        item.userRating = seed.rating
        library.persistChanges(for: .movie)
    }

    // MARK: - Fetching

    private static let maxConcurrentFetches = 6

    /// Fetches raw TV show detail responses in batches capped at `maxConcurrentFetches` (TMDB
    /// rate-limits). Failures are dropped silently — the caller skips anything missing.
    private static func fetchTVDetails(ids: [Int]) async -> [Int: TMDBTVShowDetail] {
        let service = TMDBService.shared
        var results: [Int: TMDBTVShowDetail] = [:]
        for batch in stride(from: 0, to: ids.count, by: maxConcurrentFetches) {
            let slice = ids[batch..<min(batch + maxConcurrentFetches, ids.count)]
            await withTaskGroup(of: (Int, TMDBTVShowDetail?).self) { group in
                for id in slice {
                    group.addTask {
                        let detail = try? await service.getTVShowDetails(id: id)
                        return (id, detail)
                    }
                }
                for await (id, detail) in group {
                    if let detail { results[id] = detail }
                }
            }
        }
        return results
    }

    /// Fetches raw movie detail responses in batches capped at `maxConcurrentFetches` (TMDB
    /// rate-limits). Failures are dropped silently — the caller skips anything missing.
    private static func fetchMovieDetails(ids: [Int]) async -> [Int: TMDBMovieDetail] {
        let service = TMDBService.shared
        var results: [Int: TMDBMovieDetail] = [:]
        for batch in stride(from: 0, to: ids.count, by: maxConcurrentFetches) {
            let slice = ids[batch..<min(batch + maxConcurrentFetches, ids.count)]
            await withTaskGroup(of: (Int, TMDBMovieDetail?).self) { group in
                for id in slice {
                    group.addTask {
                        let detail = try? await service.getMovieDetails(id: id)
                        return (id, detail)
                    }
                }
                for await (id, detail) in group {
                    if let detail { results[id] = detail }
                }
            }
        }
        return results
    }
}
#endif
