import Foundation

protocol RecommendableResult: Sendable {
    var id: Int { get }
    var voteAverage: Double? { get }
    var voteCount: Int? { get }
    var genreIds: [Int]? { get }
    var displayTitle: String { get }
    var overview: String? { get }
}

extension TMDBTVShowSearchResult: RecommendableResult {
    var displayTitle: String { name }
}

extension TMDBMovieSearchResult: RecommendableResult {
    var displayTitle: String { title }
}

/// Memoised TMDB genre lists. Affinity is keyed by genre *name* (that's all the media rows store)
/// while API results carry genre *ids*, so every library ranking needs the translation — and
/// building `with_genres` needs it in the other direction.
@MainActor
final class GenreCatalog {
    static let shared = GenreCatalog()

    private var cache: [MediaType: [TMDBGenre]] = [:]

    private init() {}

    /// Cached for the process lifetime — TMDB's genre vocabulary is effectively static. A failed
    /// fetch caches nothing so the next load retries rather than ranking blind forever.
    func genres(for mediaType: MediaType) async -> [TMDBGenre] {
        if let cached = cache[mediaType] { return cached }

        let fetched: [TMDBGenre]
        do {
            fetched = mediaType == .tvShow
                ? try await TMDBService.shared.fetchTVGenres()
                : try await TMDBService.shared.fetchMovieGenres()
        } catch {
            return []
        }

        cache[mediaType] = fetched
        return fetched
    }

    /// TMDB ids for the given genre names. TV and movie vocabularies differ ("Sci-Fi & Fantasy"
    /// vs "Science Fiction"), so a name with no counterpart for this type is simply dropped.
    func genreIDs(for names: [String], mediaType: MediaType) async -> [Int] {
        let idsByName = await genres(for: mediaType)
            .reduce(into: [String: Int]()) { result, genre in
                result[genre.name.lowercased()] = genre.id
            }
        return names.compactMap { idsByName[$0.lowercased()] }
    }

    func genreNamesByID(for mediaType: MediaType) async -> [Int: String] {
        await genres(for: mediaType)
            .reduce(into: [Int: String]()) { result, genre in
                result[genre.id] = genre.name
            }
    }
}

enum RecommendationEngine {

    /// Minimum votes a candidate needs before it's trusted. Without it a single obscure title with
    /// one 10/10 rating outranks everything.
    static let minimumVoteCount = 50

    // MARK: - Seed Selection

    static func selectListSeeds(from items: [CustomListItem], mediaType: MediaType) -> [Int] {
        let filtered = items
            .filter { item in
                if mediaType == .tvShow { return item.tvShow != nil }
                return item.movie != nil
            }
            .sorted { $0.addedAt > $1.addedAt }

        var seeds: [Int] = []
        var seenIDs = Set<String>()

        for item in filtered {
            guard seeds.count < 8 else { break }
            guard let id = item.media?.id, !seenIDs.contains(id), let intID = Int(id) else { continue }
            seenIDs.insert(id)
            seeds.append(intID)
        }

        return seeds
    }

    static func existingIDs(in items: [CustomListItem], mediaType: MediaType) -> Set<String> {
        Set(items.compactMap { item in
            if mediaType == .tvShow {
                return item.tvShow?.id
            }
            return item.movie?.id
        })
    }

    /// A missing `voteCount` is kept rather than dropped: `/search` responses are the one place
    /// TMDB may omit it, and a search result shouldn't disappear over a field it lacks.
    static func hasEnoughVotes<T: RecommendableResult>(_ result: T) -> Bool {
        guard let voteCount = result.voteCount else { return true }
        return voteCount >= minimumVoteCount
    }

    // MARK: - Library Seeds & Affinity

    /// A library title used as a "more like this" seed. A negative weight pushes *away* from what
    /// a thumbs-down title is associated with.
    struct WeightedSeed: Sendable {
        let id: Int
        let weight: Double
    }

    static let maximumPositiveSeeds = 3
    static let maximumNegativeSeeds = 2

    /// Seeds ordered positives-first. Thumbs-up is the strongest "more like this" signal, recent
    /// unwatched adds are the current-interest signal, and recently watched titles are the
    /// fallback when nothing has been rated.
    static func weightedSeeds(from items: [ListItem]) -> [WeightedSeed] {
        let thumbsUp = items
            .filter { $0.userRating == 1 }
            .sorted { $0.addedAt > $1.addedAt }

        let unwatched = items
            .filter { !$0.isWatched && !$0.isDropped && isNeutral($0) }
            .sorted { $0.addedAt > $1.addedAt }

        let recentlyWatched = items
            .filter { $0.isWatched && isNeutral($0) }
            .sorted { ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast) }

        let thumbsDown = items
            .filter { $0.userRating == -1 }
            .sorted { $0.addedAt > $1.addedAt }

        var seeds: [WeightedSeed] = []
        var seenIDs = Set<Int>()

        func append(_ candidates: [ListItem], weight: Double, limit: Int) {
            var taken = 0
            for item in candidates {
                guard taken < limit else { return }
                guard let id = item.media.flatMap({ Int($0.id) }), seenIDs.insert(id).inserted else { continue }
                seeds.append(WeightedSeed(id: id, weight: weight))
                taken += 1
            }
        }

        // The positive pools share one budget, so a thumbs-up title can never be crowded out by a
        // more recent unrated one.
        let positiveBudget = maximumPositiveSeeds
        append(thumbsUp, weight: 2.0, limit: positiveBudget)
        append(unwatched, weight: 1.0, limit: positiveBudget - seeds.count)
        append(recentlyWatched, weight: 0.75, limit: positiveBudget - seeds.count)
        append(thumbsDown, weight: -2.0, limit: maximumNegativeSeeds)

        return seeds
    }

    /// Genre taste in [-1, 1], keyed by the genre names the media rows store. Rows whose details
    /// were never fetched carry no genres and simply don't vote.
    static func genreAffinity(from items: [ListItem]) -> [String: Double] {
        var raw: [String: Double] = [:]

        for item in items {
            guard let genres = item.media?.genres, !genres.isEmpty else { continue }
            let contribution: Double
            switch item.userRating {
            case 1: contribution = 2
            case -1: contribution = -1
            default: contribution = 1
            }
            for genre in genres {
                raw[genre, default: 0] += contribution
            }
        }

        // Normalising by the largest magnitude keeps the genre term comparable across a 6-item and
        // a 600-item library.
        guard let peak = raw.values.map({ abs($0) }).max(), peak > 0 else { return [:] }
        return raw.mapValues { $0 / peak }
    }

    /// Highest-affinity genre names, positive affinity only — `with_genres` ORs its values, so a
    /// disliked genre in the list would actively pull the pool the wrong way.
    static func topGenreNames(in affinity: [String: Double], limit: Int = 3) -> [String] {
        affinity
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private static func isNeutral(_ item: ListItem) -> Bool {
        item.userRating != 1 && item.userRating != -1
    }

    // MARK: - Library Ranking

    /// A candidate's position within one seed's result list. TMDB returns `/recommendations`
    /// best-first, so later entries should count for less without falling off a cliff.
    static func rankDecay(_ index: Int) -> Double {
        1.0 / (1.0 + Double(index) / 10.0)
    }

    static func rankLibraryCandidates<T: RecommendableResult>(
        seedResults: [(weight: Double, results: [T])],
        discoverResults: [T],
        affinity: [String: Double],
        genreNames: [Int: String],
        providersSelected: Bool,
        excluding existingIDs: Set<String>
    ) -> [T] {
        var seedScores: [Int: Double] = [:]
        var bestByID: [Int: T] = [:]
        var fromDiscover: Set<Int> = []

        func isAdmissible(_ result: T) -> Bool {
            guard !existingIDs.contains(String(result.id)) else { return false }
            guard (result.voteCount ?? 0) >= minimumVoteCount else { return false }
            return (result.voteAverage ?? 0) >= 6.0
        }

        for seed in seedResults {
            for (index, result) in seed.results.enumerated() where isAdmissible(result) {
                seedScores[result.id, default: 0] += seed.weight * rankDecay(index)
                if bestByID[result.id] == nil { bestByID[result.id] = result }
            }
        }

        for result in discoverResults where isAdmissible(result) {
            fromDiscover.insert(result.id)
            if bestByID[result.id] == nil { bestByID[result.id] = result }
        }

        let genreAffinityByID = affinityByGenreID(affinity: affinity, genreNames: genreNames)

        var totals: [Int: Double] = [:]
        for (id, candidate) in bestByID {
            let seedScore = seedScores[id] ?? 0
            // Summed so a multi-genre match beats a single one, but clamped so a four-genre title
            // can't out-score a candidate every positive seed vouches for.
            let genreSum = (candidate.genreIds ?? []).reduce(0.0) { partial, genreID in
                partial + (genreAffinityByID[genreID] ?? 0)
            }
            let genreScore = min(max(genreSum, -2), 2)
            let quality = min(max(((candidate.voteAverage ?? 0) - 6) / 4, 0), 1)
            let onService = (providersSelected && fromDiscover.contains(id)) ? 1.0 : 0.0
            let total = seedScore + 1.5 * genreScore + 0.5 * quality + onService
            // A candidate only a thumbs-down seed vouches for scores <= 0 and drops out here.
            guard total > 0 else { continue }
            totals[id] = total
        }

        return totals.keys
            .compactMap { bestByID[$0] }
            .sorted { a, b in
                let totalA = totals[a.id] ?? 0
                let totalB = totals[b.id] ?? 0
                if totalA != totalB { return totalA > totalB }
                let voteA = a.voteAverage ?? 0
                let voteB = b.voteAverage ?? 0
                if voteA != voteB { return voteA > voteB }
                return a.id < b.id
            }
            .prefix(20)
            .map { $0 }
    }

    /// Affinity re-keyed by TMDB genre id. Names are matched exactly first, then case-insensitively,
    /// since the stored names came from TMDB in the first place.
    private static func affinityByGenreID(affinity: [String: Double], genreNames: [Int: String]) -> [Int: Double] {
        guard !affinity.isEmpty else { return [:] }

        var lowercased: [String: Double] = [:]
        for (name, value) in affinity where lowercased[name.lowercased()] == nil {
            lowercased[name.lowercased()] = value
        }

        return genreNames.reduce(into: [Int: Double]()) { result, entry in
            if let value = affinity[entry.value] ?? lowercased[entry.value.lowercased()] {
                result[entry.key] = value
            }
        }
    }

    // MARK: - Library Fetching

    /// Candidate pool floor for `/discover`. Higher than the per-candidate floor because this list
    /// is sorted by popularity and would otherwise be padded with long-tail noise.
    static let discoverVoteCountFloor = 100

    /// One round trip per seed plus at most one `/discover` sweep, all concurrent. Individual
    /// failures degrade to an empty list, so a single dead endpoint can't blank the section.
    static func fetchLibraryRecommendations<T: RecommendableResult>(
        seeds: [WeightedSeed],
        affinity: [String: Double],
        mediaType: MediaType,
        providerQuery: String?,
        excluding existingIDs: Set<String>,
        recommendationFetcher: @escaping @Sendable (Int) async throws -> [T],
        discoverFetcher: @escaping @Sendable (
            _ withGenres: String?,
            _ withWatchProviders: String?,
            _ voteCountGte: Int,
            _ dateLte: String
        ) async throws -> [T]
    ) async -> [T] {
        let catalog = GenreCatalog.shared
        let genreNames = await catalog.genreNamesByID(for: mediaType)
        let topGenres = await catalog.genreIDs(for: topGenreNames(in: affinity), mediaType: mediaType)
        let genreQuery = topGenres.isEmpty ? nil : topGenres.map(String.init).joined(separator: "|")

        // With neither a genre nor a provider constraint `/discover` is just "popular right now",
        // which the seeds already cover better — skip the request instead of diluting the pool.
        let wantsDiscover = genreQuery != nil || providerQuery != nil
        let dateLte = TMDBService.apiDateString(from: .now)
        let voteFloor = discoverVoteCountFloor

        var seedResults: [(weight: Double, results: [T])] = []
        var discoverResults: [T] = []

        await withTaskGroup(of: (Double?, [T]).self) { group in
            for seed in seeds {
                let id = seed.id
                let weight = seed.weight
                group.addTask {
                    (weight, (try? await recommendationFetcher(id)) ?? [])
                }
            }

            if wantsDiscover {
                group.addTask {
                    let results = try? await discoverFetcher(
                        genreQuery,
                        providerQuery,
                        voteFloor,
                        dateLte
                    )
                    return (nil, results ?? [])
                }
            }

            for await (weight, results) in group {
                if let weight {
                    seedResults.append((weight, results))
                } else {
                    discoverResults = results
                }
            }
        }

        return rankLibraryCandidates(
            seedResults: seedResults,
            discoverResults: discoverResults,
            affinity: affinity,
            genreNames: genreNames,
            providersSelected: providerQuery != nil,
            excluding: existingIDs
        )
    }

}
