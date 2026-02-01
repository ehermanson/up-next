import Foundation
import SwiftData

/// Service for interacting with The Movie Database (TMDB) API
actor TMDBService {
    static let shared = TMDBService()

    private let baseURL = "https://api.themoviedb.org/3"
    private let imageBaseURL = "https://image.tmdb.org/t/p"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private var apiKey: String {
        guard let key = Bundle.main.infoDictionary?["TMDB_API_KEY"] as? String,
            key != "YOUR_API_KEY_HERE"
        else {
            fatalError("TMDB_API_KEY not found in Info.plist or not configured")
        }
        return key
    }

    private init() {}

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

    /// Get watch providers for a movie (per country). Returns the US entry when available.
    func getMovieWatchProviders(id: Int, countryCode: String = "US") async throws
        -> TMDBWatchProviderCountry?
    {
        let endpoint = "/movie/\(id)/watch/providers"
        let response: TMDBWatchProvidersResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: []
        )
        return response.results?[countryCode]
    }

    /// Get watch providers for a TV show (per country). Returns the US entry when available.
    func getTVShowWatchProviders(id: Int, countryCode: String = "US") async throws
        -> TMDBWatchProviderCountry?
    {
        let endpoint = "/tv/\(id)/watch/providers"
        let response: TMDBWatchProvidersResponse = try await performRequest(
            endpoint: endpoint,
            queryItems: []
        )
        return response.results?[countryCode]
    }

    // MARK: - Image URLs

    /// Construct full image URL from TMDB image path
    nonisolated func imageURL(path: String?, size: ImageSize = .w500) -> URL? {
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
    nonisolated func mapToNetwork(_ network: TMDBNetwork) -> Network {
        Network(
            id: network.id,
            name: network.name,
            logoPath: network.logoPath,
            originCountry: network.originCountry
        )
    }

    /// Convert TMDB TV show search result to TVShow model
    nonisolated func mapToTVShow(_ result: TMDBTVShowSearchResult) -> TVShow {
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
    nonisolated func mapToTVShow(_ detail: TMDBTVShowDetail, providers: TMDBWatchProviderCountry? = nil) -> TVShow {
        let castMembers = detail.credits?.cast?.prefix(10) ?? []
        let cast = castMembers.map { $0.name }
        let castImagePaths = castMembers.map { $0.profilePath ?? "" }
        let castCharacters = castMembers.map { $0.character ?? "" }
        let genres = detail.genres?.map { $0.name } ?? []

        // Start with originating networks (category "stream"), applying aliases
        var seenNames = Set<String>()
        var categories: [Int: String] = [:]
        var allNetworks: [Network] = []
        for tmdbNetwork in detail.networks ?? [] {
            let canonical = Self.providerAliases[tmdbNetwork.name] ?? tmdbNetwork.name
            guard !seenNames.contains(canonical) else { continue }
            seenNames.insert(canonical)
            let network = Network(
                id: tmdbNetwork.id,
                name: canonical,
                logoPath: tmdbNetwork.logoPath,
                originCountry: tmdbNetwork.originCountry
            )
            allNetworks.append(network)
            categories[network.id] = "stream"
        }

        // Merge watch providers (deduplicating against originating networks)
        let (watchNetworks, watchCategories) = mapProviders(providers)
        var seenIDs = Set(allNetworks.map { $0.id })
        for network in watchNetworks {
            guard !seenIDs.contains(network.id) else { continue }
            guard !seenNames.contains(network.name) else { continue }
            seenIDs.insert(network.id)
            seenNames.insert(network.name)
            allNetworks.append(network)
            categories[network.id] = watchCategories[network.id] ?? "stream"
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
            numberOfEpisodes: detail.numberOfEpisodes
        )
    }

    /// Convert TMDB movie search result to Movie model
    nonisolated func mapToMovie(_ result: TMDBMovieSearchResult) -> Movie {
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

    /// Maps variant provider names to a canonical name so duplicates collapse.
    /// The first entry encountered keeps its ID, logo, and category.
    private static let providerAliases: [String: String] = [
        "Peacock Premium": "Peacock",
        "Peacock Premium Plus": "Peacock",
        "HBO Max": "HBO",
        "Max": "HBO",
        "Disney Plus": "Disney+",
        "AMC+ Roku Premium Channel": "AMC+",
    ]

    /// Build networks and provider categories from a watch provider response.
    /// Priority: flatrate > ads > rent > buy (first occurrence wins).
    /// Filters out resold channel variants and merges known aliases.
    nonisolated func mapProviders(_ providers: TMDBWatchProviderCountry?) -> (networks: [Network], categories: [Int: String]) {
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
    nonisolated func mapToMovie(_ detail: TMDBMovieDetail, providers: TMDBWatchProviderCountry?) -> Movie {
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
