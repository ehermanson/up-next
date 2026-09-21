import Foundation

@MainActor
@Observable
final class DiscoverViewModel {
    // MARK: - Types

    enum DiscoverMediaType: String, CaseIterable {
        case tvShows = "TV Shows"
        case movies = "Movies"
    }

    enum SortOption: String, CaseIterable {
        case popular = "Popular"
        case topRated = "Top Rated"
        case newest = "Newest"

        var tvSortBy: String {
            switch self {
            case .popular: "popularity.desc"
            case .topRated: "vote_average.desc"
            case .newest: "first_air_date.desc"
            }
        }

        var movieSortBy: String {
            switch self {
            case .popular: "popularity.desc"
            case .topRated: "vote_average.desc"
            case .newest: "primary_release_date.desc"
            }
        }
    }

    enum DiscoverItem: Identifiable {
        case tvShow(TMDBTVShowSearchResult)
        case movie(TMDBMovieSearchResult)

        var id: String {
            switch self {
            case .tvShow(let r): "tv_\(r.id)"
            case .movie(let r): "movie_\(r.id)"
            }
        }

        var tmdbId: Int {
            switch self {
            case .tvShow(let r): r.id
            case .movie(let r): r.id
            }
        }

        var title: String {
            switch self {
            case .tvShow(let r): r.name
            case .movie(let r): r.title
            }
        }

        var posterPath: String? {
            switch self {
            case .tvShow(let r): r.posterPath
            case .movie(let r): r.posterPath
            }
        }

        var overview: String? {
            switch self {
            case .tvShow(let r): r.overview
            case .movie(let r): r.overview
            }
        }

        var voteAverage: Double? {
            switch self {
            case .tvShow(let r): r.voteAverage
            case .movie(let r): r.voteAverage
            }
        }

        var mediaType: MediaType {
            switch self {
            case .tvShow: .tvShow
            case .movie: .movie
            }
        }

        /// Release/premiere year, parsed from TMDB's `yyyy-MM-dd` date string.
        var year: String? {
            let date: String?
            switch self {
            case .tvShow(let r): date = r.firstAirDate
            case .movie(let r): date = r.releaseDate
            }
            guard let date, date.count >= 4 else { return nil }
            return String(date.prefix(4))
        }
    }

    /// One carousel's outcome: its items, plus a message if the fetch failed.
    private struct CarouselResult {
        var items: [DiscoverItem] = []
        var errorDescription: String?
    }

    /// The filter state a browse request was issued under. A response whose request no longer
    /// matches the latest one is stale — a filter changed or the page counter was reset while
    /// it was in flight — and must not be applied.
    private struct BrowseRequest: Equatable {
        let mediaType: DiscoverMediaType
        let genreID: Int?
        let sort: SortOption
        let page: Int
        let providerFilter: String?
        /// Baked into `watch_region`, so a region change makes otherwise-identical requests differ.
        let region: String
    }

    // MARK: - State

    private var reloadTask: Task<Void, Never>?
    private var browseReloadTask: Task<Void, Never>?
    private var latestBrowseRequest: BrowseRequest?
    /// The media type the carousels currently on screen were fetched for. `selectedMediaType`'s
    /// `didSet` skips the reload while a search is active (see above), so this can lag behind it
    /// until `scheduleSearch`'s empty-query branch catches the mismatch up.
    private var loadedMediaType: DiscoverMediaType?
    /// True once a Discover load has completed successfully at least once — the SwiftUI `.task`
    /// that calls `initialLoad()` re-runs on every tab appearance, and without this it would
    /// flash the shimmer and reset Browse All to page 1 each time. A previous failure or
    /// cancellation leaves this false so returning to the tab retries.
    private var hasLoaded = false

    var selectedMediaType: DiscoverMediaType = .tvShows {
        didSet {
            guard oldValue != selectedMediaType else { return }
            // TV and movie genre ids are different vocabularies — a genre picked for one type
            // means something else (or nothing) for the other.
            if selectedGenre != nil { selectedGenre = nil }
            // While searching, both types are already fetched — flipping the segment just
            // changes which results are displayed, no refetch needed. `scheduleSearch`'s
            // empty-query branch catches up (via `loadedMediaType`) once search ends.
            guard !isSearchActive else { return }
            reloadTask?.cancel()
            reloadTask = Task { await reload() }
        }
    }

    var trendingItems: [DiscoverItem] = []
    var topRatedItems: [DiscoverItem] = []
    var newReleasesItems: [DiscoverItem] = []
    /// TV only: shows with an episode airing in the next seven days.
    var airingThisWeekItems: [DiscoverItem] = []
    /// Movies only: titles currently in theaters.
    var inTheatersItems: [DiscoverItem] = []

    var browseItems: [DiscoverItem] = []
    var browsePage = 1
    var browseTotalPages = 1
    var isBrowseLoading = false
    var isCarouselLoading = false

    /// Set when a carousel fetch failed. The view only surfaces it when every carousel is empty.
    var carouselError: String?
    /// Set when a browse page fetch failed. The view only surfaces it when there are no items.
    var browseError: String?

    /// True when at least one carousel has something to show.
    var hasCarouselItems: Bool {
        !trendingItems.isEmpty || !topRatedItems.isEmpty
            || !newReleasesItems.isEmpty || !airingThisWeekItems.isEmpty
            || !inTheatersItems.isEmpty
    }

    var selectedGenre: TMDBGenre? {
        didSet {
            guard oldValue?.id != selectedGenre?.id else { return }
            browseReloadTask?.cancel()
            browseReloadTask = Task { await reloadBrowse() }
        }
    }
    var selectedSort: SortOption = .popular {
        didSet {
            guard oldValue != selectedSort else { return }
            browseReloadTask?.cancel()
            browseReloadTask = Task { await reloadBrowse() }
        }
    }

    var genres: [TMDBGenre] = []

    private let service = TMDBService.shared

    /// Non-nil only when the user opted into filtering Discover to their selected services.
    private var providerFilter: String? {
        let settings = ProviderSettings.shared
        guard settings.onlyMyServicesInDiscover, settings.hasSelectedProviders else { return nil }
        return settings.watchProvidersQueryValue
    }

    /// The region TMDB lookups currently run against. Tracked alongside `providerFilter` so a
    /// superseded region's results can't land on the current carousels.
    private var currentRegion: String {
        service.currentRegion
    }

    /// Called when the "on my services" toggle, the selected providers, or the region change.
    /// Cancels any in-flight loads and reissues everything under the new filter.
    func providerFilterChanged() {
        reloadTask?.cancel()
        browseReloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    // MARK: - Loading

    /// No-ops once a load has already succeeded, so the SwiftUI `.task` that calls this on every
    /// tab appearance doesn't flash the shimmer and reset Browse All to page 1 each time. Pull-
    /// to-refresh (`refresh()`) always reloads regardless of `hasLoaded`.
    func initialLoad() async {
        guard !hasLoaded else { return }
        let completed = await runOwnedReload()
        if completed, carouselError == nil, browseError == nil {
            hasLoaded = true
        }
    }

    /// Pull-to-refresh. Drops the cached responses for the endpoints Discover owns before
    /// reloading — otherwise a refresh inside `RequestDeduplicator`'s 10-minute TTL would just
    /// re-read the cache. Scoped rather than invalidating the whole cache so detail pages,
    /// search results and the provider list the rest of the app relies on stay cached.
    func refresh() async {
        await service.invalidateResponseCache(
            pathPrefixes: ["/discover/", "/trending/", "/movie/now_playing", "/genre/"]
        )
        airingDateRequestedIDs.removeAll()
        await runOwnedReload()
    }

    /// Runs `reload()` on a task this view model owns and waits for it. The loaders bail on
    /// cancellation and leave the loading flags for "the replacement" to clear — which is right
    /// when *we* cancelled them for a newer load, but SwiftUI also cancels the caller's task
    /// (`.task` on a tab switch, `.refreshable` when the gesture ends) with no replacement
    /// coming, and the shimmer would never end. Awaiting an owned task's value doesn't forward
    /// that cancellation, so the load always runs to completion and clears its own flags.
    /// Returns whether the owned task ran to completion rather than being superseded.
    @discardableResult
    private func runOwnedReload() async -> Bool {
        reloadTask?.cancel()
        let task = Task { await reload() }
        reloadTask = task
        await task.value
        return !task.isCancelled
    }

    /// Reloads everything. Also drives pull-to-refresh; `reloadBrowse()` already resets the
    /// page counter, so browse isn't loaded twice.
    func reload() async {
        async let carousels: Void = loadCarousels()
        async let browse: Void = reloadBrowse()
        async let genreLoad: Void = loadGenres()
        _ = await (carousels, browse, genreLoad)
    }

    private func loadCarousels() async {
        let requestedMediaType = selectedMediaType
        let requestedProviderFilter = providerFilter
        let requestedRegion = currentRegion
        isCarouselLoading = true
        carouselError = nil

        let today = TMDBService.apiDateString(from: .now)
        let weekOut = TMDBService.apiDateString(from: Date.now.addingTimeInterval(7 * 24 * 60 * 60))

        async let trending = fetchTrendingCarousel(
            mediaType: requestedMediaType, providerFilter: requestedProviderFilter
        )
        async let topRated = fetchTopRatedCarousel(
            mediaType: requestedMediaType, providerFilter: requestedProviderFilter
        )
        async let newReleases = fetchNewReleasesCarousel(
            mediaType: requestedMediaType, providerFilter: requestedProviderFilter, today: today
        )
        async let airingThisWeek = fetchAiringThisWeekCarousel(
            mediaType: requestedMediaType, providerFilter: requestedProviderFilter,
            today: today, weekOut: weekOut
        )
        async let inTheaters = fetchInTheatersCarousel(mediaType: requestedMediaType)

        let results = await (trending, topRated, newReleases, airingThisWeek, inTheaters)

        // The shared request task isn't cancelled by us, so check explicitly: a superseded
        // media type, provider filter or region's results must not land on the current carousels.
        // A superseded load also leaves the loading flag alone; its replacement owns it.
        guard !Task.isCancelled,
              requestedMediaType == selectedMediaType,
              requestedProviderFilter == providerFilter,
              requestedRegion == currentRegion
        else { return }

        trendingItems = results.0.items
        topRatedItems = results.1.items
        newReleasesItems = results.2.items
        airingThisWeekItems = results.3.items
        inTheatersItems = results.4.items
        carouselError = [
            results.0.errorDescription, results.1.errorDescription, results.2.errorDescription,
            results.3.errorDescription, results.4.errorDescription,
        ].compactMap { $0 }.first
        isCarouselLoading = false
        loadedMediaType = requestedMediaType
    }

    /// Real trending when unfiltered. `/trending` can't take `with_watch_providers`, so when the
    /// user is filtering to their services we fall back to provider-scoped popularity — the
    /// closest provider-aware equivalent.
    private func fetchTrendingCarousel(
        mediaType: DiscoverMediaType, providerFilter: String?
    ) async -> CarouselResult {
        do {
            if providerFilter != nil {
                return CarouselResult(items: try await discoverItems(
                    mediaType: mediaType, sortBy: "popularity.desc", providerFilter: providerFilter
                ))
            }
            switch mediaType {
            case .tvShows:
                let response = try await service.trendingTVShows(window: "week")
                return CarouselResult(items: response.results.map { .tvShow($0) })
            case .movies:
                let response = try await service.trendingMovies(window: "week")
                return CarouselResult(items: response.results.map { .movie($0) })
            }
        } catch {
            return CarouselResult(errorDescription: Self.errorText(error))
        }
    }

    private func fetchTopRatedCarousel(
        mediaType: DiscoverMediaType, providerFilter: String?
    ) async -> CarouselResult {
        do {
            return CarouselResult(items: try await discoverItems(
                mediaType: mediaType, sortBy: "vote_average.desc",
                voteCountGte: 200, providerFilter: providerFilter
            ))
        } catch {
            return CarouselResult(errorDescription: Self.errorText(error))
        }
    }

    /// Newest *released* titles. The `…date.lte` cutoff keeps pre-release titles that already
    /// have a handful of festival votes out of the list.
    private func fetchNewReleasesCarousel(
        mediaType: DiscoverMediaType, providerFilter: String?, today: String
    ) async -> CarouselResult {
        do {
            switch mediaType {
            case .tvShows:
                return CarouselResult(items: try await discoverItems(
                    mediaType: .tvShows, sortBy: "first_air_date.desc",
                    voteCountGte: 50, providerFilter: providerFilter, firstAirDateLte: today
                ))
            case .movies:
                return CarouselResult(items: try await discoverItems(
                    mediaType: .movies, sortBy: "primary_release_date.desc",
                    voteCountGte: 50, providerFilter: providerFilter, releaseDateLte: today
                ))
            }
        } catch {
            return CarouselResult(errorDescription: Self.errorText(error))
        }
    }

    /// TV only: shows airing an episode between today and a week out. Respects the provider
    /// filter, since these are ordinary streaming/broadcast titles.
    private func fetchAiringThisWeekCarousel(
        mediaType: DiscoverMediaType, providerFilter: String?, today: String, weekOut: String
    ) async -> CarouselResult {
        guard mediaType == .tvShows else { return CarouselResult() }
        do {
            return CarouselResult(items: try await discoverItems(
                mediaType: .tvShows, sortBy: "popularity.desc", providerFilter: providerFilter,
                airDateGte: today, airDateLte: weekOut
            ))
        } catch {
            return CarouselResult(errorDescription: Self.errorText(error))
        }
    }

    /// Movies only: what's in theaters right now. Deliberately ignores the provider filter —
    /// a theatrical run isn't a streaming service.
    private func fetchInTheatersCarousel(mediaType: DiscoverMediaType) async -> CarouselResult {
        guard mediaType == .movies else { return CarouselResult() }
        do {
            let response = try await service.nowPlayingMovies(page: 1)
            return CarouselResult(items: response.results.map { .movie($0) })
        } catch {
            return CarouselResult(errorDescription: Self.errorText(error))
        }
    }

    func reloadBrowse() async {
        browsePage = 1
        browseTotalPages = 1
        await loadBrowsePage()
    }

    func loadNextBrowsePage() async {
        guard !isBrowseLoading, browsePage < browseTotalPages else { return }
        browsePage += 1
        await loadBrowsePage()
    }

    private func loadBrowsePage() async {
        let request = BrowseRequest(
            mediaType: selectedMediaType,
            genreID: selectedGenre?.id,
            sort: selectedSort,
            page: browsePage,
            providerFilter: providerFilter,
            region: currentRegion
        )
        latestBrowseRequest = request
        isBrowseLoading = true
        browseError = nil

        let genreID = request.genreID.map(String.init)
        let sortBy = request.mediaType == .movies
            ? request.sort.movieSortBy : request.sort.tvSortBy
        let voteCountGte = request.sort == .topRated ? 200 :
                           request.sort == .newest ? 50 : nil

        do {
            let newItems: [DiscoverItem]
            let totalPages: Int
            if request.mediaType == .tvShows {
                let response = try await service.discoverTVShows(
                    page: request.page, sortBy: sortBy, withGenres: genreID,
                    withWatchProviders: request.providerFilter,
                    voteCountGte: voteCountGte
                )
                newItems = response.results.map { DiscoverItem.tvShow($0) }
                totalPages = response.totalPages ?? 1
            } else {
                let response = try await service.discoverMovies(
                    page: request.page, sortBy: sortBy, withGenres: genreID,
                    withWatchProviders: request.providerFilter,
                    voteCountGte: voteCountGte
                )
                newItems = response.results.map { DiscoverItem.movie($0) }
                totalPages = response.totalPages ?? 1
            }

            // The shared request task isn't cancelled by us, so check explicitly: filters may
            // have changed (or the page counter reset) while this page was in flight.
            guard !Task.isCancelled, latestBrowseRequest == request else { return }
            if request.page == 1 {
                browseItems = newItems
            } else {
                browseItems.append(contentsOf: newItems)
            }
            browseTotalPages = totalPages
        } catch {
            // Items stay as-is; the view decides whether the failure is worth showing.
            guard !Task.isCancelled, latestBrowseRequest == request else { return }
            // `loadNextBrowsePage` already advanced `browsePage` past this failed page; roll it
            // back so the next attempt (retry button or the infinite-scroll sentinel) re-fetches
            // the same page instead of skipping it forever.
            browsePage = max(1, request.page - 1)
            browseError = Self.errorText(error)
        }
        // A superseded page leaves the flag alone; its replacement owns it.
        isBrowseLoading = false
    }

    private func loadGenres() async {
        let requestedMediaType = selectedMediaType
        do {
            let loaded = requestedMediaType == .tvShows
                ? try await service.fetchTVGenres()
                : try await service.fetchMovieGenres()
            guard !Task.isCancelled, requestedMediaType == selectedMediaType else { return }
            genres = loaded
        } catch {
            // Keep whatever genre list is already showing rather than blanking the filter menu
            // out from under the user for a transient failure.
        }
    }

    /// One page of `/discover` results for a carousel, with the optional date bounds TMDB
    /// names differently per media type.
    private func discoverItems(
        mediaType: DiscoverMediaType,
        sortBy: String,
        voteCountGte: Int? = nil,
        providerFilter: String?,
        firstAirDateLte: String? = nil,
        airDateGte: String? = nil,
        airDateLte: String? = nil,
        releaseDateLte: String? = nil
    ) async throws -> [DiscoverItem] {
        if mediaType == .tvShows {
            let response = try await service.discoverTVShows(
                page: 1, sortBy: sortBy, withWatchProviders: providerFilter,
                voteCountGte: voteCountGte, firstAirDateLte: firstAirDateLte,
                airDateGte: airDateGte, airDateLte: airDateLte
            )
            return response.results.map { .tvShow($0) }
        } else {
            let response = try await service.discoverMovies(
                page: 1, sortBy: sortBy, withWatchProviders: providerFilter,
                voteCountGte: voteCountGte, releaseDateLte: releaseDateLte
            )
            return response.results.map { .movie($0) }
        }
    }

    /// User-facing text for a failed fetch — `nil` for cancellations, which are a superseded
    /// request rather than a failure worth surfacing.
    private static func errorText(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        return error.localizedDescription
    }

    // MARK: - Search

    /// One search type's outcome. Failures are kept per-type so a movie outage can't blank the
    /// TV results the user is actually looking at (mirrors `WatchlistSearchView`).
    private struct SearchOutcome<Element> {
        var results: [Element] = []
        var error: String?
    }

    private var searchTask: Task<Void, Never>?

    var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            scheduleSearch(for: searchQuery)
        }
    }

    var searchTVResults: [TMDBTVShowSearchResult] = []
    var searchMovieResults: [TMDBMovieSearchResult] = []
    var isSearching = false
    /// Set when the type currently on screen failed to load. A failed type keeps its previous
    /// results rather than blanking, mirroring `WatchlistSearchView`.
    var searchError: String?

    /// True once the user has typed something — the view swaps carousels/Browse All for results.
    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSearchResults: Bool {
        selectedMediaType == .tvShows ? !searchTVResults.isEmpty : !searchMovieResults.isEmpty
    }

    /// The current search results as `DiscoverItem`s for the selected media type, so the view can
    /// reuse the same row builder as Browse All.
    var searchResultItems: [DiscoverItem] {
        selectedMediaType == .tvShows
            ? searchTVResults.map { .tvShow($0) }
            : searchMovieResults.map { .movie($0) }
    }

    /// How many results the *unselected* type has, for the "Show N movies instead" hint.
    var crossTypeSearchResultCount: Int {
        selectedMediaType == .tvShows ? searchMovieResults.count : searchTVResults.count
    }

    var searchCrossTypeHintTitle: String {
        let count = crossTypeSearchResultCount
        if selectedMediaType == .tvShows {
            return "Show \(count) movie\(count == 1 ? "" : "s") instead"
        }
        return "Show \(count) TV show\(count == 1 ? "" : "s") instead"
    }

    /// Flips to the other media type — used by the "Show N movies instead" hint.
    func showOtherSearchMediaType() {
        selectedMediaType = selectedMediaType == .tvShows ? .movies : .tvShows
    }

    /// Debounces ~300ms and cancels the previous search, mirroring `WatchlistSearchView`.
    private func scheduleSearch(for query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask = nil
            isSearching = false
            searchError = nil
            searchTVResults = []
            searchMovieResults = []
            // The segment may have flipped mid-search (`selectedMediaType`'s didSet skips the
            // reload while `isSearchActive`) — catch up now that carousels/Browse All are back
            // on screen, instead of showing the wrong media type until the next full reload.
            if loadedMediaType != selectedMediaType {
                Task { await runOwnedReload() }
            }
            return
        }

        isSearching = true
        searchError = nil

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmed)
        }
    }

    /// Both types are searched every time so the cross-type hint is accurate and flipping the
    /// segment is instant — the second request is served from the response cache.
    private func performSearch(query: String) async {
        async let tvFetch = fetchTVSearch(query: query)
        async let movieFetch = fetchMovieSearch(query: query)
        let (tv, movie) = await (tvFetch, movieFetch)

        // The shared request task isn't cancelled by us, so check explicitly — a superseded
        // keystroke's response must not overwrite the current one.
        guard !Task.isCancelled else { return }

        if tv.error == nil { searchTVResults = tv.results }
        if movie.error == nil { searchMovieResults = movie.results }
        // Only the type on screen gets to raise the error banner.
        searchError = selectedMediaType == .tvShows ? tv.error : movie.error
        isSearching = false
    }

    private func fetchTVSearch(query: String) async -> SearchOutcome<TMDBTVShowSearchResult> {
        do {
            return SearchOutcome(results: try await service.searchTVShows(query: query))
        } catch {
            return SearchOutcome(error: Self.errorText(error))
        }
    }

    private func fetchMovieSearch(query: String) async -> SearchOutcome<TMDBMovieSearchResult> {
        do {
            return SearchOutcome(results: try await service.searchMovies(query: query))
        } catch {
            return SearchOutcome(error: Self.errorText(error))
        }
    }

    // MARK: - Airing This Week: per-card air date

    /// TMDB `air_date` string for the show's next episode, keyed by TMDB show id. Populated
    /// lazily by `loadAiringDate(for:)` — `/discover/tv` and `/search/tv` only carry
    /// `firstAirDate` (the premiere), not the specific episode that placed the show in the
    /// "Airing This Week" window, so each visible card fetches its own show detail.
    var airingDates: [Int: String] = [:]
    /// "S3E2" companion to `airingDates`, when TMDB gave us both numbers.
    var airingEpisodeCodes: [Int: String] = [:]

    private var airingDateRequestedIDs: Set<Int> = []

    /// Fetches `next_episode_to_air` for one show and stores its air date (and episode code, if
    /// available) for the "Airing This Week" chip. Called from each card's `.task(id:)` — the
    /// `LazyHStack` only mounts visible cards, and `getTVShowDetails` is the same call the detail
    /// sheet makes, deduped/cached by `RequestDeduplicator`, so this isn't wasted work.
    func loadAiringDate(for tmdbId: Int) async {
        guard !airingDateRequestedIDs.contains(tmdbId) else { return }
        airingDateRequestedIDs.insert(tmdbId)
        do {
            let detail = try await service.getTVShowMetadata(id: tmdbId)
            guard let episode = detail.nextEpisodeToAir, let airDate = episode.airDate else { return }
            airingDates[tmdbId] = airDate
            airingEpisodeCodes[tmdbId] = episodeCode(season: episode.seasonNumber, episode: episode.episodeNumber)
        } catch {
            // Transient failure, not "no data" — allow a later appearance of the card to retry
            // rather than permanently blocking the chip.
            airingDateRequestedIDs.remove(tmdbId)
        }
    }
}
