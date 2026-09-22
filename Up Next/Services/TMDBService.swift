import Foundation

/// Service for interacting with The Movie Database (TMDB) API.
/// The class is implicitly `@MainActor` (the project's default actor isolation), which is what
/// makes its mutable cache (`canonicalLogoPaths`) safe without any locking.
final class TMDBService {
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

    /// Canonical provider logo paths keyed by provider ID.
    /// Populated once per app session from the global provider list.
    private var canonicalLogoPaths: [Int: String] = [:]

    /// The region code (e.g., "US", "GB", "DE") used for every region-aware lookup: watch
    /// providers on detail responses, the provider list, `watch_region` on discover and
    /// `region` on now playing.
    ///
    /// Follows the user's region override from `ProviderSettings`, falling back to the device
    /// locale's region and finally "US".
    var currentRegion: String {
        ProviderSettings.effectiveRegion
    }

    // MARK: - Search

    /// Search for TV shows by name. The first two pages, re-ranked by `SearchRanking` — TMDB's
    /// own order is text relevance only, which buries well-known titles under obscure tighter
    /// matches (see `SearchRanking`).
    func searchTVShows(query: String) async throws -> [TMDBTVShowSearchResult] {
        let results: [TMDBTVShowSearchResult] = try await searchPages(
            TMDBTVShowSearchResponse.self, endpoint: "/search/tv", query: query
        )
        return SearchRanking.ranked(results, query: query) {
            SearchRanking.Signals(title: $0.name, alternateTitle: $0.originalName,
                                  popularity: $0.popularity, voteCount: $0.voteCount)
        }
    }

    /// Search for movies by name. See `searchTVShows`.
    func searchMovies(query: String) async throws -> [TMDBMovieSearchResult] {
        let results: [TMDBMovieSearchResult] = try await searchPages(
            TMDBMovieSearchResponse.self, endpoint: "/search/movie", query: query
        )
        return SearchRanking.ranked(results, query: query) {
            SearchRanking.Signals(title: $0.title, alternateTitle: $0.originalTitle,
                                  popularity: $0.popularity, voteCount: $0.voteCount)
        }
    }

    /// Pages 1 and 2 of a search, fetched concurrently and merged in order, deduped by id
    /// (TMDB pagination can repeat a row across the page boundary). Page 2 is requested up
    /// front rather than after page 1 reports `totalPages` so a multi-page query doesn't pay a
    /// second round trip; a failed or empty page 2 just yields page 1.
    private nonisolated func searchPages<Page: TMDBSearchPage>(
        _ page: Page.Type, endpoint: String, query: String
    ) async throws -> [Page.Result] {
        @Sendable func items(page: Int) -> [URLQueryItem] {
            [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: "\(page)")]
        }
        async let first: Page = performRequest(endpoint: endpoint, queryItems: items(page: 1))
        async let second: Page? = try? performRequest(endpoint: endpoint, queryItems: items(page: 2))

        let firstPage = try await first
        guard (firstPage.totalPages ?? 1) > 1, let secondPage = await second else {
            return firstPage.results
        }
        var seen = Set<Int>()
        return (firstPage.results + secondPage.results).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Trending & Theatrical

    /// Genuinely trending TV shows for a time window ("day" or "week").
    ///
    /// `/trending` does not accept `with_watch_providers`; callers that must respect the user's
    /// "on my services" filter should fall back to `discoverTVShows(sortBy: "popularity.desc", …)`,
    /// which is the provider-aware equivalent.
    func trendingTVShows(window: String = "week") async throws -> TMDBTVShowSearchResponse {
        try await performRequest(endpoint: "/trending/tv/\(window)", queryItems: [])
    }

    /// Genuinely trending movies for a time window ("day" or "week"). See `trendingTVShows`
    /// for the provider-filter caveat.
    func trendingMovies(window: String = "week") async throws -> TMDBMovieSearchResponse {
        try await performRequest(endpoint: "/trending/movie/\(window)", queryItems: [])
    }

    /// Movies currently playing in theaters in the user's region.
    /// Theatrical releases aren't on a streaming service, so this ignores the provider filter.
    func nowPlayingMovies(page: Int = 1) async throws -> TMDBMovieSearchResponse {
        try await performRequest(
            endpoint: "/movie/now_playing",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "region", value: currentRegion),
            ]
        )
    }

    /// Formats a date the way TMDB's `*_date.gte` / `*_date.lte` discover filters expect:
    /// `yyyy-MM-dd` in UTC, so a device near midnight never asks for tomorrow's cutoff.
    static func apiDateString(from date: Date) -> String {
        apiDateFormatter.string(from: date)
    }

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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

    /// Get the episode list for a single season (read-only; no episode-level watched state).
    func getSeasonDetails(tvID: Int, season: Int) async throws -> TMDBSeasonDetail {
        let endpoint = "/tv/\(tvID)/season/\(season)"
        return try await performRequest(endpoint: endpoint, queryItems: [])
    }

    /// Lean TV metadata: the same `/tv/{id}` endpoint as `getTVShowDetails`, but appending only
    /// what a background library refresh or the Discover airing-date chip reads (watch providers
    /// and the region content rating) instead of credits/videos/similar/recommendations. The URL
    /// differs from the full-detail call, so it's cached under its own key.
    func getTVShowMetadata(id: Int) async throws -> TMDBTVShowDetail {
        let endpoint = "/tv/\(id)"
        return try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "append_to_response", value: "watch/providers,content_ratings")]
        )
    }

    /// Lean movie metadata — see `getTVShowMetadata`. `mapToMovie(detail:)` reads `releaseDates`
    /// for the certification, so that's appended alongside watch providers.
    func getMovieMetadata(id: Int) async throws -> TMDBMovieDetail {
        let endpoint = "/movie/\(id)"
        return try await performRequest(
            endpoint: endpoint,
            queryItems: [URLQueryItem(name: "append_to_response", value: "watch/providers,release_dates")]
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

    func collectionMovies(name: String, seeds: [Int], excluding ids: Set<String>) async -> [TMDBMovieSearchResult] {
        let genres = (try? await fetchMovieGenres()) ?? []
        let genreNames = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0.name) })
        return await CollectionRecommendationEngine.load(
            name: name, seeds: seeds, excluding: ids,
            recommendations: { try await self.fetchMovieRecommendations(id: $0) },
            member: {
                let detail = try await self.getMovieDetails(id: $0)
                return JevTitle(id: detail.id, title: detail.title, year: String((detail.releaseDate ?? "").prefix(4)),
                                overview: detail.overview ?? "", genres: detail.genres?.map(\.name) ?? [], mediaType: "movie")
            },
            candidate: {
                JevTitle(id: $0.id, title: $0.title, year: String(($0.releaseDate ?? "").prefix(4)),
                         overview: $0.overview ?? "", genres: ($0.genreIds ?? []).compactMap { genreNames[$0] }, mediaType: "movie")
            },
            search: { try await self.searchMovies(query: $0) }
        )
    }

    func collectionTVShows(name: String, seeds: [Int], excluding ids: Set<String>) async -> [TMDBTVShowSearchResult] {
        let genres = (try? await fetchTVGenres()) ?? []
        let genreNames = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0.name) })
        return await CollectionRecommendationEngine.load(
            name: name, seeds: seeds, excluding: ids,
            recommendations: { try await self.fetchTVRecommendations(id: $0) },
            member: {
                let detail = try await self.getTVShowDetails(id: $0)
                return JevTitle(id: detail.id, title: detail.name, year: String((detail.firstAirDate ?? "").prefix(4)),
                                overview: detail.overview ?? "", genres: detail.genres?.map(\.name) ?? [], mediaType: "tv")
            },
            candidate: {
                JevTitle(id: $0.id, title: $0.name, year: String(($0.firstAirDate ?? "").prefix(4)),
                         overview: $0.overview ?? "", genres: ($0.genreIds ?? []).compactMap { genreNames[$0] }, mediaType: "tv")
            },
            search: { try await self.searchTVShows(query: $0) }
        )
    }

    /// Get details for a movie collection (e.g. "Dune Collection")
    func getCollectionDetails(id: Int) async throws -> TMDBCollectionDetail {
        let endpoint = "/collection/\(id)"
        return try await performRequest(endpoint: endpoint, queryItems: [])
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
        let allResults = movieProviders.results + tvProviders.results

        // Pass 1: learn which base services exist, so `alias(for:)` can fold a channel variant
        // TMDB renamed since the alias table was written ("HBO Max Amazon Channel") onto its base.
        for provider in allResults where !Self.isChannelVariant(named: provider.providerName) {
            canonicalIDsByName[Self.normalizedProviderName(provider.providerName)] = provider.providerId
        }
        for (name, canonical) in Self.providerAliases {
            canonicalIDsByName[Self.normalizedProviderName(name)] = canonical.id
            canonicalIDsByName[Self.normalizedProviderName(canonical.name)] = canonical.id
        }

        var mergedIndexByID: [Int: Int] = [:]
        var seenNames = Set<String>()
        var merged: [TMDBWatchProviderInfo] = []
        // Best priority seen for each canonical provider across every variant that folds into it.
        // TMDB ranks "HBO Max Amazon Channel" 11th in the US but "HBO Max" itself 152nd; without
        // this the canonical row inherits whichever variant happened to be seen first.
        var bestPriority: [Int: Int] = [:]

        for provider in allResults {
            guard !Self.storefrontProviderIDs.contains(provider.providerId),
                  !Self.aggregatorProviderIDs.contains(provider.providerId) else { continue }

            // Resolve the alias first — an aliased channel variant is a real subscription.
            let alias = alias(for: provider.providerName)
            let canonicalName = alias?.name ?? provider.providerName
            let canonicalID = alias.flatMap { $0.id >= 0 ? $0.id : nil } ?? provider.providerId
            if alias == nil, Self.isChannelVariant(named: provider.providerName) { continue }

            bestPriority[canonicalID] = min(bestPriority[canonicalID] ?? Int.max, provider.priority(in: regionCode))
            // The base is the entry that *is* the canonical id ("Paramount Plus" 531), whatever
            // TMDB calls it; the canonical name is ours.
            let isBase = canonicalID == provider.providerId
            let canonical = TMDBWatchProviderInfo(
                providerId: canonicalID,
                providerName: canonicalName,
                logoPath: provider.logoPath,
                displayPriority: provider.displayPriority,
                displayPriorities: provider.displayPriorities
            )

            if let index = mergedIndexByID[canonicalID] {
                // A variant got here first (Paramount+ Premium's logo on the Paramount+ tile) —
                // the base's own logo wins.
                if isBase { merged[index] = canonical }
                continue
            }
            guard !seenNames.contains(canonicalName) else { continue }

            mergedIndexByID[canonicalID] = merged.count
            seenNames.insert(canonicalName)
            merged.append(canonical)
        }

        // TMDB lower display_priority means higher prominence — the *region's* priority, not the
        // global one, or the US grid opens with FilmBox+ and Sun NXT ahead of Hulu.
        let sorted = merged.sorted {
            let leftPriority = bestPriority[$0.providerId] ?? $0.priority(in: regionCode)
            let rightPriority = bestPriority[$1.providerId] ?? $1.priority(in: regionCode)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
        }

        // Warm the canonical logo cache so mapping functions can use it
        for provider in sorted {
            if let logo = provider.logoPath {
                canonicalLogoPaths[provider.providerId] = logo
            }
        }

        return sorted
    }

    /// Lazily loads canonical provider logos once per app session.
    /// Falls back silently on error — per-title logos are used instead.
    private func ensureCanonicalLogosLoaded() async {
        guard canonicalLogoPaths.isEmpty else { return }
        guard let providers = try? await fetchWatchProviders() else { return }
        for provider in providers {
            if let logo = provider.logoPath {
                canonicalLogoPaths[provider.providerId] = logo
            }
        }
    }

    /// Every region TMDB has watch-provider data for, sorted by English name.
    func fetchWatchProviderRegions() async throws -> [TMDBWatchProviderRegion] {
        let response: TMDBWatchProviderRegionListResponse = try await performRequest(
            endpoint: "/watch/providers/regions",
            queryItems: []
        )
        return response.results.sorted {
            $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
        }
    }

    /// Drop cached responses for the given API-relative path prefixes (e.g. `"/discover/"`),
    /// leaving the rest of the cache intact. A screen's pull-to-refresh uses this to refetch the
    /// endpoints it owns without throwing away detail responses the rest of the app still wants.
    func invalidateResponseCache(pathPrefixes: [String]) async {
        // Cache keys are full URLs, whose path carries the base URL's `/3` version segment.
        let basePath = URLComponents(string: baseURL)?.path ?? ""
        await deduplicator.invalidateCache(pathPrefixes: pathPrefixes.map { basePath + $0 })
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
        case w300 = "w300"
        case w342 = "w342"
        case w500 = "w500"
        case w780 = "w780"
        case original = "original"
    }

    // MARK: - Mapping Helpers

    /// Convert TMDB TV show search result to TVShow model
    func mapToTVShow(_ result: TMDBTVShowSearchResult) -> TVShow {
        TVShow(
            id: String(result.id),
            title: result.name,
            thumbnailURL: imageURL(path: result.posterPath),
            backdropPath: result.backdropPath,
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
    func mapToTVShow(_ detail: TMDBTVShowDetail, providers: TMDBWatchProviderCountry? = nil) async -> TVShow {
        await ensureCanonicalLogosLoaded()
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

        let seasonDescriptions: [String] = {
            guard let seasons = detail.seasons else { return [] }
            let numbered = seasons
                .filter { $0.seasonNumber > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            return numbered.map { $0.overview ?? "" }
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
            let alias = alias(for: tmdbNetwork.name)
            let canonical = alias?.name ?? tmdbNetwork.name
            guard !seenNames.contains(canonical) else { continue }
            seenNames.insert(canonical)
            // Use provider ID if known, otherwise fall back to network ID
            let networkID = Self.networkToProviderID[tmdbNetwork.name]
                ?? alias.flatMap { $0.id >= 0 ? $0.id : nil }
                ?? tmdbNetwork.id
            // Prefer canonical logo, then streaming provider's logo, then network logo
            let logoPath = canonicalLogoPaths[networkID] ?? providerLogos[networkID] ?? tmdbNetwork.logoPath
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
            backdropPath: detail.backdropPath,
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
            seasonDescriptions: seasonDescriptions,
            contentRating: extractTVContentRating(from: detail),
            episodeRunTime: detail.episodeRunTime?.first,
            nextEpisodeAirDate: detail.nextEpisodeToAir?.airDate,
            nextEpisodeSeason: detail.nextEpisodeToAir?.seasonNumber,
            nextEpisodeNumber: detail.nextEpisodeToAir?.episodeNumber,
            nextEpisodeName: detail.nextEpisodeToAir?.name,
            status: detail.status,
            voteAverage: detail.voteAverage
        )
    }

    /// Convert TMDB movie search result to Movie model
    func mapToMovie(_ result: TMDBMovieSearchResult) -> Movie {
        Movie(
            id: String(result.id),
            title: result.title,
            thumbnailURL: imageURL(path: result.posterPath),
            backdropPath: result.backdropPath,
            networks: [],
            descriptionText: result.overview,
            cast: [],
            releaseDate: result.releaseDate,
            runtime: nil,
            voteAverage: result.voteAverage
        )
    }

    /// Suffixes that indicate a resold channel variant (e.g. "HBO Max Amazon Channel").
    /// Stored normalized (lowercased, collapsed whitespace).
    /// Rent/buy storefronts: real places to watch (they stay in a title's provider row under
    /// rent/buy) but nothing anyone "subscribes" to, so they're kept out of the selection grid.
    private static let storefrontProviderIDs: Set<Int> = [
        2,      // Apple TV Store (iTunes)
        3,      // Google Play Movies
        7,      // Fandango At Home (Vudu)
        10,     // Amazon Video
        68,     // Microsoft Store
        192,    // YouTube
        332,    // Fandango at Home Free
        652,    // Apple TV
    ]

    /// Aggregators and cable on-demand portals TMDB lists as providers. Not services in any
    /// sense a user recognises, so they're dropped from the grid *and* from every title's logos.
    private static let aggregatorProviderIDs: Set<Int> = [
        2285,   // JustWatch TV
        486,    // Spectrum On Demand
    ]

    private static let channelSuffixes = [
        "amazon channel",
        "apple tv channel",
        "apple tv+ channel",
        "roku premium channel",
    ]

    /// Normalised provider names → canonical ids, learned from the region's provider list (every
    /// non-variant entry, plus the alias table's keys and canonical names). Filled by
    /// `fetchWatchProviders`, which runs at startup via `ensureCanonicalLogosLoaded`.
    private var canonicalIDsByName: [String: Int] = [:]

    /// Alias lookup that also understands the two ways TMDB spawns variants faster than a table
    /// keeps up: ad-supported tiers ("Amazon Prime Video Free with Ads" → Prime Video) and resold
    /// channels ("HBO Max Amazon Channel" → HBO Max, "Paramount+ Apple TV channel" → Paramount+).
    /// Both strip the suffix and resolve the base — through the alias table first, then through
    /// `canonicalIDsByName`. An ad tier whose base is unknown keeps the entry's own id (`-1`
    /// signals that to callers); a channel whose base is unknown returns nil and is dropped, since
    /// a resold channel with no base subscription isn't a service anyone picks.
    private func alias(for providerName: String) -> CanonicalProvider? {
        if let exact = Self.providerAliases[providerName] { return exact }

        let tierBase = providerName.replacingOccurrences(
            of: #"\s+(?:free\s+|standard\s+|basic\s+)?with\s+ads\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if tierBase != providerName {
            if let baseAlias = alias(for: tierBase) { return baseAlias }
            return CanonicalProvider(name: tierBase, id: canonicalIDsByName[Self.normalizedProviderName(tierBase)] ?? -1)
        }

        if let channelBase = Self.channelBaseName(of: providerName) {
            if let baseAlias = alias(for: channelBase) { return baseAlias }
            if let id = canonicalIDsByName[Self.normalizedProviderName(channelBase)] {
                return CanonicalProvider(name: channelBase, id: id)
            }
        }
        return nil
    }

    /// "Paramount+ Amazon Channel" → "Paramount+"; nil when the name carries no channel suffix.
    private static func channelBaseName(of providerName: String) -> String? {
        let normalized = normalizedProviderName(providerName)
        guard let suffix = channelSuffixes.first(where: { normalized.hasSuffix($0) }) else { return nil }
        let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > suffix.count else { return nil }
        let base = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }

    private static func normalizedProviderName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isChannelVariant(named providerName: String) -> Bool {
        let normalized = normalizedProviderName(providerName)
        return channelSuffixes.contains { normalized.hasSuffix($0) }
    }

    /// Maps originating network names to their streaming provider IDs.
    /// Used when a show's network (e.g., "AMC") should match the user's selected provider (e.g., AMC+ ID 526).
    private static let networkToProviderID: [String: Int] = [
        "AMC": 526,         // AMC network → AMC+ provider
        "AMC+": 526,
        "HBO": 1899,        // HBO network → HBO Max provider
        "HBO Max": 1899,
        "Max": 1899,
    ]

    /// The provider a variant name collapses onto: canonical display name plus canonical TMDB ID.
    private struct CanonicalProvider {
        let name: String
        let id: Int
    }

    /// Maps variant provider names to the canonical provider they collapse onto.
    /// The canonical ID (not the variant's own ID) is what gets stored, so a tier variant like
    /// "Netflix Standard with Ads" (1796) never shadows Netflix (8) in the user's provider selection.
    /// Aliases are resolved before the channel-variant filter, so a resold channel with an alias here
    /// (e.g. "Paramount+ Amazon Channel") counts as the real subscription rather than being dropped.
    private static let providerAliases: [String: CanonicalProvider] = [
        // Netflix tiers
        "Netflix basic with Ads": CanonicalProvider(name: "Netflix", id: 8),
        "Netflix Kids": CanonicalProvider(name: "Netflix", id: 8),
        "Netflix Standard with Ads": CanonicalProvider(name: "Netflix", id: 8),
        // Peacock tiers
        "Peacock Premium": CanonicalProvider(name: "Peacock", id: 386),
        "Peacock Premium Plus": CanonicalProvider(name: "Peacock", id: 386),
        // HBO/Max
        "HBO": CanonicalProvider(name: "HBO Max", id: 1899),
        "Max": CanonicalProvider(name: "HBO Max", id: 1899),
        "Max Amazon Channel": CanonicalProvider(name: "HBO Max", id: 1899),
        // Disney
        "Disney Plus": CanonicalProvider(name: "Disney+", id: 337),
        // AMC
        "AMC": CanonicalProvider(name: "AMC+", id: 526),
        "AMC+ Roku Premium Channel": CanonicalProvider(name: "AMC+", id: 526),
        "AMC Plus": CanonicalProvider(name: "AMC+", id: 526),
        // Paramount
        "Paramount+ Premium": CanonicalProvider(name: "Paramount+", id: 531),
        "Paramount Plus Premium": CanonicalProvider(name: "Paramount+", id: 531),
        "Paramount+ Essential": CanonicalProvider(name: "Paramount+", id: 531),
        "Paramount Plus Essential": CanonicalProvider(name: "Paramount+", id: 531),
        "Paramount Plus": CanonicalProvider(name: "Paramount+", id: 531),
        "Paramount+ Amazon Channel": CanonicalProvider(name: "Paramount+", id: 531),
        // Hulu
        "Hulu (No Ads)": CanonicalProvider(name: "Hulu", id: 15),
        // Amazon
        "Amazon Prime Video": CanonicalProvider(name: "Prime Video", id: 9),
        "Amazon Prime Video with Ads": CanonicalProvider(name: "Prime Video", id: 9),
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
                guard !Self.aggregatorProviderIDs.contains(entry.providerId) else { continue }
                // Resolve the alias first — an aliased channel variant (e.g. "Paramount+ Amazon
                // Channel") is a real subscription, so it must survive the channel-variant filter.
                let alias = alias(for: entry.providerName)
                let canonicalName = alias?.name ?? entry.providerName
                let canonicalID = alias.flatMap { $0.id >= 0 ? $0.id : nil } ?? entry.providerId
                if alias == nil, Self.isChannelVariant(named: entry.providerName) { continue }

                guard !seenIDs.contains(canonicalID) else { continue }
                guard !seenNames.contains(canonicalName) else { continue }

                seenIDs.insert(canonicalID)
                seenNames.insert(canonicalName)
                let logoPath = canonicalLogoPaths[canonicalID] ?? entry.logoPath
                networks.append(Network(
                    id: canonicalID,
                    name: canonicalName,
                    logoPath: logoPath,
                    originCountry: currentRegion
                ))
                categories[canonicalID] = category
            }
        }

        return (networks, categories)
    }

    /// Convert TMDB movie detail + watch providers to Movie model
    func mapToMovie(_ detail: TMDBMovieDetail, providers: TMDBWatchProviderCountry?) async -> Movie {
        await ensureCanonicalLogosLoaded()
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
            backdropPath: detail.backdropPath,
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

    /// Discover TV shows with optional filters.
    ///
    /// Date parameters take TMDB's `yyyy-MM-dd` format (see `apiDateString(from:)`):
    /// - `firstAirDateLte` excludes shows that haven't premiered yet.
    /// - `airDateGte` / `airDateLte` bound the window in which *any* episode airs, which is what
    ///   "currently airing" means to TMDB.
    func discoverTVShows(
        page: Int = 1,
        sortBy: String = "popularity.desc",
        withGenres: String? = nil,
        withWatchProviders: String? = nil,
        watchRegion: String? = nil,
        voteCountGte: Int? = nil,
        firstAirDateLte: String? = nil,
        airDateGte: String? = nil,
        airDateLte: String? = nil
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
        if let firstAirDateLte {
            queryItems.append(URLQueryItem(name: "first_air_date.lte", value: firstAirDateLte))
        }
        if let airDateGte {
            queryItems.append(URLQueryItem(name: "air_date.gte", value: airDateGte))
        }
        if let airDateLte {
            queryItems.append(URLQueryItem(name: "air_date.lte", value: airDateLte))
        }
        return try await performRequest(endpoint: "/discover/tv", queryItems: queryItems)
    }

    /// Discover movies with optional filters.
    ///
    /// `releaseDateLte` takes TMDB's `yyyy-MM-dd` format (see `apiDateString(from:)`) and excludes
    /// titles that haven't been released yet.
    func discoverMovies(
        page: Int = 1,
        sortBy: String = "popularity.desc",
        withGenres: String? = nil,
        withWatchProviders: String? = nil,
        watchRegion: String? = nil,
        voteCountGte: Int? = nil,
        releaseDateLte: String? = nil
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
        if let releaseDateLte {
            queryItems.append(URLQueryItem(name: "primary_release_date.lte", value: releaseDateLte))
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

    private nonisolated func performRequest<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(endpoint)")
        var items = queryItems
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        components?.queryItems = items
        // `URLComponents` percent-encodes query values with `.urlQueryAllowed`, which leaves '+'
        // unescaped; TMDB decodes an unescaped '+' as a space, so "Paramount+" would search as
        // "Paramount ". Escape it explicitly after the fact — the only place any URL gets built.
        if let escaped = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") {
            components?.percentEncodedQuery = escaped
        }

        guard let url = components?.url else {
            throw TMDBError.invalidURL
        }

        let data: Data
        do {
            data = try await deduplicator.deduplicated(for: url) {
                try await Self.fetchWithRetry(url: url)
            }
        } catch {
            throw Self.mapTransportError(error)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingError(error)
        }
    }

    /// Fetches once, retrying a single time for transient server trouble (rate limiting or a
    /// momentary outage) before giving up. Honors `Retry-After` when TMDB sends one, capped at 3s
    /// so a misbehaving header can't stall the UI; otherwise a flat 0.8s backoff.
    private nonisolated static func fetchWithRetry(url: URL) async throws -> Data {
        do {
            return try await fetchOnce(url: url)
        } catch let error as TMDBError {
            guard case .httpError(let statusCode, let retryAfter) = error, isRetryableStatus(statusCode) else {
                throw error
            }
            try Task.checkCancellation()
            let delaySeconds = min(retryAfter ?? 0.8, 3.0)
            try await Task.sleep(for: .milliseconds(Int(delaySeconds * 1000)))
            return try await fetchOnce(url: url)
        }
    }

    private nonisolated static func isRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 429 || (502...504).contains(statusCode)
    }

    private nonisolated static func fetchOnce(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TMDBError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw TMDBError.httpError(statusCode: httpResponse.statusCode, retryAfter: retryAfter)
        }

        return data
    }

    /// Wraps the handful of `URLError`s a person should hear about differently than "HTTP error:
    /// nnn" — everything else (including cancellation) passes through unchanged.
    private nonisolated static func mapTransportError(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return TMDBError.offline
        case .timedOut:
            return TMDBError.timedOut
        default:
            return error
        }
    }
}

private actor RequestDeduplicator {
    private var inFlight: [URL: Task<Data, any Error>] = [:]
    private var cache: [URL: CachedResponse] = [:]

    private struct CachedResponse {
        let data: Data
        let insertedAt: Date
    }

    /// Default time-to-live for cached responses (10 minutes)
    private let ttl: TimeInterval = 600
    /// Upper bound on cached responses — otherwise a long session's cache grows unbounded since
    /// TTL is only ever checked on read, never proactively swept.
    private let maxEntries = 300

    func deduplicated(for url: URL, perform: @Sendable @escaping () async throws -> Data) async throws -> Data {
        // Return cached response if within TTL
        if let cached = cache[url], Date.now.timeIntervalSince(cached.insertedAt) < ttl {
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
        store(data, for: url)
        return data
    }

    /// Inserts a fresh response, first dropping anything past its TTL, then evicting the oldest
    /// entry if the cache is still at capacity.
    private func store(_ data: Data, for url: URL) {
        let now = Date.now
        cache = cache.filter { now.timeIntervalSince($0.value.insertedAt) < ttl }
        if cache.count >= maxEntries, let oldest = cache.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[url] = CachedResponse(data: data, insertedAt: now)
    }

    /// Drops cached entries whose URL path starts with any of the given prefixes. Prefixes are
    /// full URL paths (including the API version segment), not API-relative endpoints.
    /// In-flight requests are left alone — they're already fresh.
    func invalidateCache(pathPrefixes: [String]) {
        guard !pathPrefixes.isEmpty else { return }
        cache = cache.filter { url, _ in
            let path = url.path(percentEncoded: false)
            return !pathPrefixes.contains { path.hasPrefix($0) }
        }
    }
}

nonisolated enum TMDBError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, retryAfter: Double? = nil)
    case decodingError(Error)
    case offline
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode, _):
            switch statusCode {
            case 429:
                return "TMDB is busy right now. Try again in a moment."
            case 500...599:
                return "TMDB is having trouble. Try again later."
            default:
                return "HTTP error: \(statusCode)"
            }
        case .decodingError:
            return "Couldn’t read the response from TMDB."
        case .offline:
            return "You’re offline."
        case .timedOut:
            return "The connection timed out."
        }
    }
}
