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

    /// TMDB backdrop path (16:9 artwork) used by the detail header. Optional so the
    /// CloudKit schema change stays additive.
    var backdropPath: String?

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

    /// Content rating (e.g., "PG-13", "R")
    var contentRating: String?

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
        backdropPath: String? = nil,
        networks: [Network]? = nil,
        descriptionText: String? = nil,
        cast: [String] = [],
        castImagePaths: [String] = [],
        castCharacters: [String] = [],
        genres: [String] = [],
        providerCategories: [Int: String] = [:],
        contentRating: String? = nil,
        releaseDate: String? = nil,
        runtime: Int? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.backdropPath = backdropPath
        self.networks = networks
        self.descriptionText = descriptionText
        self.cast = cast
        self.castImagePaths = castImagePaths
        self.castCharacters = castCharacters
        self.genres = genres
        self.providerCategories = providerCategories
        self.contentRating = contentRating
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

    /// TMDB backdrop path (16:9 artwork) used by the detail header. Optional so the
    /// CloudKit schema change stays additive.
    var backdropPath: String?

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

    /// Season descriptions/overviews (index 0 = season 1)
    var seasonDescriptions: [String] = []

    /// Average episode runtime in minutes
    var episodeRunTime: Int?

    /// Content rating (e.g., "TV-MA", "TV-PG")
    var contentRating: String?

    /// Next episode air date in "YYYY-MM-DD" format (if the show is still airing)
    var nextEpisodeAirDate: String?

    /// Season / episode number and title of the next episode to air, when TMDB knows them
    var nextEpisodeSeason: Int?
    var nextEpisodeNumber: Int?
    var nextEpisodeName: String?

    /// TMDB series status: "Returning Series", "Ended", "Canceled", "In Production", ...
    var status: String?

    /// TMDB vote average (0–10)
    var voteAverage: Double?

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \ListItem.tvShow) var listItems: [ListItem]?
    @Relationship(inverse: \CustomListItem.tvShow) var customListItems: [CustomListItem]?

    init(
        id: String = "",
        title: String = "",
        thumbnailURL: URL? = nil,
        backdropPath: String? = nil,
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
        seasonDescriptions: [String] = [],
        contentRating: String? = nil,
        episodeRunTime: Int? = nil,
        nextEpisodeAirDate: String? = nil,
        nextEpisodeSeason: Int? = nil,
        nextEpisodeNumber: Int? = nil,
        nextEpisodeName: String? = nil,
        status: String? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.backdropPath = backdropPath
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
        self.seasonDescriptions = seasonDescriptions
        self.contentRating = contentRating
        self.episodeRunTime = episodeRunTime
        self.nextEpisodeAirDate = nextEpisodeAirDate
        self.nextEpisodeSeason = nextEpisodeSeason
        self.nextEpisodeNumber = nextEpisodeNumber
        self.nextEpisodeName = nextEpisodeName
        self.status = status
        self.voteAverage = voteAverage
    }
}

// MARK: - Shared cleanup helpers

/// True when two network lists describe the same providers. `TMDBService` builds brand-new
/// `Network` instances on every fetch, so identity comparison would always report a change.
private func networksAreEquivalent(_ lhs: [Network]?, _ rhs: [Network]?) -> Bool {
    let left = lhs ?? []
    let right = rhs ?? []
    guard left.count == right.count else { return false }
    return zip(left, right).allSatisfy { a, b in
        a.id == b.id && a.name == b.name && a.logoPath == b.logoPath
    }
}

/// Deletes the `Network` rows in `networks` that nothing other than `ownerID` refers to. Without
/// this they pile up as orphans (and CloudKit records) every time metadata is refreshed.
private func deleteUnreferencedNetworks(
    _ networks: [Network]?,
    excludingOwner ownerID: PersistentIdentifier,
    in context: ModelContext
) {
    guard let networks else { return }
    for network in networks {
        let stillReferenced = (network.movies ?? []).contains { $0.persistentModelID != ownerID }
            || (network.tvShows ?? []).contains { $0.persistentModelID != ownerID }
        guard !stillReferenced else { continue }
        context.delete(network)
    }
}

/// Replaces `current` with `incoming` only when the providers actually differ, deleting any
/// network rows that `ownerID` was the last referrer of. Returns the list to store, or nil when
/// nothing changed and the caller should leave the relationship alone.
private func reconciledNetworks(
    current: [Network]?,
    incoming: [Network]?,
    ownerID: PersistentIdentifier,
    in context: ModelContext?
) -> [Network]?? {
    guard !networksAreEquivalent(current, incoming) else { return nil }
    if let context {
        deleteUnreferencedNetworks(current, excludingOwner: ownerID, in: context)
    }
    return .some(incoming)
}

/// Deletes a `Movie`/`TVShow` row — plus any networks only it referred to — once nothing points at
/// it any more. `deletedItemID` is the list item that was just deleted; it can linger in the
/// inverse relationships until the context is saved, so it's filtered out.
func deleteMediaIfUnreferenced(
    movie: Movie?,
    tvShow: TVShow?,
    ignoring deletedItemID: PersistentIdentifier,
    in context: ModelContext
) {
    if let movie {
        let stillReferenced = (movie.listItems ?? []).contains { $0.persistentModelID != deletedItemID }
            || (movie.customListItems ?? []).contains { $0.persistentModelID != deletedItemID }
        if !stillReferenced {
            deleteUnreferencedNetworks(movie.networks, excludingOwner: movie.persistentModelID, in: context)
            context.delete(movie)
        }
    }
    if let tvShow {
        let stillReferenced = (tvShow.listItems ?? []).contains { $0.persistentModelID != deletedItemID }
            || (tvShow.customListItems ?? []).contains { $0.persistentModelID != deletedItemID }
        if !stillReferenced {
            deleteUnreferencedNetworks(tvShow.networks, excludingOwner: tvShow.persistentModelID, in: context)
            context.delete(tvShow)
        }
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
        if let replacement = reconciledNetworks(
            current: networks,
            incoming: source.networks,
            ownerID: persistentModelID,
            in: modelContext
        ) {
            networks = replacement
        }
        providerCategories = source.providerCategories
        contentRating = source.contentRating
        releaseDate = source.releaseDate
        runtime = source.runtime
        voteAverage = source.voteAverage
        if source.thumbnailURL != nil {
            thumbnailURL = source.thumbnailURL
        }
        if source.backdropPath != nil {
            backdropPath = source.backdropPath
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
        if let replacement = reconciledNetworks(
            current: networks,
            incoming: source.networks,
            ownerID: persistentModelID,
            in: modelContext
        ) {
            networks = replacement
        }
        providerCategories = source.providerCategories
        numberOfSeasons = source.numberOfSeasons
        numberOfEpisodes = source.numberOfEpisodes
        seasonEpisodeCounts = source.seasonEpisodeCounts
        seasonDescriptions = source.seasonDescriptions
        contentRating = source.contentRating
        episodeRunTime = source.episodeRunTime
        nextEpisodeAirDate = source.nextEpisodeAirDate
        nextEpisodeSeason = source.nextEpisodeSeason
        nextEpisodeNumber = source.nextEpisodeNumber
        nextEpisodeName = source.nextEpisodeName
        status = source.status
        voteAverage = source.voteAverage
        if source.thumbnailURL != nil {
            thumbnailURL = source.thumbnailURL
        }
        if source.backdropPath != nil {
            backdropPath = source.backdropPath
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
