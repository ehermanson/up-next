import Foundation

// MARK: - Search Response Models

/// One page of a paginated TMDB list response. Lets `TMDBService` fetch and merge the first
/// pages of `/search/{tv,movie}` generically. `nonisolated` (like the other model types below)
/// so its `Decodable` conformance can be decoded inside `searchPages`'s `async let` pair without
/// the compiler treating a generic `Page: TMDBSearchPage` as possibly main-actor-isolated.
nonisolated protocol TMDBSearchPage: Decodable {
    associatedtype Result: Identifiable where Result.ID == Int
    var results: [Result] { get }
    var totalPages: Int? { get }
}

nonisolated struct TMDBTVShowSearchResponse: Codable, TMDBSearchPage, Sendable {
    let results: [TMDBTVShowSearchResult]
    let totalPages: Int?
}

nonisolated struct TMDBMovieSearchResponse: Codable, TMDBSearchPage, Sendable {
    let results: [TMDBMovieSearchResult]
    let totalPages: Int?
}

// MARK: - Genre List Response

struct TMDBGenreListResponse: Codable {
    let genres: [TMDBGenre]
}

// MARK: - TV Show Models

nonisolated struct TMDBTVShowSearchResult: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    /// `/search`, `/discover` and `/recommendations` all return these; the detail endpoint does not
    /// (it returns full `genres`). Used by `RecommendationEngine` for genre affinity and the
    /// vote-count floor.
    let genreIds: [Int]?
    let voteCount: Int?
    /// Search-only signals read by `SearchRanking` (see `TMDBService.searchTVShows`).
    let originalName: String?
    let popularity: Double?
}

struct TMDBTVShowDetail: Codable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let episodeRunTime: [Int]?
    let nextEpisodeToAir: TMDBEpisode?
    /// "Returning Series", "Ended", "Canceled", "In Production", ...
    let status: String?
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
    let contentRatings: TMDBContentRatingsResponse?
    let similar: TMDBTVShowSearchResponse?
    let recommendations: TMDBTVShowSearchResponse?
    let videos: TMDBVideosResponse?
    let networks: [TMDBNetwork]?
    let seasons: [TMDBSeason]?
    let watchProviders: TMDBWatchProvidersResponse?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, posterPath, backdropPath, firstAirDate, voteAverage
        case numberOfSeasons, numberOfEpisodes, episodeRunTime, nextEpisodeToAir, status
        case genres, credits, contentRatings, similar, recommendations, videos
        case networks, seasons
        case watchProviders = "watch/providers"
    }
}

struct TMDBEpisode: Codable {
    let airDate: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    let name: String?
}

struct TMDBSeason: Codable {
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
    let overview: String?
    let voteAverage: Double?
}

// MARK: - Season Detail (episode list)

/// `/tv/{id}/season/{season_number}` — read-only episode list for `SeasonEpisodesView`.
/// No episode-level watched state exists or is planned; this is display-only.
struct TMDBSeasonDetail: Codable {
    let id: Int?
    let name: String?
    let overview: String?
    let airDate: String?
    let seasonNumber: Int
    let episodes: [TMDBSeasonEpisode]?
}

struct TMDBSeasonEpisode: Codable, Identifiable {
    let id: Int
    let episodeNumber: Int
    let seasonNumber: Int?
    let name: String?
    let overview: String?
    let airDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let runtime: Int?
    let stillPath: String?
}

// MARK: - Movie Models

nonisolated struct TMDBMovieSearchResult: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    /// See `TMDBTVShowSearchResult.genreIds`.
    let genreIds: [Int]?
    let voteCount: Int?
    /// Search-only signals read by `SearchRanking` (see `TMDBService.searchMovies`).
    let originalTitle: String?
    let popularity: Double?
}

struct TMDBMovieDetail: Codable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let runtime: Int?
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
    let releaseDates: TMDBReleaseDatesResponse?
    let similar: TMDBMovieSearchResponse?
    let recommendations: TMDBMovieSearchResponse?
    let videos: TMDBVideosResponse?
    let belongsToCollection: TMDBBelongsToCollection?
    let watchProviders: TMDBWatchProvidersResponse?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, posterPath, backdropPath, releaseDate, voteAverage
        case runtime, genres, credits, releaseDates, similar, recommendations, videos
        case belongsToCollection
        case watchProviders = "watch/providers"
    }
}

struct TMDBBelongsToCollection: Codable {
    let id: Int
    let name: String
    let posterPath: String?
    let backdropPath: String?
}

struct TMDBCollectionDetail: Codable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let parts: [TMDBCollectionPart]
}

struct TMDBCollectionPart: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let releaseDate: String?
    let voteAverage: Double?

    var releaseYear: String? {
        guard let date = releaseDate, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }
}

// Watch Providers (per country)
struct TMDBWatchProvidersResponse: Codable {
    let results: [String: TMDBWatchProviderCountry]?
}

struct TMDBWatchProviderCountry: Codable {
    let link: String?
    let flatrate: [TMDBWatchProviderEntry]?
    let rent: [TMDBWatchProviderEntry]?
    let buy: [TMDBWatchProviderEntry]?
    let ads: [TMDBWatchProviderEntry]?
}

struct TMDBWatchProviderEntry: Codable {
    let displayPriority: Int?
    let logoPath: String?
    let providerId: Int
    let providerName: String
}

// MARK: - Supporting Models

struct TMDBGenre: Codable {
    let id: Int
    let name: String
}

struct TMDBCredits: Codable {
    let cast: [TMDBCastMember]?
}

struct TMDBCastMember: Codable {
    let name: String
    let character: String?
    let order: Int?
    let profilePath: String?
}

struct TMDBNetwork: Codable {
    let id: Int
    let name: String
    let logoPath: String?
    let originCountry: String?
}

// MARK: - Videos

struct TMDBVideosResponse: Codable {
    let results: [TMDBVideo]?
}

struct TMDBVideo: Codable {
    let key: String
    let site: String
    let type: String
    let name: String
    let official: Bool?
}

// MARK: - Content Ratings & Release Dates

struct TMDBContentRatingsResponse: Codable {
    let results: [TMDBContentRating]?
}

struct TMDBContentRating: Codable {
    let iso31661: String
    let rating: String
}

struct TMDBReleaseDatesResponse: Codable {
    let results: [TMDBReleaseDateCountry]?
}

struct TMDBReleaseDateCountry: Codable {
    let iso31661: String
    let releaseDates: [TMDBReleaseDateEntry]?
}

struct TMDBReleaseDateEntry: Codable {
    let certification: String?
    let type: Int?
}

// MARK: - Watch Provider List Models

// Response from /watch/providers/movie or /watch/providers/tv
nonisolated struct TMDBWatchProviderListResponse: Codable, Sendable {
    let results: [TMDBWatchProviderInfo]
}

nonisolated struct TMDBWatchProviderInfo: Codable, Identifiable, Sendable {
    let providerId: Int
    let providerName: String
    let logoPath: String?
    let displayPriority: Int?

    var id: Int { providerId }
    // Note: No CodingKeys needed - decoder uses .convertFromSnakeCase automatically
}

// Response from /watch/providers/regions
nonisolated struct TMDBWatchProviderRegionListResponse: Codable, Sendable {
    let results: [TMDBWatchProviderRegion]
}

nonisolated struct TMDBWatchProviderRegion: Codable, Identifiable, Sendable, Hashable {
    /// ISO 3166-1 country code, e.g. "US". `.convertFromSnakeCase` turns `iso_3166_1` into this,
    /// the same way `TMDBContentRating` decodes it.
    let iso31661: String
    let englishName: String
    let nativeName: String

    var id: String { iso31661 }
}
