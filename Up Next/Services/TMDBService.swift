import Foundation
import SwiftData

/// Service for interacting with The Movie Database (TMDB) API
/// All stored properties are either `let` values or actor-isolated caches,
/// so cross-isolation capture is safe.
final class TMDBService: @unchecked Sendable {
    static let shared = TMDBService()

    private let baseURL = "https://api.themoviedb.org/3"
    private let imageBaseURL = "https://image.tmdb.org/t/p"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let apiKey: String = {
        guard let key = Bundle.main.infoDictionary?["TMDB_API_KEY"] as? String,
            key != "YOUR_API_KEY_HERE"
        else {
            assertionFailure("TMDB_API_KEY not found in Info.plist or not configured")
            return ""
        }
        return key
    }()

    private init() {}

    /// Returns the user's region code (e.g., "US", "GB", "DE") for watch provider lookups.
    /// Falls back to "US" if the device locale doesn't provide a region.
    var currentRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    // MARK: - Search

    /// Search for TV shows by name
    func searchTVShows(query: String) async throws -> [TMDBTVShowSearchResult] {
        let endpoint = "/search/tv"
        let response: TMDBTVShowSearchResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
        return response.results
    }

    /// Search for movies by name
    func searchMovies(query: String) async throws -> [TMDBMovieSearchResult] {
        let endpoint = "/search/movie"
        let response: TMDBMovieSearchResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
        return response.results
    }

    // MARK: - Details

    /// Get detailed information for a TV show
    func getTVShowDetails(id: Int) async throws -> TMDBTVShowDetail {
        let endpoint = "/tv/\(id)"
        return try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "append_to_response", value: "credits,content_ratings,videos,similar,recommendations,watch/providers")]
        )
    }

    /// Get detailed information for a movie
    func getMovieDetails(id: Int) async throws -> TMDBMovieDetail {
        let endpoint = "/movie/\(id)"
        return try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "append_to_response", value: "credits,release_dates,videos,similar,recommendations,watch/providers")]
        )
    }

    // MARK: - Recommendations

    /// Get recommended TV shows based on a specific TV show
    func fetchTVRecommendations(id: Int) async throws -> [TMDBTVShowSearchResult] {
        let response: TMDBTVShowSearchResponse = try await performRequest(
            endpoint: "/tv/\(id)/recommendations", queryItems: []
        )
        return response.results
    }

    /// Get recommended movies based on a specific movie
    func fetchMovieRecommendations(id: Int) async throws -> [TMDBMovieSearchResult] {
        let response: TMDBMovieSearchResponse = try await performRequest(
            endpoint: "/movie/\(id)/recommendations", queryItems: []
        )
        return response.results
    }

    /// Get details for a movie collection (e.g. "Dune Collection")
    func getCollectionDetails(id: Int) async throws -> TMDBCollectionDetail {
        let endpoint = "/collection/\(id)"
        return try await performRequest(endpoint: endpoint, queryItems: [])
    }

    /// Get watch providers for a movie (per country). Uses device locale by default.
    func getMovieWatchProviders(id: Int, countryCode: String? = nil) async throws
        -> TMDBWatchProviderCountry?
    {
        let region = countryCode ?? currentRegion
        let endpoint = "/movie/\(id)/watch/providers"
        let response: TMDBWatchProvidersResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: []
        )
        return response.results?[region]
    }

    /// Get watch providers for a TV show (per country). Uses device locale by default.
    func getTVShowWatchProviders(id: Int, countryCode: String? = nil) async throws
        -> TMDBWatchProviderCountry?
    {
        let region = countryCode ?? currentRegion
        let endpoint = "/tv/\(id)/watch/providers"
        let response: TMDBWatchProvidersResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: []
        )
        return response.results?[region]
    }

    /// Fetch all available watch providers for a region, merged from movie and TV endpoints.
    /// Filters out channel variants and known rent/buy storefronts, then sorts by TMDB display priority.
    func fetchWatchProviders(for region: String? = nil) async throws -> [TMDBWatchProviderInfo] {
        let regionCode = region ?? currentRegion

        async let movieProvidersTask: TMDBWatchProviderListResponse = performRequest(
            endpoint: "/watch/providers/movie",
            queryItems: [URLQueryItem(name: "watch_region", value: regionCode)]
        )

        async let tvProvidersTask: TMDBWatchProviderListResponse = performRequest(
            endpoint: "/watch/providers/tv",
            queryItems: [URLQueryItem(name: "watch_region", value: regionCode)]
        )

        let (movieProviders, tvProviders) = try await (movieProvidersTask, tvProvidersTask)

        // Storefront-style rent/buy-only providers that should not appear in the selection grid.
        let rentBuyOnlyProviderIDs: Set<Int> = [
            2,      // Apple iTunes
            3,      // Google Play Movies
            7,      // Vudu
            10,     // Amazon Video
            68,     // Microsoft Store
            192,    // YouTube
            652,    // Apple TV
        ]

        var seenIds = Set<Int>()
        var seenNames = Set<String>()
        var merged: [TMDBWatchProviderInfo] = []

        for provider in movieProviders.results + tvProviders.results {
            guard !seenIds.contains(provider.providerId) else { continue }
            guard !rentBuyOnlyProviderIDs.contains(provider.providerId) else { continue }

            let isChannelVariant = Self.channelSuffixes.contains { provider.providerName.hasSuffix($0) }
            guard !isChannelVariant else { continue }

            let canonicalName = Self.providerAliases[provider.providerName] ?? provider.providerName
            guard !seenNames.contains(canonicalName) else { continue }

            seenIds.insert(provider.providerId)
            seenNames.insert(canonicalName)

            if canonicalName == provider.providerName {
                merged.append(provider)
            } else {
                merged.append(TMDBWatchProviderInfo(
                    providerId: provider.providerId,
                    providerName: canonicalName,
                    logoPath: provider.logoPath,
                    displayPriority: provider.displayPriority
                ))
            }
        }

        // TMDB lower display_priority means higher prominence.
        return merged.sorted {
            let leftPriority = $0.displayPriority ?? Int.max
            let rightPriority = $1.displayPriority ?? Int.max
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
        }
    }

    /// Clear the response cache to force fresh data on next request
    func clearResponseCache() async {
        await deduplicator.clearCache()
    }

    // MARK: - Image URLs

    /// Construct full image URL from TMDB image path
    func imageURL(path: String?, size: ImageSize = .w500) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(imageBaseURL)/\(size.rawValue)/\(cleanPath)")
    }

    enum ImageSize: String {
        case w92 = "w92"
        case w154 = "w154"
        case w185 = "w185"
        case w342 = "w342"
        case w500 = "w500"
        case w780 = "w780"
        case original = "original"
    }

    // MARK: - Mapping Helpers

    /// Convert TMDB network to Network model
    func mapToNetwork(_ network: TMDBNetwork) -> Network {
        Network(
            id: network.id,
            name: network.name,
            logoPath: network.logoPath,
            originCountry: network.originCountry
        )
    }

    /// Convert TMDB TV show search result to TVShow model
    func mapToTVShow(_ result: TMDBTVShowSearchResult) -> TVShow {
        TVShow(
            id: String(result.id),
            title: result.name,
            thumbnailURL: imageURL(path: result.posterPath),
            networks: [],
            descriptionText: result.overview,
            cast: [],
            numberOfSeasons: nil,
            numberOfEpisodes: nil,
            voteAverage: result.voteAverage
        )
    }

    /// Extract the content rating for the user's region from a TV show detail response
    private func extractTVContentRating(from detail: TMDBTVShowDetail) -> String? {
        guard let ratings = detail.contentRatings?.results else { return nil }
        let region = currentRegion
        if let match = ratings.first(where: { $0.iso31661 == region }), !match.rating.isEmpty {
            return match.rating
        }
        if region != "US", let us = ratings.first(where: { $0.iso31661 == "US" }), !us.rating.isEmpty {
            return us.rating
        }
        return nil
    }

    /// Extract the certification for the user's region from a movie detail response
    private func extractMovieCertification(from detail: TMDBMovieDetail) -> String? {
        guard let countries = detail.releaseDates?.results else { return nil }
        let region = currentRegion
        func certification(for countryCode: String) -> String? {
            guard let country = countries.first(where: { $0.iso31661 == countryCode }) else { return nil }
            return country.releaseDates?.first(where: { $0.certification?.isEmpty == false })?.certification
        }
        if let cert = certification(for: region) { return cert }
        if region != "US", let cert = certification(for: "US") { return cert }
        return nil
    }

    /// Convert TMDB TV show detail + optional watch providers to TVShow model
    func mapToTVShow(_ detail: TMDBTVShowDetail, providers: TMDBWatchProviderCountry? = nil) -> TVShow {
        let castMembers = detail.credits?.cast?.prefix(10) ?? []
        let cast = castMembers.map { $0.name }
        let castImagePaths = castMembers.map { $0.profilePath ?? "" }
        let castCharacters = castMembers.map { $0.character ?? "" }
        let genres = detail.genres?.map { $0.name } ?? []

        // Build per-season episode counts (skip specials with seasonNumber == 0)
        let seasonEpisodeCounts: [Int] = {
            guard let seasons = detail.seasons else { return [] }
            let numbered = seasons
                .filter { $0.seasonNumber > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            return numbered.map { $0.episodeCount ?? 0 }
        }()

        // Start with watch providers (using provider IDs which match user selections)
        let (watchNetworks, watchCategories) = mapProviders(providers)
        var seenNames = Set<String>()
        var categories: [Int: String] = [:]
        var allNetworks: [Network] = []

        // Build lookup for provider logos by ID
        var providerLogos: [Int: String] = [:]
        for network in watchNetworks {
            if let logo = network.logoPath {
                providerLogos[network.id] = logo
            }
        }

        for network in watchNetworks {
            guard !seenNames.contains(network.name) else { continue }
            seenNames.insert(network.name)
            allNetworks.append(network)
            categories[network.id] = watchCategories[network.id] ?? "stream"
        }

        // Add originating networks only if not already covered by watch providers
        for tmdbNetwork in detail.networks ?? [] {
            let canonical = Self.providerAliases[tmdbNetwork.name] ?? tmdbNetwork.name
            guard !seenNames.contains(canonical) else { continue }
            seenNames.insert(canonical)
            // Use provider ID if known, otherwise fall back to network ID
            let networkID = Self.networkToProviderID[tmdbNetwork.name] ?? tmdbNetwork.id
            // Prefer the streaming provider's logo if we have it
            let logoPath = providerLogos[networkID] ?? tmdbNetwork.logoPath
            let network = Network(
                id: networkID,
                name: canonical,
                logoPath: logoPath,
                originCountry: tmdbNetwork.originCountry
            )
            allNetworks.append(network)
            categories[network.id] = "stream"
        }

        return TVShow(
            id: String(detail.id),
            title: detail.name,
            thumbnailURL: imageURL(path: detail.posterPath),
            networks: allNetworks,
            descriptionText: detail.overview,
            cast: cast,
            castImagePaths: castImagePaths,
            castCharacters: castCharacters,
            genres: genres,
            providerCategories: categories,
            numberOfSeasons: detail.numberOfSeasons,
            numberOfEpisodes: detail.numberOfEpisodes,
            seasonEpisodeCounts: seasonEpisodeCounts,
            contentRating: extractTVContentRating(from: detail),
            episodeRunTime: detail.episodeRunTime?.first,
            nextEpisodeAirDate: detail.nextEpisodeToAir?.airDate,
            voteAverage: detail.voteAverage
        )
    }

    /// Convert TMDB movie search result to Movie model
    func mapToMovie(_ result: TMDBMovieSearchResult) -> Movie {
        Movie(
            id: String(result.id),
            title: result.title,
            thumbnailURL: imageURL(path: result.posterPath),
            networks: [],
            descriptionText: result.overview,
            cast: [],
            releaseDate: result.releaseDate,
            runtime: nil,
            voteAverage: result.voteAverage
        )
    }

    /// Suffixes that indicate a resold channel variant (e.g. "HBO Max Amazon Channel").
    private static let channelSuffixes = [" Amazon Channel", " Apple TV Channel", " Roku Premium Channel"]

    /// Maps originating network names to their streaming provider IDs.
    /// Used when a show's network (e.g., "AMC") should match the user's selected provider (e.g., AMC+ ID 526).
    private static let networkToProviderID: [String: Int] = [
        "AMC": 526,         // AMC network → AMC+ provider
        "AMC+": 526,
        "HBO": 1899,        // HBO network → HBO Max provider
        "HBO Max": 1899,
        "Max": 1899,
    ]

    /// Maps variant provider names to a canonical name so duplicates collapse.
    /// The first entry encountered keeps its ID, logo, and category.
    private static let providerAliases: [String: String] = [
        // Netflix tiers
        "Netflix basic with Ads": "Netflix",
        "Netflix Standard with Ads": "Netflix",
        // Peacock tiers
        "Peacock Premium": "Peacock",
        "Peacock Premium Plus": "Peacock",
        // HBO/Max
        "HBO": "HBO Max",
        "Max": "HBO Max",
        "Max Amazon Channel": "HBO Max",
        // Disney
        "Disney Plus": "Disney+",
        // AMC
        "AMC": "AMC+",
        "AMC+ Roku Premium Channel": "AMC+",
        "AMC Plus": "AMC+",
        // Paramount
        "Paramount+ Premium": "Paramount+",
        "Paramount Plus Premium": "Paramount+",
        "Paramount Plus": "Paramount+",
        "Paramount+ Amazon Channel": "Paramount+",
        // Hulu
        "Hulu (No Ads)": "Hulu",
        // Amazon
        "Amazon Prime Video": "Prime Video",
        "Amazon Prime Video with Ads": "Prime Video",
    ]

    /// Build networks and provider categories from a watch provider response.
    /// Priority: flatrate > ads > rent > buy (first occurrence wins).
    /// Filters out resold channel variants and merges known aliases.
    func mapProviders(_ providers: TMDBWatchProviderCountry?) -> (networks: [Network], categories: [Int: String]) {
        guard let providers else { return ([], [:]) }

        let categorized: [(String, [TMDBWatchProviderEntry])] = [
            ("stream", providers.flatrate ?? []),
            ("ads", providers.ads ?? []),
            ("rent", providers.rent ?? []),
            ("buy", providers.buy ?? []),
        ]

        var seenIDs = Set<Int>()
        var seenNames = Set<String>()
        var networks: [Network] = []
        var categories: [Int: String] = [:]

        for (category, entries) in categorized {
            for entry in entries {
                guard !seenIDs.contains(entry.providerId) else { continue }
                let isChannel = Self.channelSuffixes.contains { entry.providerName.hasSuffix($0) }
                guard !isChannel else { continue }

                let canonicalName = Self.providerAliases[entry.providerName] ?? entry.providerName
                guard !seenNames.contains(canonicalName) else { continue }

                seenIDs.insert(entry.providerId)
                seenNames.insert(canonicalName)
                networks.append(Network(
                    id: entry.providerId,
                    name: canonicalName,
                    logoPath: entry.logoPath,
                    originCountry: "US"
                ))
                categories[entry.providerId] = category
            }
        }

        return (networks, categories)
    }

    /// Convert TMDB movie detail + watch providers to Movie model
    func mapToMovie(_ detail: TMDBMovieDetail, providers: TMDBWatchProviderCountry?) -> Movie {
        let castMembers = detail.credits?.cast?.prefix(10) ?? []
        let cast = castMembers.map { $0.name }
        let castImagePaths = castMembers.map { $0.profilePath ?? "" }
        let castCharacters = castMembers.map { $0.character ?? "" }
        let (networks, categories) = mapProviders(providers)
        let genres = detail.genres?.map { $0.name } ?? []

        return Movie(
            id: String(detail.id),
            title: detail.title,
            thumbnailURL: imageURL(path: detail.posterPath),
            networks: networks,
            descriptionText: detail.overview,
            cast: cast,
            castImagePaths: castImagePaths,
            castCharacters: castCharacters,
            genres: genres,
            providerCategories: categories,
            contentRating: extractMovieCertification(from: detail),
            releaseDate: detail.releaseDate,
            runtime: detail.runtime,
            voteAverage: detail.voteAverage
        )
    }

    // MARK: - Discover

    /// Discover TV shows with optional filters
    func discoverTVShows(
        page: Int = 1,
        sortBy: String = "popularity.desc",
        withGenres: String? = nil,
        withWatchProviders: String? = nil,
        watchRegion: String? = nil,
        voteCountGte: Int? = nil
    ) async throws -> TMDBTVShowSearchResponse {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: sortBy),
        ]
        if let withGenres {
            queryItems.append(URLQueryItem(name: "with_genres", value: withGenres))
        }
        if let withWatchProviders {
            queryItems.append(URLQueryItem(name: "with_watch_providers", value: withWatchProviders))
            queryItems.append(URLQueryItem(name: "watch_region", value: watchRegion ?? currentRegion))
            queryItems.append(URLQueryItem(name: "with_watch_monetization_types", value: "flatrate|free|ads"))
        }
        if let voteCountGte {
            queryItems.append(URLQueryItem(name: "vote_count.gte", value: String(voteCountGte)))
        }
        return try await performRequest(endpoint: "/discover/tv", queryItems: queryItems)
    }

    /// Discover movies with optional filters
    func discoverMovies(
        page: Int = 1,
        sortBy: String = "popularity.desc",
        withGenres: String? = nil,
        withWatchProviders: String? = nil,
        watchRegion: String? = nil,
        voteCountGte: Int? = nil
    ) async throws -> TMDBMovieSearchResponse {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: sortBy),
        ]
        if let withGenres {
            queryItems.append(URLQueryItem(name: "with_genres", value: withGenres))
        }
        if let withWatchProviders {
            queryItems.append(URLQueryItem(name: "with_watch_providers", value: withWatchProviders))
            queryItems.append(URLQueryItem(name: "watch_region", value: watchRegion ?? currentRegion))
            queryItems.append(URLQueryItem(name: "with_watch_monetization_types", value: "flatrate|free|ads"))
        }
        if let voteCountGte {
            queryItems.append(URLQueryItem(name: "vote_count.gte", value: String(voteCountGte)))
        }
        return try await performRequest(endpoint: "/discover/movie", queryItems: queryItems)
    }

    /// Fetch TV show genres
    func fetchTVGenres() async throws -> [TMDBGenre] {
        let response: TMDBGenreListResponse = try await performRequest(
            endpoint: "/genre/tv/list", queryItems: []
        )
        return response.genres
    }

    /// Fetch movie genres
    func fetchMovieGenres() async throws -> [TMDBGenre] {
        let response: TMDBGenreListResponse = try await performRequest(
            endpoint: "/genre/movie/list", queryItems: []
        )
        return response.genres
    }

    // MARK: - Private Helpers

    private let deduplicator = RequestDeduplicator()

    private func performRequest<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(endpoint)")
        var items = queryItems
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        components?.queryItems = items

        guard let url = components?.url else {
            throw TMDBError.invalidURL
        }

        let data = try await deduplicator.deduplicated(for: url) {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TMDBError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw TMDBError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingError(error)
        }
    }
}

private actor RequestDeduplicator {
    private var inFlight: [URL: Task<Data, any Error>] = [:]
    private var cache: [URL: CachedResponse] = [:]

    private struct CachedResponse {
        let data: Data
        let timestamp: Date
    }

    /// Default time-to-live for cached responses (10 minutes)
    private let ttl: TimeInterval = 600

    func deduplicated(for url: URL, perform: @Sendable @escaping () async throws -> Data) async throws -> Data {
        // Return cached response if within TTL
        if let cached = cache[url], Date().timeIntervalSince(cached.timestamp) < ttl {
            return cached.data
        }

        // Coalesce concurrent requests for the same URL
        if let existing = inFlight[url] {
            return try await existing.value
        }

        let task = Task { try await perform() }
        inFlight[url] = task
        defer { inFlight.removeValue(forKey: url) }

        let data = try await task.value
        cache[url] = CachedResponse(data: data, timestamp: Date())
        return data
    }

    func clearCache() {
        cache.removeAll()
    }
}

enum TMDBError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}
