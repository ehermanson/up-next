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

    // MARK: - State

    private var reloadTask: Task<Void, Never>?
    private var browseReloadTask: Task<Void, Never>?

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
        isCarouselLoading = true

        await withTaskGroup(of: (String, [DiscoverItem]).self) { group in
            group.addTask { [selectedMediaType] in
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: "popularity.desc",
                    voteCountGte: nil, page: 1
                )
                return ("trending", items)
            }
            group.addTask { [selectedMediaType] in
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: "vote_average.desc",
                    voteCountGte: 200, page: 1
                )
                return ("topRated", items)
            }
            group.addTask { [selectedMediaType] in
                let sortBy = selectedMediaType == .movies
                    ? "primary_release_date.desc" : "first_air_date.desc"
                let items = await self.fetchItems(
                    mediaType: selectedMediaType, sortBy: sortBy,
                    voteCountGte: 50, page: 1
                )
                return ("newReleases", items)
            }

            for await (key, items) in group {
                switch key {
                case "trending": trendingItems = items
                case "topRated": topRatedItems = items
                case "newReleases": newReleasesItems = items
                default: break
                }
            }
        }
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
        isBrowseLoading = true
        let genreID = selectedGenre.map { String($0.id) }
        let sortBy = selectedMediaType == .movies
            ? selectedSort.movieSortBy : selectedSort.tvSortBy
        let voteCountGte = selectedSort == .topRated ? 200 :
                           selectedSort == .newest ? 50 : nil

        do {
            if selectedMediaType == .tvShows {
                let response = try await service.discoverTVShows(
                    page: browsePage, sortBy: sortBy, withGenres: genreID,
                    voteCountGte: voteCountGte
                )
                let newItems = response.results.map { DiscoverItem.tvShow($0) }
                if browsePage == 1 {
                    browseItems = newItems
                } else {
                    browseItems.append(contentsOf: newItems)
                }
                browseTotalPages = response.totalPages ?? 1
            } else {
                let response = try await service.discoverMovies(
                    page: browsePage, sortBy: sortBy, withGenres: genreID,
                    voteCountGte: voteCountGte
                )
                let newItems = response.results.map { DiscoverItem.movie($0) }
                if browsePage == 1 {
                    browseItems = newItems
                } else {
                    browseItems.append(contentsOf: newItems)
                }
                browseTotalPages = response.totalPages ?? 1
            }
        } catch {
            // Silently fail; items stay as-is
        }
        isBrowseLoading = false
    }

    private func loadGenres() async {
        do {
            if selectedMediaType == .tvShows {
                genres = try await service.fetchTVGenres()
            } else {
                genres = try await service.fetchMovieGenres()
            }
        } catch {
            genres = []
        }
    }

    private func fetchItems(
        mediaType: DiscoverMediaType, sortBy: String,
        voteCountGte: Int?, page: Int
    ) async -> [DiscoverItem] {
        do {
            if mediaType == .tvShows {
                let response = try await service.discoverTVShows(
                    page: page, sortBy: sortBy, voteCountGte: voteCountGte
                )
                return response.results.map { .tvShow($0) }
            } else {
                let response = try await service.discoverMovies(
                    page: page, sortBy: sortBy, voteCountGte: voteCountGte
                )
                return response.results.map { .movie($0) }
            }
        } catch {
            return []
        }
    }
}
