import Foundation

// MARK: - Search Response Models

struct TMDBTVShowSearchResponse: Codable {
    let results: [TMDBTVShowSearchResult]
}

struct TMDBMovieSearchResponse: Codable {
    let results: [TMDBMovieSearchResult]
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
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
    let networks: [TMDBNetwork]?
    let seasons: [TMDBSeason]?
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
