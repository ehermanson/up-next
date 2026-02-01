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

    /// Convert TMDB TV show detail to TVShow model
    nonisolated func mapToTVShow(_ detail: TMDBTVShowDetail) -> TVShow {
        let cast = detail.credits?.cast?.prefix(10).map { $0.name } ?? []
        let networks = detail.networks?.map { mapToNetwork($0) } ?? []
        let genres = detail.genres?.map { $0.name } ?? []
        return TVShow(
            id: String(detail.id),
            title: detail.name,
            thumbnailURL: imageURL(path: detail.posterPath),
            networks: networks,
            descriptionText: detail.overview,
            cast: cast,
            genres: genres,
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

    /// Convert TMDB movie detail + watch providers to Movie model
    nonisolated func mapToMovie(_ detail: TMDBMovieDetail, providers: TMDBWatchProviderCountry?) -> Movie {
        let cast = detail.credits?.cast?.prefix(10).map { $0.name } ?? []

        let rent: [TMDBWatchProviderEntry] = providers?.rent ?? []
        let buy: [TMDBWatchProviderEntry] = providers?.buy ?? []
        let providerEntries: [TMDBWatchProviderEntry] = rent + buy

        // Deduplicate providers by providerId, keeping first occurrence
        var seen = Set<Int>()
        let networks = providerEntries.compactMap { entry -> Network? in
            guard !seen.contains(entry.providerId) else { return nil }
            seen.insert(entry.providerId)
            return Network(
                id: entry.providerId,
                name: entry.providerName,
                logoPath: entry.logoPath,
                originCountry: "US"
            )
        }

        let genres = detail.genres?.map { $0.name } ?? []

        return Movie(
            id: String(detail.id),
            title: detail.title,
            thumbnailURL: imageURL(path: detail.posterPath),
            networks: networks,
            descriptionText: detail.overview,
            cast: cast,
            genres: genres,
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
