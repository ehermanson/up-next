// SwiftData models representing metadata about TV shows and movies
import Foundation
import SwiftData

/// Model representing a network/streaming provider
@Model
final class Network {
    /// Network ID from TMDB
    @Attribute(.unique) var id: Int

    /// Network name (e.g., "Netflix", "HBO")
    var name: String

    /// Logo path from TMDB
    var logoPath: String?

    /// Origin country code
    var originCountry: String?

    init(id: Int, name: String, logoPath: String? = nil, originCountry: String? = nil) {
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
    var networks: [Network] { get }
    var providerCategories: [Int: String] { get set }
    var descriptionText: String? { get }
    var cast: [String] { get }
    var castImagePaths: [String] { get }
    var castCharacters: [String] { get }
    var genres: [String] { get }
}

@Model
final class Movie: MediaItemProtocol {
    /// Unique ID, such as MovieDB's identifier
    @Attribute(.unique) var id: String

    /// Title of the movie
    var title: String

    /// Optional thumbnail image URL
    var thumbnailURL: URL?

    /// Networks/streaming providers for this movie
    @Relationship(deleteRule: .nullify) var networks: [Network]

    /// Additional optional metadata
    var descriptionText: String?
    var cast: [String]
    var castImagePaths: [String]
    var castCharacters: [String]
    var genres: [String]

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    var providerCategories: [Int: String]

    /// Release date in "YYYY-MM-DD" format (if known)
    var releaseDate: String?

    /// Runtime in minutes (specific to movies)
    var runtime: Int?

    init(
        id: String,
        title: String,
        thumbnailURL: URL? = nil,
        networks: [Network] = [],
        descriptionText: String? = nil,
        cast: [String] = [],
        castImagePaths: [String] = [],
        castCharacters: [String] = [],
        genres: [String] = [],
        providerCategories: [Int: String] = [:],
        releaseDate: String? = nil,
        runtime: Int? = nil
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
    }
}

@Model
final class TVShow: MediaItemProtocol {
    /// Unique ID, such as MovieDB's identifier
    @Attribute(.unique) var id: String

    /// Title of the TV show
    var title: String

    /// Optional thumbnail image URL
    var thumbnailURL: URL?

    /// Networks/streaming providers for this TV show
    @Relationship(deleteRule: .nullify) var networks: [Network]

    /// Additional optional metadata
    var descriptionText: String?
    var cast: [String]
    var castImagePaths: [String]
    var castCharacters: [String]
    var genres: [String]

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    var providerCategories: [Int: String]

    /// Number of seasons (specific to TV shows)
    var numberOfSeasons: Int?

    /// Number of episodes (specific to TV shows)
    var numberOfEpisodes: Int?

    /// Episode count per season (index 0 = season 1)
    var seasonEpisodeCounts: [Int]

    init(
        id: String,
        title: String,
        thumbnailURL: URL? = nil,
        networks: [Network] = [],
        descriptionText: String? = nil,
        cast: [String] = [],
        castImagePaths: [String] = [],
        castCharacters: [String] = [],
        genres: [String] = [],
        providerCategories: [Int: String] = [:],
        numberOfSeasons: Int? = nil,
        numberOfEpisodes: Int? = nil,
        seasonEpisodeCounts: [Int] = []
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
    }
}

extension Movie {
    /// User-facing release year derived from the stored date
    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
}

extension TVShow {
    /// User-facing summary of seasons and episodes for display
    var seasonsEpisodesSummary: String? {
        guard let seasons = numberOfSeasons else { return nil }

        let seasonsLabel = seasons == 1 ? "1 Season" : "\(seasons) Seasons"
        guard let episodes = numberOfEpisodes else { return seasonsLabel }

        let episodesLabel = episodes == 1 ? "1 Episode" : "\(episodes) Episodes"
        return "\(seasonsLabel) - \(episodesLabel)"
    }
}
