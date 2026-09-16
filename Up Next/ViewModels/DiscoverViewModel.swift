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
    }

    // MARK: - State

    private var reloadTask: Task<Void, Never>?
    private var browseReloadTask: Task<Void, Never>?
    private var latestBrowseRequest: BrowseRequest?

    var selectedMediaType: DiscoverMediaType = .tvShows {
        didSet {
            guard oldValue != selectedMediaType else { return }
            reloadTask?.cancel()
            reloadTask = Task { await reload() }
        }
    }

    var trendingItems: [DiscoverItem] = []
    var topRatedItems: [DiscoverItem] = []
    var newReleasesItems: [DiscoverItem] = []

    var browseItems: [DiscoverItem] = []
    var browsePage = 1
    var browseTotalPages = 1
    var isBrowseLoading = false
    var isCarouselLoading = false

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

    /// Called when the "on my services" toggle or the selected providers change. Cancels any
    /// in-flight loads and reissues everything under the new filter.
    func providerFilterChanged() {
        reloadTask?.cancel()
        browseReloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    // MARK: - Loading

    func initialLoad() async {
        await reload()
    }

    func reload() async {
        async let carousels: Void = loadCarousels()
        async let browse: Void = reloadBrowse()
        async let genreLoad: Void = loadGenres()
        _ = await (carousels, browse, genreLoad)
    }

    private func loadCarousels() async {
        let requestedMediaType = selectedMediaType
        let requestedProviderFilter = providerFilter
        isCarouselLoading = true

        await withTaskGroup(of: (String, [DiscoverItem]).self) { group in
            group.addTask { [selectedMediaType] in
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: "popularity.desc",
                    voteCountGte: nil, page: 1, providerFilter: requestedProviderFilter
                )
                return ("trending", items)
            }
            group.addTask { [selectedMediaType] in
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: "vote_average.desc",
                    voteCountGte: 200, page: 1, providerFilter: requestedProviderFilter
                )
                return ("topRated", items)
            }
            group.addTask { [selectedMediaType] in
                let sortBy = selectedMediaType == .movies
                    ? "primary_release_date.desc" : "first_air_date.desc"
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: sortBy,
                    voteCountGte: 50, page: 1, providerFilter: requestedProviderFilter
                )
                return ("newReleases", items)
            }

            for await (key, items) in group {
                // The shared request task isn't cancelled by us, so check explicitly: a
                // superseded media type's results must not land on the current carousels.
                guard !Task.isCancelled, requestedMediaType == selectedMediaType else { continue }
                switch key {
                case "trending": trendingItems = items
                case "topRated": topRatedItems = items
                case "newReleases": newReleasesItems = items
                default: break
                }
            }
        }
        // A superseded load leaves the flag alone; its replacement owns it.
        guard !Task.isCancelled, requestedMediaType == selectedMediaType else { return }
        isCarouselLoading = false
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
            providerFilter: providerFilter
        )
        latestBrowseRequest = request
        isBrowseLoading = true

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
            // Silently fail; items stay as-is
            guard !Task.isCancelled, latestBrowseRequest == request else { return }
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
            guard !Task.isCancelled, requestedMediaType == selectedMediaType else { return }
            genres = []
        }
    }

    private func fetchItems(
        mediaType: DiscoverMediaType, sortBy: String,
        voteCountGte: Int?, page: Int, providerFilter: String?
    ) async -> [DiscoverItem] {
        do {
            if mediaType == .tvShows {
                let response = try await service.discoverTVShows(
                    page: page, sortBy: sortBy, withWatchProviders: providerFilter,
                    voteCountGte: voteCountGte
                )
                return response.results.map { .tvShow($0) }
            } else {
                let response = try await service.discoverMovies(
                    page: page, sortBy: sortBy, withWatchProviders: providerFilter,
                    voteCountGte: voteCountGte
                )
                return response.results.map { .movie($0) }
            }
        } catch {
            return []
        }
    }
}
