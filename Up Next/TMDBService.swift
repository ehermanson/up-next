import Foundation
import SwiftData

/// Service for interacting with The Movie Database (TMDB) API
final class TMDBService {
    static let shared = TMDBService()

    private let baseURL = "https://api.themoviedb.org/3"
    private let imageBaseURL = "https://image.tmdb.org/t/p"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Cache for provider availability checks (keyed by "movie_123" or "tv_456")
    private var providerAvailabilityCache: [String: ProviderAvailability] = [:]

    private var apiKey: String {
        guard let key = Bundle.main.infoDictionary?["TMDB_API_KEY"] as? String,
            key != "YOUR_API_KEY_HERE"
        else {
            assertionFailure("TMDB_API_KEY not found in Info.plist or not configured")
            return ""
        }
        return key
    }

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
            queryItems: [URLQueryItem(name: "append_to_response", value: "credits")]
        )
    }

    /// Get detailed information for a movie
    func getMovieDetails(id: Int) async throws -> TMDBMovieDetail {
        let endpoint = "/movie/\(id)"
        return try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "append_to_response", value: "credits")]
        )
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
    /// Deduplicates by provider ID and sorts by provider name.
    func fetchWatchProviders(for region: String? = nil) async throws -> [TMDBWatchProviderInfo] {
        let regionCode = region ?? currentRegion

        let movieProviders: TMDBWatchProviderListResponse = try await performRequest(
            endpoint: "/watch/providers/movie",
            queryItems: [URLQueryItem(name: "watch_region", value: regionCode)]
        )

        let tvProviders: TMDBWatchProviderListResponse = try await performRequest(
            endpoint: "/watch/providers/tv",
            queryItems: [URLQueryItem(name: "watch_region", value: regionCode)]
        )

        // Curated list of streaming subscription services
        // These are services people actually subscribe to - no rent/buy stores
        let streamingProviderIDs: Set<Int> = [
            8,      // Netflix
            9,      // Amazon Prime Video
            337,    // Disney Plus
            1899,   // Max
            15,     // Hulu
            2303,   // Paramount+
            386,    // Peacock
            350,    // Apple TV+
            43,     // Starz
            526,    // AMC+
            283,    // Crunchyroll
            73,     // Tubi (free)
            300,    // Pluto TV (free)
        ]

        // Merge and deduplicate, only keeping whitelisted providers
        var seenIds = Set<Int>()
        var merged: [TMDBWatchProviderInfo] = []

        for provider in movieProviders.results + tvProviders.results {
            guard !seenIds.contains(provider.providerId) else { continue }
            guard streamingProviderIDs.contains(provider.providerId) else { continue }

            seenIds.insert(provider.providerId)
            merged.append(provider)
        }

        // Sort alphabetically
        return merged.sorted {
            $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
        }
    }

    // MARK: - Provider Availability Check

    /// Result of checking provider availability for a media item
    struct ProviderAvailability: Sendable {
        let providerIDs: Set<Int>
        let isOnUserServices: Bool
    }

    /// Check if a media item is available on user's selected streaming services.
    /// Results are cached to avoid redundant API calls.
    func checkProviderAvailability(mediaId: Int, mediaType: MediaType) async -> ProviderAvailability {
        let cacheKey = "\(mediaType == .tvShow ? "tv" : "movie")_\(mediaId)"

        // Return cached result if available
        if let cached = providerAvailabilityCache[cacheKey] {
            return cached
        }

        // Fetch provider info
        var providerIDs = Set<Int>()
        do {
            let providers: TMDBWatchProviderCountry?
            if mediaType == .tvShow {
                providers = try await getTVShowWatchProviders(id: mediaId)
            } else {
                providers = try await getMovieWatchProviders(id: mediaId)
            }

            // Collect all provider IDs from all categories
            if let p = providers {
                providerIDs.formUnion(p.flatrate?.map(\.providerId) ?? [])
                providerIDs.formUnion(p.ads?.map(\.providerId) ?? [])
                providerIDs.formUnion(p.rent?.map(\.providerId) ?? [])
                providerIDs.formUnion(p.buy?.map(\.providerId) ?? [])
            }
        } catch {
            // On error, return empty (we'll show as unavailable)
        }

        // Check against user's selected providers
        let selectedIDs = ProviderSettings.shared.selectedProviderIDs
        let isOnUserServices = !selectedIDs.isEmpty && !providerIDs.isDisjoint(with: selectedIDs)

        let result = ProviderAvailability(providerIDs: providerIDs, isOnUserServices: isOnUserServices)
        providerAvailabilityCache[cacheKey] = result
        return result
    }

    /// Clear the provider availability cache (e.g., when user changes provider selections)
    func clearProviderAvailabilityCache() {
        providerAvailabilityCache.removeAll()
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
            numberOfEpisodes: nil
        )
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
            seasonEpisodeCounts: seasonEpisodeCounts
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
            runtime: nil
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
            releaseDate: detail.releaseDate,
            runtime: detail.runtime
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

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TMDBError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw TMDBError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingError(error)
        }
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
