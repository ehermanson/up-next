// SwiftData models representing metadata about TV shows and movies
import Foundation
import SwiftData

/// Model representing a network/streaming provider
@Model
final class Network {
    /// Network ID from TMDB
    var id: Int = 0

    /// Network name (e.g., "Netflix", "HBO")
    var name: String = ""

    /// Logo path from TMDB
    var logoPath: String?

    /// Origin country code
    var originCountry: String?

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \Movie.networks) var movies: [Movie]?
    @Relationship(inverse: \TVShow.networks) var tvShows: [TVShow]?

    init(id: Int = 0, name: String = "", logoPath: String? = nil, originCountry: String? = nil) {
        self.id = id
        self.name = name
        self.logoPath = logoPath
        self.originCountry = originCountry
    }
}

/// Protocol defining shared properties for all media items
protocol MediaItemProtocol {
    var id: String { get }
    var title: String { get }
    var thumbnailURL: URL? { get }
    var networks: [Network]? { get }
    var providerCategories: [Int: String] { get set }
    var descriptionText: String? { get }
    var cast: [String] { get }
    var castImagePaths: [String] { get }
    var castCharacters: [String] { get }
    var genres: [String] { get }
    var voteAverage: Double? { get }
}

@Model
final class Movie: MediaItemProtocol {
    /// Unique ID, such as MovieDB's identifier
    var id: String = ""

    /// Title of the movie
    var title: String = ""

    /// Optional thumbnail image URL
    var thumbnailURL: URL?

    /// Networks/streaming providers for this movie
    @Relationship(deleteRule: .nullify) var networks: [Network]?

    /// Additional optional metadata
    var descriptionText: String?
    var cast: [String] = []
    var castImagePaths: [String] = []
    var castCharacters: [String] = []
    var genres: [String] = []

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    var providerCategories: [Int: String] = [:]

    /// Release date in "YYYY-MM-DD" format (if known)
    var releaseDate: String?

    /// Runtime in minutes (specific to movies)
    var runtime: Int?

    /// TMDB vote average (0–10)
    var voteAverage: Double?

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \ListItem.movie) var listItems: [ListItem]?
    @Relationship(inverse: \CustomListItem.movie) var customListItems: [CustomListItem]?

    init(
        id: String = "",
        title: String = "",
        thumbnailURL: URL? = nil,
        networks: [Network]? = nil,
        descriptionText: String? = nil,
        cast: [String] = [],
        castImagePaths: [String] = [],
        castCharacters: [String] = [],
        genres: [String] = [],
        providerCategories: [Int: String] = [:],
        releaseDate: String? = nil,
        runtime: Int? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.networks = networks
        self.descriptionText = descriptionText
        self.cast = cast
        self.castImagePaths = castImagePaths
        self.castCharacters = castCharacters
        self.genres = genres
        self.providerCategories = providerCategories
        self.releaseDate = releaseDate
        self.runtime = runtime
        self.voteAverage = voteAverage
    }
}

@Model
final class TVShow: MediaItemProtocol {
    /// Unique ID, such as MovieDB's identifier
    var id: String = ""

    /// Title of the TV show
    var title: String = ""

    /// Optional thumbnail image URL
    var thumbnailURL: URL?

    /// Networks/streaming providers for this TV show
    @Relationship(deleteRule: .nullify) var networks: [Network]?

    /// Additional optional metadata
    var descriptionText: String?
    var cast: [String] = []
    var castImagePaths: [String] = []
    var castCharacters: [String] = []
    var genres: [String] = []

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    var providerCategories: [Int: String] = [:]

    /// Number of seasons (specific to TV shows)
    var numberOfSeasons: Int?

    /// Number of episodes (specific to TV shows)
    var numberOfEpisodes: Int?

    /// Episode count per season (index 0 = season 1)
    var seasonEpisodeCounts: [Int] = []

    /// Average episode runtime in minutes
    var episodeRunTime: Int?

    /// TMDB vote average (0–10)
    var voteAverage: Double?

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \ListItem.tvShow) var listItems: [ListItem]?
    @Relationship(inverse: \CustomListItem.tvShow) var customListItems: [CustomListItem]?

    init(
        id: String = "",
        title: String = "",
        thumbnailURL: URL? = nil,
        networks: [Network]? = nil,
        descriptionText: String? = nil,
        cast: [String] = [],
        castImagePaths: [String] = [],
        castCharacters: [String] = [],
        genres: [String] = [],
        providerCategories: [Int: String] = [:],
        numberOfSeasons: Int? = nil,
        numberOfEpisodes: Int? = nil,
        seasonEpisodeCounts: [Int] = [],
        episodeRunTime: Int? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.networks = networks
        self.descriptionText = descriptionText
        self.cast = cast
        self.castImagePaths = castImagePaths
        self.castCharacters = castCharacters
        self.genres = genres
        self.providerCategories = providerCategories
        self.numberOfSeasons = numberOfSeasons
        self.numberOfEpisodes = numberOfEpisodes
        self.seasonEpisodeCounts = seasonEpisodeCounts
        self.episodeRunTime = episodeRunTime
        self.voteAverage = voteAverage
    }
}

extension Movie {
    /// Applies all TMDB-sourced fields from a freshly-fetched instance.
    /// Add new TMDB fields here — this is the single place to keep in sync.
    func update(from source: Movie) {
        title = source.title
        descriptionText = source.descriptionText
        cast = source.cast
        castImagePaths = source.castImagePaths
        castCharacters = source.castCharacters
        genres = source.genres
        networks = source.networks
        providerCategories = source.providerCategories
        releaseDate = source.releaseDate
        runtime = source.runtime
        voteAverage = source.voteAverage
        if source.thumbnailURL != nil {
            thumbnailURL = source.thumbnailURL
        }
    }

    /// User-facing release year derived from the stored date
    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
}

extension TVShow {
    /// Applies all TMDB-sourced fields from a freshly-fetched instance.
    /// Add new TMDB fields here — this is the single place to keep in sync.
    func update(from source: TVShow) {
        title = source.title
        descriptionText = source.descriptionText
        cast = source.cast
        castImagePaths = source.castImagePaths
        castCharacters = source.castCharacters
        genres = source.genres
        networks = source.networks
        providerCategories = source.providerCategories
        numberOfSeasons = source.numberOfSeasons
        numberOfEpisodes = source.numberOfEpisodes
        seasonEpisodeCounts = source.seasonEpisodeCounts
        episodeRunTime = source.episodeRunTime
        voteAverage = source.voteAverage
        if source.thumbnailURL != nil {
            thumbnailURL = source.thumbnailURL
        }
    }

    /// User-facing summary of seasons and episodes for display
    var seasonsEpisodesSummary: String? {
        guard let seasons = numberOfSeasons else { return nil }

        let seasonsLabel = seasons == 1 ? "1 Season" : "\(seasons) Seasons"
        guard let episodes = numberOfEpisodes else { return seasonsLabel }

        let episodesLabel = episodes == 1 ? "1 Episode" : "\(episodes) Episodes"
        return "\(seasonsLabel) - \(episodesLabel)"
    }
}
