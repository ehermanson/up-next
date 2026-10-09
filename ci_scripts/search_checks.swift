// Search quality checks: the real `DescriptiveSearch` + `SearchRanking` against live TMDB, scored
// on a fixed set of queries. Run with ./ci_scripts/check_search.sh (needs network and a TMDB key).
//
// Each case describes what a person would want to see, not what the code happens to do. Cases
// marked `gap` fail today for a known reason; they're the to-do list, and the score counts them so
// a new lever shows up as progress. Only a non-gap case failing (a regression) fails the script.
import Foundation

// MARK: - Minimal stand-ins for the app types DescriptiveSearch touches

enum MediaType: CustomStringConvertible {
    case tvShow, movie
    var description: String { self == .tvShow ? "TV" : "Movies" }
}
nonisolated struct TMDBKeyword: Codable, Sendable { let id: Int; let name: String }
nonisolated struct TMDBKeywordPage: Codable, Sendable { let results: [TMDBKeyword] }
nonisolated struct TMDBTVShowSearchResult: Codable, Sendable {
    let id: Int; let name: String; let originalName: String?; let popularity: Double?; let voteCount: Int?
}
nonisolated struct TMDBMovieSearchResult: Codable, Sendable {
    let id: Int; let title: String; let originalTitle: String?; let popularity: Double?; let voteCount: Int?
}
nonisolated struct TVPage: Codable, Sendable { let results: [TMDBTVShowSearchResult]; let totalPages: Int? }
nonisolated struct MoviePage: Codable, Sendable { let results: [TMDBMovieSearchResult]; let totalPages: Int? }
nonisolated struct TMDBWatchProviderInfo: Codable, Sendable { let providerId: Int; let providerName: String }
nonisolated struct ProviderPage: Codable, Sendable { let results: [TMDBWatchProviderInfo] }

/// A household subscribed to Netflix, Hulu and Disney+ in the US.
final class ProviderSettings {
    static let shared = ProviderSettings()
    var selectedProviderIDs: Set<Int> = [8, 15, 337]
}

final class TMDBService {
    // `run`'s `= .shared` default argument is evaluated outside the main actor in this Swift
    // 5-mode build.
    nonisolated static let shared = TMDBService()
    let currentRegion = "US"
    private let apiKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? ""
    private var cache: [URL: Data] = [:]
    private(set) var requestCount = 0

    func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        components.queryItems = query.merging(["api_key": apiKey]) { first, _ in first }
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let url = components.url!
        let data: Data
        if let cached = cache[url] {
            data = cached
        } else {
            requestCount += 1
            var (fetched, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 429 {
                try await Task.sleep(for: .seconds(2))
                (fetched, response) = try await URLSession.shared.data(from: url)
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            cache[url] = fetched
            data = fetched
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    func fetchWatchProviders() async throws -> [TMDBWatchProviderInfo] {
        async let tv: ProviderPage = get("/watch/providers/tv", ["watch_region": currentRegion])
        async let movie: ProviderPage = get("/watch/providers/movie", ["watch_region": currentRegion])
        return try await movie.results + tv.results
    }
    func searchKeywords(query: String) async throws -> [TMDBKeyword] {
        let page: TMDBKeywordPage = try await get("/search/keyword", ["query": query]); return page.results
    }
    func discoverTVShows(filters: [String: String]) async throws -> [TMDBTVShowSearchResult] {
        let page: TVPage = try await get("/discover/tv", filters); return page.results
    }
    func discoverMovies(filters: [String: String]) async throws -> [TMDBMovieSearchResult] {
        let page: MoviePage = try await get("/discover/movie", filters); return page.results
    }

    /// The app's title search: pages 1–2, deduped, re-ranked by `SearchRanking`.
    func searchTVShows(query: String) async throws -> [TMDBTVShowSearchResult] {
        let results: [TMDBTVShowSearchResult] = try await pages("/search/tv", query) { (page: TVPage) in (page.results, page.totalPages) }
        return SearchRanking.ranked(results, query: query) {
            SearchRanking.Signals(title: $0.name, alternateTitle: $0.originalName, popularity: $0.popularity, voteCount: $0.voteCount)
        }
    }
    func searchMovies(query: String) async throws -> [TMDBMovieSearchResult] {
        let results: [TMDBMovieSearchResult] = try await pages("/search/movie", query) { (page: MoviePage) in (page.results, page.totalPages) }
        return SearchRanking.ranked(results, query: query) {
            SearchRanking.Signals(title: $0.title, alternateTitle: $0.originalTitle, popularity: $0.popularity, voteCount: $0.voteCount)
        }
    }
    private func pages<Page: Decodable, R>(
        _ path: String, _ query: String, _ unpack: (Page) -> ([R], Int?)
    ) async throws -> [R] {
        let (first, total) = unpack(try await get(path, ["query": query, "page": "1"]) as Page)
        guard (total ?? 1) > 1, let second: Page = try? await get(path, ["query": query, "page": "2"]) else { return first }
        return first + unpack(second).0
    }
}

// MARK: - Cases

enum Expectation {
    /// One of `titles` is among the first `top` rows the user sees for `type`.
    case finds([String], MediaType, top: Int = 10)
    /// No described section for either type.
    case noSection
    /// A described section with rows for `type`.
    case section(MediaType)
}

struct Case {
    let query: String
    let expectations: [Expectation]
    /// Why it fails today, if it's a known gap.
    var gap: String?

    init(_ query: String, _ expectations: Expectation..., gap: String? = nil) {
        self.query = query; self.expectations = expectations; self.gap = gap
    }
}

let cases: [Case] = [
    // Descriptions
    Case("hulu hockey comedy", .finds(["Shoresy"], .tvShow, top: 3)),
    Case("slasher movies", .finds(["Scream", "Scream VI", "Scream 7", "Halloween", "X", "A Nightmare on Elm Street"], .movie)),
    Case("90s heist films", .finds(["Heat", "Reservoir Dogs", "The Usual Suspects"], .movie)),
    Case("time travel romance", .finds(["About Time", "The Time Traveler's Wife", "Palm Springs"], .movie)),
    Case("comedies about chefs", .finds(["The Bear"], .tvShow), .finds(["Ratatouille"], .movie)),
    Case("zombie movies", .finds(["World War Z", "Resident Evil", "28 Days Later", "Zombieland", "28 Years Later"], .movie)),
    Case("christmas movies on disney plus", .finds(["The Nightmare Before Christmas", "Home Alone", "The Santa Clause"], .movie)),
    Case("scary shows on netflix", .finds(["Stranger Things", "Wednesday", "The Haunting of Hill House"], .tvShow)),
    Case("rom coms from the 2000s", .finds(["50 First Dates", "The Proposal", "Love Actually", "How to Lose a Guy in 10 Days"], .movie)),
    Case("heist movies", .finds(["Ocean's Eleven", "Inception", "Baby Driver", "The Italian Job"], .movie)),
    Case("anime series", .finds(["Naruto", "Attack on Titan", "One Piece", "Demon Slayer: Kimetsu no Yaiba", "Jujutsu Kaisen"], .tvShow)),
    Case("western movies", .finds(["Django Unchained", "The Good, the Bad and the Ugly", "Unforgiven", "True Grit"], .movie)),
    Case("space movies", .finds(["Interstellar", "Gravity", "The Martian", "2001: A Space Odyssey"], .movie)),
    Case("boxing movies", .finds(["Rocky", "Creed", "Raging Bull", "Million Dollar Baby"], .movie)),
    Case("vampire shows", .finds(["The Vampire Diaries", "What We Do in the Shadows", "True Blood", "Interview with the Vampire"], .tvShow)),
    Case("shark movies", .finds(["Jaws", "The Meg", "Meg 2: The Trench", "Deep Blue Sea"], .movie)),
    Case("dinosaur movies", .finds(["Jurassic Park", "Jurassic World", "Jurassic World Rebirth"], .movie)),
    Case("superhero shows", .finds(["The Boys", "Invincible", "Daredevil: Born Again", "Peacemaker"], .tvShow)),
    Case("mafia movies", .finds(["The Godfather", "Goodfellas", "The Irishman", "Casino"], .movie)),
    Case("kids shows on disney plus", .finds(["Bluey", "Mickey Mouse Clubhouse", "Phineas and Ferb"], .tvShow)),
    Case("80s horror", .finds(["The Shining", "A Nightmare on Elm Street", "The Thing", "Friday the 13th", "Poltergeist"], .movie)),
    Case("true crime documentaries", .finds(["Making a Murderer", "The Jinx", "Tiger King", "American Murder"], .tvShow)),
    Case("high school comedy movies", .finds(["Superbad", "Mean Girls", "Ferris Bueller's Day Off", "Easy A"], .movie)),
    // Genre words that are also titles
    Case("comedy", .section(.tvShow), .section(.movie)),
    Case("kids", .section(.tvShow)),
    Case("horror", .section(.movie)),
    Case("documentary", .section(.movie)),
    Case("1917", .finds(["1917"], .movie, top: 1)),
    // Names: the title search's job, no section
    Case("family guy", .noSection, .finds(["Family Guy"], .tvShow, top: 1)),
    Case("the office", .noSection, .finds(["The Office"], .tvShow, top: 2)),
    Case("mad max", .noSection, .finds(["Mad Max"], .movie, top: 3)),
    Case("new amsterdam", .noSection, .finds(["New Amsterdam"], .tvShow, top: 2)),
    Case("apple cider vinegar", .noSection, .finds(["Apple Cider Vinegar"], .tvShow, top: 1)),
    Case("scary movie", .finds(["Scary Movie"], .movie, top: 1)),
    Case("breaking bad", .noSection, .finds(["Breaking Bad"], .tvShow, top: 1)),
    Case("the walking dead", .noSection, .finds(["The Walking Dead"], .tvShow, top: 1)),
    Case("arrow", .noSection, .finds(["Arrow"], .tvShow, top: 1)),
    Case("war", .finds(["War"], .movie, top: 3)),
    Case("the office us", .noSection),
    // Known gaps — the to-do list
    Case("hulu shoresy", .finds(["Shoresy"], .tvShow, top: 3),
         gap: "a service word plus a name: the title search gets the whole string"),
    Case("zombies", .finds(["The Walking Dead", "World War Z", "Zombieland"], .movie),
         gap: "keyword-only query that's also a title (Zombies) isn't interpreted"),
    Case("tom hanks movies", .finds(["Forrest Gump", "Cast Away", "Saving Private Ryan", "Toy Story"], .movie),
         gap: "people aren't searched"),
    Case("christopher nolan", .finds(["Inception", "Oppenheimer", "Interstellar", "The Dark Knight"], .movie),
         gap: "people aren't searched"),
    Case("zendaya", .finds(["Euphoria"], .tvShow), gap: "people aren't searched"),
    Case("shows like ted lasso", .finds(["Shrinking", "Schitt's Creek", "Abbott Elementary", "Ghosts", "The Good Place"], .tvShow),
         gap: "\"like X\" isn't understood"),
    Case("movies like inception", .finds(["Interstellar", "Tenet", "The Matrix", "Shutter Island", "The Prestige"], .movie),
         gap: "\"like X\" isn't understood"),
    Case("show about a chemistry teacher who makes meth", .finds(["Breaking Bad"], .tvShow),
         gap: "plot recall needs a model"),
    Case("movie where a guy relives the same day", .finds(["Groundhog Day", "Palm Springs", "Edge of Tomorrow"], .movie),
         gap: "plot recall needs a model"),
    Case("cozy mystery shows", .finds(["Only Murders in the Building", "Murder, She Wrote", "Poker Face", "Death in Paradise"], .tvShow),
         gap: "mood words aren't TMDB keywords"),
    Case("sports dramedy", .finds(["Ted Lasso", "Shoresy", "Friday Night Lights"], .tvShow),
         gap: "\"sports\" and \"dramedy\" aren't TMDB keywords"),
    Case("korean dramas", .finds(["Squid Game", "Crash Landing on You", "Goblin", "Extraordinary Attorney Woo", "When Life Gives You Tangerines"], .tvShow),
         gap: "language/country isn't a filter (with_original_language)"),
]

// MARK: - Running

/// What the app would show for one query: per type, the rows in on-screen order.
struct Outcome {
    var rows: [MediaType: [String]] = [:]
    var described: DescriptiveSearch.Results?
    var titleMatch = SearchRanking.TitleMatch.none

    func hasSection(_ type: MediaType) -> Bool {
        guard let described else { return false }
        return type == .tvShow ? !described.tvShows.isEmpty : !described.movies.isEmpty
    }
}

func normalizedTitle(_ title: String) -> String { SearchRanking.normalized(title) }

func outcome(for query: String) async -> Outcome {
    let service = TMDBService.shared
    async let tvTitles = (try? service.searchTVShows(query: query)) ?? []
    async let movieTitles = (try? service.searchMovies(query: query)) ?? []
    let (tv, movies) = await (tvTitles, movieTitles)
    var outcome = Outcome()
    outcome.titleMatch = max(
        tv.first.map { SearchRanking.titleMatch($0.name, query: query, voteCount: $0.voteCount) } ?? .none,
        movies.first.map { SearchRanking.titleMatch($0.title, query: query, voteCount: $0.voteCount) } ?? .none
    )
    outcome.described = await DescriptiveSearch.run(query: query, titleMatch: outcome.titleMatch)

    // Same order and dedupe as the add sheet / Discover: the described section leads unless the
    // type's top title hit is a strong match, and a title is listed only in the first section.
    func arrange(titles: [(Int, String)], topVotes: Int?, described: [(Int, String)]) -> [String] {
        let leads = !(titles.first.map { SearchRanking.isStrongTitleMatch($0.1, query: query, voteCount: topVotes) } ?? false)
        let (first, second) = leads ? (described, titles) : (titles, described)
        let shown = Set(first.map(\.0))
        return (first + second.filter { !shown.contains($0.0) }).map(\.1)
    }
    outcome.rows[.tvShow] = arrange(titles: tv.map { ($0.id, $0.name) }, topVotes: tv.first?.voteCount,
                                    described: outcome.described?.tvShows.map { ($0.id, $0.name) } ?? [])
    outcome.rows[.movie] = arrange(titles: movies.map { ($0.id, $0.title) }, topVotes: movies.first?.voteCount,
                                   described: outcome.described?.movies.map { ($0.id, $0.title) } ?? [])
    return outcome
}

/// nil when the expectation holds, else what went wrong.
func failure(_ expectation: Expectation, _ outcome: Outcome) -> String? {
    switch expectation {
    case .finds(let titles, let type, let top):
        let rows = outcome.rows[type] ?? []
        let wanted = Set(titles.map(normalizedTitle))
        if let index = rows.prefix(top).firstIndex(where: { wanted.contains(normalizedTitle($0)) }) {
            _ = index
            return nil
        }
        let position = rows.firstIndex { wanted.contains(normalizedTitle($0)) }.map { " (found at #\($0 + 1))" } ?? ""
        return "\(type): none of \(titles.prefix(3).joined(separator: ", "))… in top \(top)\(position); saw \(rows.prefix(5).joined(separator: ", "))"
    case .noSection:
        guard let described = outcome.described, !described.tvShows.isEmpty || !described.movies.isEmpty else { return nil }
        let type: MediaType = described.tvShows.isEmpty ? .movie : .tvShow
        return "unexpected section \"\(described.summary(for: type))\""
    case .section(let type):
        return outcome.hasSection(type) ? nil : "\(type): no described section (title match \(outcome.titleMatch))"
    }
}

@main
struct SearchChecks {
    static func main() async {
        guard !(ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? "").isEmpty else {
            print("TMDB_API_KEY is not set."); exit(2)
        }
        let filter = CommandLine.arguments.dropFirst().first
        var passed = 0, regressions: [String] = [], promoted: [String] = [], gaps = 0, total = 0
        for testCase in cases where filter == nil || testCase.query.contains(filter!) {
            total += 1
            let result = await outcome(for: testCase.query)
            let failures = testCase.expectations.compactMap { failure($0, result) }
            switch (failures.isEmpty, testCase.gap) {
            case (true, nil):
                passed += 1
            case (true, .some):
                passed += 1
                promoted.append(testCase.query)
                print("✓ \(testCase.query) — known gap now passes; drop its `gap`")
            case (false, nil):
                regressions.append(testCase.query)
                print("✗ \(testCase.query)")
                failures.forEach { print("    \($0)") }
            case (false, .some(let reason)):
                gaps += 1
                print("· \(testCase.query) — gap: \(reason)")
                failures.forEach { print("    \($0)") }
            }
        }
        print("\nSearch checks: \(passed)/\(total) pass · \(gaps) known gaps · \(regressions.count) regressions · \(TMDBService.shared.requestCount) TMDB requests")
        if !promoted.isEmpty { print("Now passing: \(promoted.joined(separator: ", "))") }
        exit(regressions.isEmpty ? 0 : 1)
    }
}
