// Core Data models representing metadata about TV shows and movies
import Foundation
import CoreData

/// Entity lookup for the model convenience initializers. Managed object subclass initializers are
/// nonisolated (they must match `NSManagedObject`'s designated initializer) and run off the main
/// actor when `TMDBService` maps API responses into unattached objects, so this goes through the
/// `nonisolated` compiled-model lookup rather than the live container.
nonisolated func managedEntity(named name: String) -> NSEntityDescription {
    PersistenceController.entity(named: name)
}

/// The context a new object should be inserted into: the caller's, else the context of the first
/// persisted object it is being related to. Core Data raises "relationship between objects in
/// different contexts" when a context-less object is related to a stored one, so a child (list
/// item, collection entry, transient detail wrapper) must join its target's context up front.
nonisolated func inferredContext(
    _ context: NSManagedObjectContext?,
    relating related: [NSManagedObject?]
) -> NSManagedObjectContext? {
    context ?? related.lazy.compactMap { $0?.managedObjectContext }.first
}

/// Puts `object` in the persistent store of the first related object that has one, so a child
/// created through context inference lands in the same store — and CloudKit zone — as its parent.
/// Objects with a temporary id and no store yet are skipped; `PersistenceController.insert` or
/// Core Data's own relationship-based inference covers those at save time.
nonisolated func assignToStore(of related: [NSManagedObject?], _ object: NSManagedObject) {
    guard let context = object.managedObjectContext else { return }
    for candidate in related {
        if let store = candidate?.objectID.persistentStore {
            context.assign(object, to: store)
            return
        }
    }
}

/// Model representing a network/streaming provider
@objc(Network)
final class Network: NSManagedObject {
    /// Network ID from TMDB
    @NSManaged var id: Int

    /// Network name (e.g., "Netflix", "HBO")
    @NSManaged var name: String

    /// Logo path from TMDB
    @NSManaged var logoPath: String?

    /// Origin country code
    @NSManaged var originCountry: String?

    // MARK: - Inverse relationships for CloudKit
    @NSManaged var movieSet: NSSet?
    @NSManaged var tvShowSet: NSSet?

    var movies: [Movie]? {
        get { (movieSet as? Set<Movie>).map(Array.init) }
        set { movieSet = newValue.map { NSSet(array: $0) } }
    }

    var tvShows: [TVShow]? {
        get { (tvShowSet as? Set<TVShow>).map(Array.init) }
        set { tvShowSet = newValue.map { NSSet(array: $0) } }
    }

    convenience init(
        id: Int = 0,
        name: String = "",
        logoPath: String? = nil,
        originCountry: String? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        self.init(entity: managedEntity(named: "Network"), insertInto: context)
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

extension MediaItemProtocol {
    /// See `displayOrderedNetworks(_:categories:)` — the deterministic display order for `networks`.
    var orderedNetworks: [Network] {
        displayOrderedNetworks(networks, categories: providerCategories)
    }
}

@objc(Movie)
final class Movie: NSManagedObject, MediaItemProtocol, Identifiable {
    /// Unique ID, such as MovieDB's identifier
    @NSManaged var id: String

    /// Title of the movie
    @NSManaged var title: String

    /// Optional thumbnail image URL
    @NSManaged var thumbnailURL: URL?

    /// TMDB backdrop path (16:9 artwork) used by the detail header. Optional so the
    /// CloudKit schema change stays additive.
    @NSManaged var backdropPath: String?

    /// Networks/streaming providers for this movie
    @NSManaged var networkSet: NSSet?

    /// Additional optional metadata
    @NSManaged var descriptionText: String?
    @NSManaged var castRaw: [String]?
    @NSManaged var castImagePathsRaw: [String]?
    @NSManaged var castCharactersRaw: [String]?
    @NSManaged var genresRaw: [String]?

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    @NSManaged var providerCategoriesRaw: [Int: String]?

    /// Content rating (e.g., "PG-13", "R")
    @NSManaged var contentRating: String?

    /// Release date in "YYYY-MM-DD" format (if known)
    @NSManaged var releaseDate: String?

    /// Runtime in minutes (specific to movies)
    @NSManaged var runtimeNumber: NSNumber?

    /// TMDB vote average (0–10)
    @NSManaged var voteAverageNumber: NSNumber?

    // MARK: - Inverse relationships for CloudKit
    @NSManaged var listItemSet: NSSet?
    @NSManaged var customListItemSet: NSSet?

    var networks: [Network]? {
        get { (networkSet as? Set<Network>).map(Array.init) }
        set { networkSet = newValue.map { NSSet(array: $0) } }
    }

    var cast: [String] {
        get { castRaw ?? [] }
        set { castRaw = newValue }
    }

    var castImagePaths: [String] {
        get { castImagePathsRaw ?? [] }
        set { castImagePathsRaw = newValue }
    }

    var castCharacters: [String] {
        get { castCharactersRaw ?? [] }
        set { castCharactersRaw = newValue }
    }

    var genres: [String] {
        get { genresRaw ?? [] }
        set { genresRaw = newValue }
    }

    var providerCategories: [Int: String] {
        get { providerCategoriesRaw ?? [:] }
        set { providerCategoriesRaw = newValue }
    }

    var runtime: Int? {
        get { runtimeNumber?.intValue }
        set { runtimeNumber = newValue.map(NSNumber.init(value:)) }
    }

    var voteAverage: Double? {
        get { voteAverageNumber?.doubleValue }
        set { voteAverageNumber = newValue.map(NSNumber.init(value:)) }
    }

    var listItems: [ListItem]? {
        get { (listItemSet as? Set<ListItem>).map(Array.init) }
        set { listItemSet = newValue.map { NSSet(array: $0) } }
    }

    var customListItems: [CustomListItem]? {
        get { (customListItemSet as? Set<CustomListItem>).map(Array.init) }
        set { customListItemSet = newValue.map { NSSet(array: $0) } }
    }

    convenience init(
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
        voteAverage: Double? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        self.init(entity: managedEntity(named: "Movie"), insertInto: context)
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

@objc(TVShow)
final class TVShow: NSManagedObject, MediaItemProtocol, Identifiable {
    /// Unique ID, such as MovieDB's identifier
    @NSManaged var id: String

    /// Title of the TV show
    @NSManaged var title: String

    /// Optional thumbnail image URL
    @NSManaged var thumbnailURL: URL?

    /// TMDB backdrop path (16:9 artwork) used by the detail header. Optional so the
    /// CloudKit schema change stays additive.
    @NSManaged var backdropPath: String?

    /// Networks/streaming providers for this TV show
    @NSManaged var networkSet: NSSet?

    /// Additional optional metadata
    @NSManaged var descriptionText: String?
    @NSManaged var castRaw: [String]?
    @NSManaged var castImagePathsRaw: [String]?
    @NSManaged var castCharactersRaw: [String]?
    @NSManaged var genresRaw: [String]?

    /// Provider ID → category ("stream", "ads", "rent", "buy")
    @NSManaged var providerCategoriesRaw: [Int: String]?

    /// Number of seasons (specific to TV shows)
    @NSManaged var numberOfSeasonsNumber: NSNumber?

    /// Number of episodes (specific to TV shows)
    @NSManaged var numberOfEpisodesNumber: NSNumber?

    /// Episode count per season (index 0 = season 1)
    @NSManaged var seasonEpisodeCountsRaw: [Int]?

    /// Season descriptions/overviews (index 0 = season 1)
    @NSManaged var seasonDescriptionsRaw: [String]?

    /// Average episode runtime in minutes
    @NSManaged var episodeRunTimeNumber: NSNumber?

    /// Content rating (e.g., "TV-MA", "TV-PG")
    @NSManaged var contentRating: String?

    /// Next episode air date in "YYYY-MM-DD" format (if the show is still airing)
    @NSManaged var nextEpisodeAirDate: String?

    /// Season / episode number and title of the next episode to air, when TMDB knows them
    @NSManaged var nextEpisodeSeasonNumber: NSNumber?
    @NSManaged var nextEpisodeNumberNumber: NSNumber?
    @NSManaged var nextEpisodeName: String?

    /// TMDB series status: "Returning Series", "Ended", "Canceled", "In Production", ...
    @NSManaged var status: String?

    /// TMDB vote average (0–10)
    @NSManaged var voteAverageNumber: NSNumber?

    // MARK: - Inverse relationships for CloudKit
    @NSManaged var listItemSet: NSSet?
    @NSManaged var customListItemSet: NSSet?

    var networks: [Network]? {
        get { (networkSet as? Set<Network>).map(Array.init) }
        set { networkSet = newValue.map { NSSet(array: $0) } }
    }

    var cast: [String] {
        get { castRaw ?? [] }
        set { castRaw = newValue }
    }

    var castImagePaths: [String] {
        get { castImagePathsRaw ?? [] }
        set { castImagePathsRaw = newValue }
    }

    var castCharacters: [String] {
        get { castCharactersRaw ?? [] }
        set { castCharactersRaw = newValue }
    }

    var genres: [String] {
        get { genresRaw ?? [] }
        set { genresRaw = newValue }
    }

    var providerCategories: [Int: String] {
        get { providerCategoriesRaw ?? [:] }
        set { providerCategoriesRaw = newValue }
    }

    var numberOfSeasons: Int? {
        get { numberOfSeasonsNumber?.intValue }
        set { numberOfSeasonsNumber = newValue.map(NSNumber.init(value:)) }
    }

    var numberOfEpisodes: Int? {
        get { numberOfEpisodesNumber?.intValue }
        set { numberOfEpisodesNumber = newValue.map(NSNumber.init(value:)) }
    }

    var seasonEpisodeCounts: [Int] {
        get { seasonEpisodeCountsRaw ?? [] }
        set { seasonEpisodeCountsRaw = newValue }
    }

    var seasonDescriptions: [String] {
        get { seasonDescriptionsRaw ?? [] }
        set { seasonDescriptionsRaw = newValue }
    }

    var episodeRunTime: Int? {
        get { episodeRunTimeNumber?.intValue }
        set { episodeRunTimeNumber = newValue.map(NSNumber.init(value:)) }
    }

    var nextEpisodeSeason: Int? {
        get { nextEpisodeSeasonNumber?.intValue }
        set { nextEpisodeSeasonNumber = newValue.map(NSNumber.init(value:)) }
    }

    var nextEpisodeNumber: Int? {
        get { nextEpisodeNumberNumber?.intValue }
        set { nextEpisodeNumberNumber = newValue.map(NSNumber.init(value:)) }
    }

    var voteAverage: Double? {
        get { voteAverageNumber?.doubleValue }
        set { voteAverageNumber = newValue.map(NSNumber.init(value:)) }
    }

    var listItems: [ListItem]? {
        get { (listItemSet as? Set<ListItem>).map(Array.init) }
        set { listItemSet = newValue.map { NSSet(array: $0) } }
    }

    var customListItems: [CustomListItem]? {
        get { (customListItemSet as? Set<CustomListItem>).map(Array.init) }
        set { customListItemSet = newValue.map { NSSet(array: $0) } }
    }

    convenience init(
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
        voteAverage: Double? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        self.init(entity: managedEntity(named: "TVShow"), insertInto: context)
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

// MARK: - Canonical row lookup

/// The stored `Movie` row for a TMDB id, if there is one. There should only ever be a single row
/// per id — the watchlist and every custom list share it — but older installs can hold duplicates,
/// so the row the library refers to (the one with `listItems`) wins.
func existingMovie(id: String, in context: NSManagedObjectContext) -> Movie? {
    let request = NSFetchRequest<Movie>(entityName: "Movie")
    request.predicate = NSPredicate(format: "id == %@", id)
    guard let matches = try? context.fetch(request), !matches.isEmpty else { return nil }
    return matches.first { !($0.listItems ?? []).isEmpty } ?? matches.first
}

/// The stored `TVShow` row for a TMDB id, if there is one. See `existingMovie(id:in:)`.
func existingTVShow(id: String, in context: NSManagedObjectContext) -> TVShow? {
    let request = NSFetchRequest<TVShow>(entityName: "TVShow")
    request.predicate = NSPredicate(format: "id == %@", id)
    guard let matches = try? context.fetch(request), !matches.isEmpty else { return nil }
    return matches.first { !($0.listItems ?? []).isEmpty } ?? matches.first
}

/// A row mapped straight from a TMDB *search* result carries no cast, genres or runtime. Applying
/// one over a fully-fetched row would blank real metadata, so those updates are skipped.
private func hasFullDetail(_ movie: Movie) -> Bool {
    !movie.cast.isEmpty || !movie.genres.isEmpty || movie.runtime != nil
}

/// See `hasFullDetail(_: Movie)`.
private func hasFullDetail(_ tvShow: TVShow) -> Bool {
    !tvShow.cast.isEmpty || !tvShow.genres.isEmpty || tvShow.numberOfSeasons != nil
}

/// Returns the stored row for `movie`'s id — refreshed from `movie` — or `movie` itself when the
/// title isn't stored yet. Callers attach their new list item to the result so a title never ends
/// up with two media rows. When `movie` isn't stored yet, it (and its networks) are inserted into
/// `context` and assigned to the active store so the caller doesn't have to.
@MainActor
func canonicalMovieRow(for movie: Movie, in context: NSManagedObjectContext) -> Movie {
    guard let existing = existingMovie(id: movie.id, in: context), existing !== movie else {
        if movie.managedObjectContext == nil {
            context.insert(movie)
            for network in movie.networks ?? [] where network.managedObjectContext == nil {
                context.insert(network)
                context.assign(network, to: PersistenceController.shared.activeStore)
            }
            context.assign(movie, to: PersistenceController.shared.activeStore)
        }
        return movie
    }
    if hasFullDetail(movie) || !hasFullDetail(existing) {
        existing.update(from: movie)
    }
    return existing
}

/// See `canonicalMovieRow(for:in:)`.
@MainActor
func canonicalTVShowRow(for tvShow: TVShow, in context: NSManagedObjectContext) -> TVShow {
    guard let existing = existingTVShow(id: tvShow.id, in: context), existing !== tvShow else {
        if tvShow.managedObjectContext == nil {
            context.insert(tvShow)
            for network in tvShow.networks ?? [] where network.managedObjectContext == nil {
                context.insert(network)
                context.assign(network, to: PersistenceController.shared.activeStore)
            }
            context.assign(tvShow, to: PersistenceController.shared.activeStore)
        }
        return tvShow
    }
    if hasFullDetail(tvShow) || !hasFullDetail(existing) {
        existing.update(from: tvShow)
    }
    return existing
}

// MARK: - Shared cleanup helpers

/// True when two network lists describe the same providers. `TMDBService` builds brand-new
/// `Network` instances on every fetch, so identity comparison would always report a change.
/// Compared by id order — the stored side comes from an unordered to-many relationship.
private func networksAreEquivalent(_ lhs: [Network]?, _ rhs: [Network]?) -> Bool {
    let left = (lhs ?? []).sorted { $0.id < $1.id }
    let right = (rhs ?? []).sorted { $0.id < $1.id }
    guard left.count == right.count else { return false }
    return zip(left, right).allSatisfy { a, b in
        a.id == b.id && a.name == b.name && a.logoPath == b.logoPath
    }
}

/// Inserts freshly-mapped (`managedObjectContext == nil`) networks into `context` and assigns them
/// to the active store, so they can be related to a persisted media row. No-op for stored rows.
@MainActor
private func insertUnattachedNetworks(_ networks: [Network]?, into context: NSManagedObjectContext?) {
    guard let context, let networks else { return }
    for network in networks where network.managedObjectContext == nil {
        context.insert(network)
        context.assign(network, to: PersistenceController.shared.activeStore)
    }
}

/// Deletes the `Network` rows in `networks` that nothing other than `ownerID` refers to. Without
/// this they pile up as orphans (and CloudKit records) every time metadata is refreshed.
func deleteUnreferencedNetworks(
    _ networks: [Network]?,
    excludingOwner ownerID: NSManagedObjectID,
    in context: NSManagedObjectContext
) {
    guard let networks else { return }
    for network in networks {
        let stillReferenced = (network.movies ?? []).contains { $0.objectID != ownerID }
            || (network.tvShows ?? []).contains { $0.objectID != ownerID }
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
    ownerID: NSManagedObjectID,
    in context: NSManagedObjectContext?
) -> [Network]?? {
    guard !networksAreEquivalent(current, incoming) else { return nil }
    if let context {
        deleteUnreferencedNetworks(current, excludingOwner: ownerID, in: context)
    }
    return .some(incoming)
}

// MARK: - Display ordering

/// Stable display order for a media row's networks. `networks` is an unordered Core Data
/// relationship, so without this the logos reshuffle on every render. Streaming first, then
/// ads, rent, buy; alphabetical within a category so the order never depends on fetch order.
/// CloudKit can merge distinct Network records with the same provider ID into the relationship.
/// Collapse those before callers filter, truncate, or count providers, including cached data.
func displayOrderedNetworks(_ networks: [Network]?, categories: [Int: String]) -> [Network] {
    func rank(_ network: Network) -> Int {
        switch categories[network.id] {
        case "stream": return 0
        case "ads": return 1
        case "rent": return 2
        case "buy": return 3
        default: return 4
        }
    }
    // Prefer a record with a logo when duplicate records contain different cached metadata.
    let candidates = (networks ?? []).sorted { a, b in
        let aHasLogo = !(a.logoPath ?? "").isEmpty
        let bHasLogo = !(b.logoPath ?? "").isEmpty
        if aHasLogo != bHasLogo { return aHasLogo }
        if a.name != b.name { return a.name < b.name }
        return (a.logoPath ?? "") < (b.logoPath ?? "")
    }
    var seenIDs = Set<Int>()
    return candidates.filter { seenIDs.insert($0.id).inserted }.sorted { a, b in
        let rankA = rank(a)
        let rankB = rank(b)
        if rankA != rankB { return rankA < rankB }
        let nameOrder = a.name.localizedCaseInsensitiveCompare(b.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return a.id < b.id
    }
}

/// Deletes a `Movie`/`TVShow` row — plus any networks only it referred to — once nothing points at
/// it any more. `deletedItemID` is the list item that was just deleted; it can linger in the
/// inverse relationships until the context is saved, so it's filtered out.
func deleteMediaIfUnreferenced(
    movie: Movie?,
    tvShow: TVShow?,
    ignoring deletedItemID: NSManagedObjectID,
    in context: NSManagedObjectContext
) {
    if let movie {
        let stillReferenced = (movie.listItems ?? []).contains { $0.objectID != deletedItemID }
            || (movie.customListItems ?? []).contains { $0.objectID != deletedItemID }
        if !stillReferenced {
            deleteUnreferencedNetworks(movie.networks, excludingOwner: movie.objectID, in: context)
            context.delete(movie)
        }
    }
    if let tvShow {
        let stillReferenced = (tvShow.listItems ?? []).contains { $0.objectID != deletedItemID }
            || (tvShow.customListItems ?? []).contains { $0.objectID != deletedItemID }
        if !stillReferenced {
            deleteUnreferencedNetworks(tvShow.networks, excludingOwner: tvShow.objectID, in: context)
            context.delete(tvShow)
        }
    }
}

extension Movie {
    /// Applies all TMDB-sourced fields from a freshly-fetched instance.
    /// Add new TMDB fields here — this is the single place to keep in sync.
    @MainActor
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
            ownerID: objectID,
            in: managedObjectContext
        ) {
            // Only now do the incoming rows become real — inserting them before knowing the
            // providers changed would leave orphan Network rows (and CloudKit records) behind.
            insertUnattachedNetworks(replacement, into: managedObjectContext)
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
    @MainActor
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
            ownerID: objectID,
            in: managedObjectContext
        ) {
            // See `Movie.update(from:)` — insert only once we know the providers changed.
            insertUnattachedNetworks(replacement, into: managedObjectContext)
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

    /// Seasons that can actually be watched right now. TMDB lists a season the moment it's announced —
    /// zero episodes, or episodes dated months out — and counting it would drag a caught-up show back
    /// into Up Next with nothing to watch. A season is available when it has episodes and has started
    /// airing; `next_episode_to_air` pointing at its episode 1 means it hasn't.
    var availableSeasonCount: Int {
        let total = numberOfSeasons ?? 0
        guard total > 0 else { return 0 }

        var highest = 0
        for season in 1...total {
            // Search-stub rows carry no per-season data — treat those seasons as available so thin
            // data never behaves worse than it does today.
            if seasonEpisodeCounts.count >= season, seasonEpisodeCounts[season - 1] <= 0 { continue }
            // The next episode to air being this season's premiere means the season hasn't started;
            // anything past the season that episode belongs to hasn't either.
            if nextEpisodeSeason == season, nextEpisodeNumber == 1 { continue }
            if let nextSeason = nextEpisodeSeason, season > nextSeason { continue }
            highest = season
        }
        return highest
    }

    /// The first season that exists but isn't watchable yet, or nil when every season is available.
    var announcedSeasonNumber: Int? {
        let total = numberOfSeasons ?? 0
        let available = availableSeasonCount
        return available < total ? available + 1 : nil
    }

    /// The announced season's premiere date, when TMDB has scheduled one.
    var announcedSeasonPremiere: String? {
        guard let announced = announcedSeasonNumber, nextEpisodeSeason == announced else { return nil }
        return nextEpisodeAirDate
    }

    /// User-facing summary of seasons and episodes for display
    var seasonsEpisodesSummary: String? {
        guard let seasons = numberOfSeasons else { return nil }

        let seasonsLabel = seasons == 1 ? "1 Season" : "\(seasons) Seasons"
        guard let episodes = numberOfEpisodes else { return seasonsLabel }

        let episodesLabel = episodes == 1 ? "1 Episode" : "\(episodes) Episodes"
        return "\(seasonsLabel) \u{00B7} \(episodesLabel)"
    }
}
