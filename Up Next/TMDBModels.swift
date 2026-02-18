import Foundation

// MARK: - Search Response Models

struct TMDBTVShowSearchResponse: Codable {
    let results: [TMDBTVShowSearchResult]
    let totalPages: Int?
}

struct TMDBMovieSearchResponse: Codable {
    let results: [TMDBMovieSearchResult]
    let totalPages: Int?
}

// MARK: - Genre List Response

struct TMDBGenreListResponse: Codable {
    let genres: [TMDBGenre]
}

// MARK: - TV Show Models

struct TMDBTVShowSearchResult: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
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
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
    let contentRatings: TMDBContentRatingsResponse?
    let similar: TMDBTVShowSearchResponse?
    let recommendations: TMDBTVShowSearchResponse?
    let networks: [TMDBNetwork]?
    let seasons: [TMDBSeason]?
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
}

// MARK: - Movie Models

struct TMDBMovieSearchResult: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
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

// MARK: - Content Ratings & Release Dates

struct TMDBContentRatingsResponse: Codable {
    let results: [TMDBContentRating]?
}

struct TMDBContentRating: Codable {
    let iso31661: String
    let rating: String

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case rating
    }
}

struct TMDBReleaseDatesResponse: Codable {
    let results: [TMDBReleaseDateCountry]?
}

struct TMDBReleaseDateCountry: Codable {
    let iso31661: String
    let releaseDates: [TMDBReleaseDateEntry]?

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

struct TMDBReleaseDateEntry: Codable {
    let certification: String?
    let type: Int?
}

// MARK: - Watch Provider List Models

// Response from /watch/providers/movie or /watch/providers/tv
struct TMDBWatchProviderListResponse: Codable {
    let results: [TMDBWatchProviderInfo]
}

struct TMDBWatchProviderInfo: Codable, Identifiable {
    let providerId: Int
    let providerName: String
    let logoPath: String?
    let displayPriority: Int?

    var id: Int { providerId }
    // Note: No CodingKeys needed - decoder uses .convertFromSnakeCase automatically
}
