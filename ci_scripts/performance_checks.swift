// Deterministic service doubles for the actual Discover view model and response-cache actor.
// Run with ./ci_scripts/check_performance.sh on a Mac with the project's Xcode toolchain.
import Foundation
import Observation

nonisolated enum MediaType { case tvShow, movie }
nonisolated struct TMDBGenre { let id: Int; let name: String }
nonisolated struct TMDBTVShowSearchResult {
    let id: Int
    var name: String { "TV \(id)" }
    var posterPath: String? { nil }; var overview: String? { nil }
    var voteAverage: Double? { nil }; var firstAirDate: String? { nil }; var voteCount: Int? { nil }; var popularity: Double? { nil }
}
nonisolated struct TMDBMovieSearchResult {
    let id: Int
    var title: String { "Movie \(id)" }
    var posterPath: String? { nil }; var overview: String? { nil }
    var voteAverage: Double? { nil }; var releaseDate: String? { nil }; var voteCount: Int? { nil }; var popularity: Double? { nil }
}
nonisolated struct TMDBTVShowSearchResponse { let results: [TMDBTVShowSearchResult]; let totalPages: Int? }
nonisolated struct TMDBMovieSearchResponse { let results: [TMDBMovieSearchResult]; let totalPages: Int? }
nonisolated struct Episode { let airDate: String?; let seasonNumber: Int; let episodeNumber: Int }
nonisolated struct Detail { let nextEpisodeToAir: Episode? }
func episodeCode(season: Int, episode: Int) -> String { "S\(season)E\(episode)" }
enum SearchRanking {
    enum TitleMatch: Comparable { case none, strong, exact }
    static func bestTitleMatch(tvShow: (name: String, votes: Int?, date: String?, popularity: Double?)?,
                               movie: (name: String, votes: Int?, date: String?, popularity: Double?)?,
                               query: String) -> (match: TitleMatch, votes: Int?) { (.none, nil) }
}
enum SearchSession {
    struct Titles {
        var tvShows: [TMDBTVShowSearchResult] = []; var movies: [TMDBMovieSearchResult] = []
        var tvError: String?; var movieError: String?
    }
    struct Outcome {
        var described: DescriptiveSearch.Results?
        var remainder: (query: String, tvShows: [TMDBTVShowSearchResult], movies: [TMDBMovieSearchResult])?
    }
    /// Mirrors the real session's shape: both types fetched at once, each failure kept per type.
    static func run(query: String, mediaType: MediaType? = nil, titlesLanded: (Titles) -> Void) async -> Outcome? {
        async let tv: ([TMDBTVShowSearchResult], String?) = {
            do { return (try await TMDBService.shared.searchTVShows(query: query), nil) } catch { return ([], errorText(error)) }
        }()
        async let movies: ([TMDBMovieSearchResult], String?) = {
            do { return (try await TMDBService.shared.searchMovies(query: query), nil) } catch { return ([], errorText(error)) }
        }()
        let (shows, films) = await (tv, movies)
        guard !Task.isCancelled else { return nil }
        titlesLanded(Titles(tvShows: shows.0, movies: films.0, tvError: shows.1, movieError: films.1))
        return Outcome()
    }
    nonisolated static func errorText(_ error: any Error) -> String? { error.localizedDescription }
}
enum SearchModel {
    struct Reading {}
    static func prewarm() {}
    static func read(_ query: String) async -> Reading? { nil }
}
enum DescriptiveSearch {
    struct Interpretation { var mediaType: MediaType? }
    struct Results {
        let query: String
        let interpretation: Interpretation
        let tvShows: [TMDBTVShowSearchResult]
        let movies: [TMDBMovieSearchResult]
        var isEmpty: Bool { tvShows.isEmpty && movies.isEmpty }
        var readsAsDescription: Bool { false }
        func summary(for mediaType: MediaType) -> String { "" }
    }
    struct Layout<Item> { var leadingTitles: [Item] = []; var described: [Item] = []; var trailingTitles: [Item] = [] }
    static func layout<Item>(titles: [Item], described: [Item], query: String, descriptionFirst: Bool,
                             id: (Item) -> Int, name: (Item) -> String, votes: (Item) -> Int?,
                             date: (Item) -> String?, popularity: (Item) -> Double?) -> Layout<Item> {
        Layout(leadingTitles: titles, described: described)
    }
    static func run(query: String, titleMatch: SearchRanking.TitleMatch, titleVotes: Int? = nil, mediaType: MediaType? = nil,
                    reading: SearchModel.Reading? = nil) async -> Results? { nil }
    static func remainderTitleSearch(query: String, besideSection: Bool, reading: SearchModel.Reading? = nil) async -> (remainder: String, tvShows: [TMDBTVShowSearchResult], movies: [TMDBMovieSearchResult])? { nil }
}
@Observable final class ProviderSettings {
    static let shared = ProviderSettings()
    var onlyMyServicesInDiscover = false
    var hasSelectedProviders = false
    var watchProvidersQueryValue: String? = nil
}
final class TMDBService {
    static let shared = TMDBService()
    var currentRegion = "US"
    var requests = 0
    var pages: [Int] = []
    var failPage: Int?
    var failMovies = false
    var failCarousels = false
    static func apiDateString(from date: Date) -> String { "2026-10-05" }
    func invalidateResponseCache(pathPrefixes: [String]) async {}
    func wait() async { requests += 1; try? await Task.sleep(for: .milliseconds(60)) }
    func trendingTVShows(window: String) async throws -> TMDBTVShowSearchResponse {
        await wait(); if failCarousels { throw URLError(.notConnectedToInternet) }
        return .init(results: [.init(id: 9)], totalPages: 1000)
    }
    func trendingMovies(window: String) async throws -> TMDBMovieSearchResponse {
        await wait(); return .init(results: [.init(id: 9)], totalPages: 1000)
    }
    func nowPlayingMovies(page: Int) async throws -> TMDBMovieSearchResponse { try await trendingMovies(window: "week") }
    func discoverTVShows(page: Int = 1, sortBy: String = "popularity.desc", withGenres: String? = nil,
                         withWatchProviders: String? = nil, voteCountGte: Int? = nil,
                         firstAirDateLte: String? = nil, airDateGte: String? = nil, airDateLte: String? = nil) async throws -> TMDBTVShowSearchResponse {
        pages.append(page); await wait()
        if failPage == page { throw URLError(.notConnectedToInternet) }
        let ids = withGenres == "7" ? [7] : (page == 1 ? [1, 1, 2] : [2, 3])
        return .init(results: ids.map { .init(id: $0) }, totalPages: 1000)
    }
    func discoverMovies(page: Int = 1, sortBy: String = "popularity.desc", withGenres: String? = nil,
                        withWatchProviders: String? = nil, voteCountGte: Int? = nil, releaseDateLte: String? = nil) async throws -> TMDBMovieSearchResponse {
        await wait(); return .init(results: [.init(id: 4)], totalPages: 1000)
    }
    func fetchTVGenres() async throws -> [TMDBGenre] { await wait(); return [] }
    func fetchMovieGenres() async throws -> [TMDBGenre] { await wait(); return [] }
    func searchTVShows(query: String) async throws -> [TMDBTVShowSearchResult] { await wait(); return [.init(id: 8)] }
    func searchMovies(query: String) async throws -> [TMDBMovieSearchResult] {
        await wait(); if failMovies { throw URLError(.notConnectedToInternet) }; return [.init(id: 8)]
    }
    func getTVShowMetadata(id: Int) async throws -> Detail { await wait(); return .init(nextEpisodeToAir: nil) }
}
actor Counter {
    var value = 0
    func fetch() async throws -> Data { value += 1; try await Task.sleep(for: .milliseconds(30)); return Data([42]) }
}
@main struct Checks {
    static func main() async throws {
        let service = TMDBService.shared
        let model = DiscoverViewModel()
        let initial = Task { await model.initialLoad() }
        await Task.yield(); initial.cancel(); await initial.value
        precondition(!model.isBrowseLoading && !model.isCarouselLoading && !model.browseItems.isEmpty)
        let count = service.requests
        await model.initialLoad()
        precondition(service.requests == count, "tab return should not reload")
        precondition(model.browseTotalPages == 500)
        precondition(model.browseItems.map(\.tmdbId) == [1, 2], "page one must deduplicate")
        let refresh = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.isCarouselLoading && model.hasCarouselItems, "refresh should retain content")
        await refresh.value
        service.failCarousels = true
        await model.refresh()
        precondition(model.trendingItems.map(\.tmdbId) == [9], "failed refresh should retain section")
        service.failCarousels = false
        let next = Task { await model.loadNextBrowsePage() }
        await Task.yield(); next.cancel(); await next.value
        precondition(!model.isBrowseLoading && model.browsePage == 2)
        precondition(model.browseItems.map(\.tmdbId) == [1, 2, 3], "page overlap must deduplicate")
        service.failPage = 3
        await model.loadNextBrowsePage()
        precondition(model.browsePage == 2 && model.browseError != nil && !model.isBrowseLoading)
        service.failPage = nil
        await model.loadNextBrowsePage()
        precondition(model.browsePage == 3 && model.browseError == nil)
        service.failPage = 1
        await model.reloadBrowse()
        precondition(!model.browseItems.isEmpty && model.browseError != nil)
        service.failPage = nil
        await model.retryBrowse()
        precondition(model.browsePage == 1 && model.browseError == nil && model.browseTotalPages == 500)
        let stale = Task { await model.reloadBrowse() }
        try await Task.sleep(for: .milliseconds(5))
        model.selectedGenre = .init(id: 7, name: "Genre")
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.isBrowseLoading && model.browseItems.map(\.tmdbId) == [1, 2],
                     "genre changes must retain rows during loading to preserve scroll extent")
        await stale.value
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.browseItems.map(\.tmdbId) == [7] && !model.isBrowseLoading)
        model.selectedSort = .topRated
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.isBrowseLoading && model.browseItems.map(\.tmdbId) == [7],
                     "sort changes must retain rows during loading to preserve scroll extent")
        try await Task.sleep(for: .milliseconds(100))
        service.failMovies = true
        model.searchQuery = "query"
        try await Task.sleep(for: .milliseconds(420))
        precondition(model.searchError == nil && model.hasSearchResults)
        model.selectedMediaType = .movies
        precondition(model.searchError != nil, "switching search type must show its own failure")
        model.searchQuery = ""
        try await Task.sleep(for: .milliseconds(100))
        precondition(!model.isCarouselLoading && model.browseItems.map(\.tmdbId) == [4])
        let cache = RequestDeduplicator(), counter = Counter()
        let url = URL(string: "https://example.com/3/discover/tv")!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try? await cache.deduplicated(for: url) { try await counter.fetch() } } }
        }
        let requests = await counter.value
        precondition(requests == 1, "concurrent calls must coalesce")
        _ = try await cache.deduplicated(for: url) { try await counter.fetch() }
        let cachedRequests = await counter.value
        precondition(cachedRequests == 1)
        await cache.invalidateCache(pathPrefixes: ["/3/movie/"])
        _ = try await cache.deduplicated(for: url) { try await counter.fetch() }
        let scopedRequests = await counter.value
        precondition(scopedRequests == 1, "unrelated invalidation must preserve cache")
        await cache.invalidateCache(pathPrefixes: ["/3/discover/"])
        _ = try await cache.deduplicated(for: url) { try await counter.fetch() }
        let invalidatedRequests = await counter.value
        precondition(invalidatedRequests == 2)
        // Forced metadata refresh changes only the full URL it fetches, and warms normal reads.
        let detailURL = URL(string: "https://example.com/3/tv/1?append_to_response=credits")!
        let seasonURL = URL(string: "https://example.com/3/tv/1/season/1")!
        for otherURL in [detailURL, seasonURL] {
            _ = try await cache.deduplicated(for: otherURL) { try await counter.fetch() }
        }
        _ = try await cache.deduplicated(for: url, bypassCache: true) { try await counter.fetch() }
        for readURL in [url, detailURL, seasonURL] {
            _ = try await cache.deduplicated(for: readURL) { try await counter.fetch() }
        }
        let bypassRequests = await counter.value
        precondition(bypassRequests == 5, "bypass must preserve unrelated cached URLs and warm normal reads")
        let freshURL = URL(string: "https://example.com/3/tv/2")!
        let flight = Task { try await cache.deduplicated(for: freshURL) { try await counter.fetch() } }
        while await counter.value == 5 { await Task.yield() }
        flight.cancel()
        _ = try await cache.deduplicated(for: freshURL, bypassCache: true) { try await counter.fetch() }
        _ = try await flight.value
        let joinedRequests = await counter.value
        precondition(joinedRequests == 6, "bypass must reuse the canceled caller's shared download")
        FileHandle.standardOutput.write(Data("PASS: Discover cancellation, warm-tab reuse, refresh retention, page cap, page deduplication, failure retry, stale-filter rejection, per-type search errors; response coalescing, scoped invalidation, exact-URL bypass and reuse of canceled callers' downloads.\n".utf8))
    }
}
