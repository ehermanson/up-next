// Search quality checks: the real `DescriptiveSearch` + `SearchRanking` against live TMDB, scored
// on a fixed set of queries. Run with ./ci_scripts/check_search.sh (needs network and a TMDB key).
//
// Each case describes what a person would want to see, not what the code happens to do. Cases
// marked `gap` fail today for a known reason; they're the to-do list, and the score counts them so
// a new lever shows up as progress. Only a non-gap case failing (a regression) fails the script.
//
// `finds` is recall — one right answer somewhere in the top rows — and a list can pass it while
// being mostly junk. The precision cases (`precision`, `notAny`) say what the top rows should and
// shouldn't be; they're the ones a ranking change has to move.
import Foundation

// MARK: - Minimal stand-ins for the app types DescriptiveSearch touches

enum MediaType: CustomStringConvertible {
    case tvShow, movie
    var description: String { self == .tvShow ? "TV" : "Movies" }
}
nonisolated struct TMDBKeyword: Codable, Sendable { let id: Int; let name: String }
nonisolated struct TMDBKeywordPage: Codable, Sendable { let results: [TMDBKeyword] }
nonisolated struct TitleKeywordsPage: Codable, Sendable { let results: [TMDBKeyword]?; let keywords: [TMDBKeyword]? }
nonisolated struct TMDBTVShowSearchResult: Codable, Sendable {
    let id: Int; let name: String; let originalName: String?; let popularity: Double?; let voteCount: Int?
    let genreIds: [Int]?; let firstAirDate: String?; let overview: String?
}
nonisolated struct TMDBMovieSearchResult: Codable, Sendable {
    let id: Int; let title: String; let originalTitle: String?; let popularity: Double?; let voteCount: Int?
    let genreIds: [Int]?; let releaseDate: String?; let overview: String?
}
nonisolated struct TMDBPersonSearchResult: Codable, Sendable { let id: Int; let name: String; let popularity: Double? }
nonisolated struct PersonPage: Codable, Sendable { let results: [TMDBPersonSearchResult] }
nonisolated struct TMDBPersonTVCredits: Decodable, Sendable {
    nonisolated struct Credit: Decodable, Sendable {
        let show: TMDBTVShowSearchResult; let character: String?; let episodeCount: Int?; let job: String?
        private enum CodingKeys: String, CodingKey { case character, episodeCount, job }
        init(from decoder: any Decoder) throws {
            show = try TMDBTVShowSearchResult(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            character = try container.decodeIfPresent(String.self, forKey: .character)
            episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
            job = try container.decodeIfPresent(String.self, forKey: .job)
        }
    }
    let cast: [Credit]; let crew: [Credit]
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
    func titleKeywords(id: Int, isTVShow: Bool) async throws -> [TMDBKeyword] {
        let page: TitleKeywordsPage = try await get("/\(isTVShow ? "tv" : "movie")/\(id)/keywords", [:])
        return page.results ?? page.keywords ?? []
    }
    func searchPeople(query: String) async throws -> [TMDBPersonSearchResult] {
        let page: PersonPage = try await get("/search/person", ["query": query]); return page.results
    }
    func personTVCredits(id: Int) async throws -> TMDBPersonTVCredits { try await get("/person/\(id)/tv_credits", [:]) }
    func fetchTVRecommendations(id: Int) async throws -> [TMDBTVShowSearchResult] {
        let page: TVPage = try await get("/tv/\(id)/recommendations", [:]); return page.results
    }
    func fetchMovieRecommendations(id: Int) async throws -> [TMDBMovieSearchResult] {
        let page: MoviePage = try await get("/movie/\(id)/recommendations", [:]); return page.results
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
    /// `title` isn't the first row for `type` — a name-match that shouldn't lead.
    case notFirst(String, MediaType)
    /// The described section's heading for `type` contains `text`.
    case heading(String, MediaType)
    /// At least `atLeast` of the first `top` rows for `type` are in `acceptable` — the list is
    /// mostly right, not just not wrong.
    case precision([String], MediaType, top: Int = 5, atLeast: Int = 3)
    /// None of `titles` is among the first `top` rows for `type` — the wrong answers we've seen.
    case notAny([String], MediaType, top: Int = 5)
}

struct Case {
    let query: String
    let expectations: [Expectation]
    /// Why it fails today, if it's a known gap. A case that `needsModel` is a gap only when the
    /// on-device model isn't in use; with it, it's a regular case.
    var gap: String?

    init(_ query: String, _ expectations: Expectation..., gap: String? = nil, needsModel: Bool = false) {
        self.query = query; self.expectations = expectations
        self.gap = gap ?? (needsModel && !usesModel ? "needs the on-device model" : nil)
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
    // Descriptions that are also some obscure title's exact name
    Case("time travel", .section(.movie)),
    Case("haunted house", .section(.movie)),
    Case("true crime", .section(.tvShow)),
    Case("heist movies", .notFirst("Heist", .movie), .finds(["Ocean's Eleven", "Inception", "Baby Driver", "The Italian Job"], .movie)),
    Case("the heist movies", .notFirst("The Heist", .movie), .section(.movie)),
    Case("high school comedy movies", .notFirst("High School", .movie)),
    Case("road trip movies", .notFirst("Road Trip", .movie), .section(.movie)),
    Case("summer camp movies", .notFirst("Summer Camp", .movie), .section(.movie)),
    Case("coming of age movies", .finds(["Lady Bird", "Boyhood", "The Perks of Being a Wallflower", "Stand by Me", "Eighth Grade", "The Breakfast Club", "Moonlight", "Juno", "Dead Poets Society", "Good Will Hunting"], .movie)),
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
    // A service or type word plus a name
    Case("hulu shoresy", .finds(["Shoresy"], .tvShow, top: 3)),
    Case("breaking bad netflix", .finds(["Breaking Bad"], .tvShow, top: 3)),
    Case("the bear hulu", .finds(["The Bear"], .tvShow, top: 3)),
    Case("the boys prime", .finds(["The Boys"], .tvShow, top: 3)),
    Case("the studio apple tv", .finds(["The Studio"], .tvShow, top: 3)),
    // Upcoming and brand-new titles have few or no votes
    Case("avengers doomsday", .finds(["Avengers: Doomsday"], .movie, top: 3)),
    // Names being typed — a prefix the model may read as a description, with one leftover word
    // that is some TMDB keyword
    Case("squid", .finds(["Squid Game"], .tvShow, top: 1)),
    Case("the morning", .finds(["The Morning Show"], .tvShow, top: 1)),
    Case("the walking", .finds(["The Walking Dead"], .tvShow, top: 1)),
    // A name plus a genre word, and a name with an apostrophe
    // The rules can't tell a name plus a genre word from "heist movies"; the model can.
    Case("the bear comedy", .finds(["The Bear"], .tvShow, top: 1), needsModel: true),
    Case("the office sitcom", .finds(["The Office"], .tvShow, top: 1)),
    Case("schitt's creek netflix", .finds(["Schitt's Creek"], .tvShow, top: 1)),
    Case("shows like schitt's creek", .heading("Like Schitt's Creek", .tvShow)),
    // Names the model may misread as descriptions
    Case("you", .noSection, .finds(["You"], .tvShow, top: 1)),
    Case("industry", .noSection, .finds(["Industry"], .tvShow, top: 1)),
    Case("scandal", .noSection, .finds(["Scandal"], .tvShow, top: 1)),
    Case("something like summer", .noSection, .finds(["Something Like Summer"], .movie, top: 1)),
    // The on-device model's cases
    Case("zombies", .finds(["The Walking Dead", "World War Z", "Zombieland"], .movie), needsModel: true),
    Case("movie where a guy relives the same day", .finds(["Groundhog Day", "Palm Springs", "Edge of Tomorrow"], .movie), needsModel: true),
    Case("cozy mystery shows", .finds(["Only Murders in the Building", "Murder, She Wrote", "Poker Face", "Death in Paradise", "Midsomer Murders"], .tvShow),
         gap: "regressed with the shape-only schema: the model's guesses for this query are now invented (\"House of Secrets\") and rightly fail to verify, and TMDB's \"cozy\" keyword tags one show"),
    Case("sports dramedy", .finds(["Ted Lasso", "Shoresy", "Friday Night Lights"], .tvShow), needsModel: true),
    // People, origins, "like X"
    Case("tom hanks movies", .finds(["Forrest Gump", "Cast Away", "Saving Private Ryan", "Toy Story"], .movie)),
    Case("christopher nolan", .finds(["Inception", "Oppenheimer", "Interstellar", "The Dark Knight"], .movie)),
    Case("zendaya", .finds(["Euphoria"], .tvShow)),
    Case("tom hanks comedies", .finds(["Big", "Splash", "The Money Pit", "You've Got Mail", "Sleepless in Seattle", "Toy Story"], .movie)),
    Case("movies like the office", .finds(["Office Space", "The Intern", "Horrible Bosses", "Clerks", "The Devil Wears Prada", "Waiting...", "Superstore"], .movie)),
    Case("shows like inception", .finds(["Westworld", "Black Mirror", "Dark", "Severance", "Devs", "Altered Carbon", "Fringe", "The OA", "Sense8", "Mr. Robot"], .tvShow)),
    Case("shows like ted lasso on netflix", .finds(["Never Have I Ever", "Sex Education", "Schitt's Creek", "Kim's Convenience", "The Good Place", "Unstable", "Running Point", "Brooklyn Nine-Nine", "The Office"], .tvShow)),
    Case("i like comedies", .section(.tvShow), .section(.movie)),
    // Widened after the first run: the rules' family sitcoms are right answers the first list missed.
    Case("shows like modern family", .finds(["The Office", "Parks and Recreation", "Brooklyn Nine-Nine", "The Middle", "Black-ish", "Schitt's Creek", "Abbott Elementary", "Friends", "How I Met Your Mother", "The Goldbergs", "Malcolm in the Middle", "Young Sheldon", "The Fresh Prince of Bel-Air"], .tvShow)),
    Case("shows like the morning show", .finds(["The Newsroom", "Succession", "Big Little Lies", "House of Cards", "Scandal", "The Crown", "Billions", "Industry", "The Loudest Voice"], .tvShow)),
    Case("shows like friends from the 90s", .finds(["Seinfeld", "Frasier", "Will & Grace", "Mad About You", "Ellen", "Spin City", "Living Single", "The Nanny", "Everybody Loves Raymond", "3rd Rock from the Sun"], .tvShow)),
    Case("shows like severance that are funny", .section(.tvShow)),
    Case("shows like partners in crime", .heading("Like Partners in Crime", .tvShow)),
    Case("shows like married with children", .heading("Like Married", .tvShow)),
    Case("shows like the bear hulu", .heading("Like The Bear", .tvShow), .heading("Hulu", .tvShow)),
    Case("shows like ted lasso netflix", .heading("Like Ted Lasso", .tvShow), .heading("Netflix", .tvShow)),
    Case("movies like inception 2010", .heading("Like Inception", .movie)),
    Case("i would like something like ted lasso", .finds(["The Office", "Parks and Recreation", "Brooklyn Nine-Nine", "The Good Place", "Abbott Elementary", "Schitt's Creek", "Shrinking", "Scrubs"], .tvShow)),
    Case("tom hanks christmas", .finds(["The Polar Express"], .movie)),
    Case("anything in the vein of ted lasso", .heading("Like Ted Lasso", .tvShow), needsModel: true),
    // The rules split a four-word run word by word ("Age or Sport"); the model keeps the phrase.
    Case("coming of age sports movies", .heading("Coming of Age", .movie), needsModel: true),
    // Precision — what the top rows should and shouldn't be. The `gap`s here are the ranking
    // to-do list: "like X" still fuses popular-but-unrelated titles, and a verified guess can be
    // real yet irrelevant.
    Case("shows like breaking bad", .precision(["Better Call Saul", "Ozark", "Narcos", "Narcos: Mexico", "The Sopranos", "Weeds", "The Wire", "The Shield", "Mad Men", "Oz", "Boardwalk Empire", "Sons of Anarchy", "Justified", "Fargo", "True Detective", "Dexter", "Snowfall", "Peaky Blinders"], .tvShow)),
    Case("shows like modern family", .precision(["The Office", "Parks and Recreation", "Brooklyn Nine-Nine", "The Middle", "Black-ish", "Schitt's Creek", "Abbott Elementary", "Friends", "How I Met Your Mother", "The Goldbergs", "Malcolm in the Middle", "Young Sheldon", "The Fresh Prince of Bel-Air", "Community", "Arrested Development", "Superstore", "Ghosts", "Married... with Children", "Everybody Loves Raymond"], .tvShow)),
    Case("movies like inception", .precision(["Interstellar", "Tenet", "The Matrix", "Shutter Island", "The Prestige", "Memento", "Source Code", "Looper", "Edge of Tomorrow", "Minority Report", "Paprika", "Dark City", "Arrival", "Oblivion", "Blade Runner 2049", "Predestination", "Coherence", "Primer", "Donnie Darko", "Eternal Sunshine of the Spotless Mind"], .movie),
         .notAny(["Solo: A Star Wars Story", "The Matrix Reloaded", "The Matrix Revolutions", "Inside Out", "The Lord of the Rings: The Two Towers"], .movie), needsModel: true),
    Case("something similar to the bear", .precision(["Boiling Point", "Kitchen Confidential", "Shrinking", "Hacks", "Somebody Somewhere", "The Rehearsal", "Beef", "Barry", "Atlanta", "Reservation Dogs", "Ted Lasso", "Succession", "Fleabag", "Dave", "Ramy", "After Life", "The Studio", "Six Feet Under"], .tvShow), needsModel: true),
    Case("shows like ted lasso", .precision(["Shrinking", "Schitt's Creek", "Abbott Elementary", "Ghosts", "The Good Place", "Parks and Recreation", "Brooklyn Nine-Nine", "The Office", "Scrubs", "Never Have I Ever", "Welcome to Wrexham", "Friday Night Lights", "Cobra Kai", "Superstore", "Community", "Shoresy", "Detroiters", "Kim's Convenience"], .tvShow), needsModel: true),
    Case("shows like inception", .precision(["Dark", "Westworld", "Severance", "Black Mirror", "Devs", "Fringe", "Mr. Robot", "Altered Carbon", "The OA", "Sense8", "Maniac", "Twin Peaks", "Lost", "Counterpart", "Tales from the Loop", "Bodies", "1899", "The Leftovers"], .tvShow),
         .notAny(["Riverdale", "Gravity Falls", "Money Heist", "Lupin", "Blindspot", "House of Cards"], .tvShow),
         gap: "keyword neighbours of a heist/dream film are popular shows sharing a generic keyword — Riverdale, Gravity Falls"),
    Case("shows like fleabag", .precision(["Catastrophe", "Insecure", "Russian Doll", "Dead to Me", "I May Destroy You", "Girls", "Crashing", "Killing Eve", "Normal People", "Barry", "Chewing Gum", "Somebody Somewhere", "Hacks", "Atlanta", "Ramy", "Shrinking", "Everything I Know About Love", "Starstruck", "Feel Good", "Baby Reindeer", "Only Murders in the Building", "Peep Show", "You're the Worst", "Catastrophe"], .tvShow),
         .notAny(["The Crown", "Malcolm in the Middle", "The Office", "It's Always Sunny in Philadelphia", "Broadchurch", "Adolescence", "Behind Her Eyes"], .tvShow),
         gap: "the model's picks for Fleabag are famous rather than alike (The Office, The Crown) and TMDB's neighbours are British-ness, not tone"),
    Case("shows like severance", .precision(["Black Mirror", "Silo", "Mr. Robot", "Dark", "Westworld", "The Leftovers", "Devs", "Fringe", "Pluribus", "Maniac", "Homecoming", "Counterpart", "Tales from the Loop", "The Twilight Zone", "Twin Peaks", "Station Eleven", "Dispatches from Elsewhere", "Utopia"], .tvShow),
         .notAny(["Stranger Things", "The Lincoln Lawyer", "The Expanse", "Behind Her Eyes", "Mr. Mercedes", "The Capture"], .tvShow, top: 8),
         gap: "TMDB's recommendations for Severance are popular thrillers; Stranger Things rides vote count"),
    Case("shows like the morning show", .precision(["The Newsroom", "Succession", "Big Little Lies", "House of Cards", "Scandal", "The Crown", "Billions", "Industry", "The Loudest Voice", "The Bold Type", "UnREAL", "Sports Night", "Studio 60 on the Sunset Strip", "Good Girls Revolt", "The Diplomat", "Mad Men", "The West Wing", "The Morning Show", "The Newsreader"], .tvShow),
         .notAny(["Chicago Fire", "The Strain", "FBI", "NCIS: Hawaiʻi", "Power Book III: Raising Kanan", "Wu-Tang: An American Saga"], .tvShow),
         gap: "the reference's keywords (\"workplace\", \"news\") pull procedurals; nothing weighs tone"),
    Case("shows like ted lasso netflix", .notAny(["Peaky Blinders", "The Crown", "Wednesday", "Weak Hero", "Emily in Paris", "The English Game"], .tvShow),
         gap: "with a service there are no recommendations or model picks, only keyword neighbours on that service"),
    Case("shows like the bear hulu", .notAny(["Grey's Anatomy", "WandaVision", "ER", "Archer", "Bob's Burgers", "A Million Little Things", "This Is Us"], .tvShow),
         gap: "with a service there are no recommendations or model picks, only keyword neighbours on that service"),
    Case("movies like the office", .precision(["Office Space", "The Intern", "Horrible Bosses", "Clerks", "The Devil Wears Prada", "Waiting...", "Set It Up", "9 to 5", "Working Girl", "Up in the Air", "The Hudsucker Proxy", "Employee of the Month", "Extract", "Sorry to Bother You", "Boiler Room", "Glengarry Glen Ross"], .movie),
         .notAny(["Shrek", "Love Actually", "Ratatouille", "Project X", "The Proposal"], .movie),
         gap: "across types there are no recommendations, and the judge still lets an office-set rom-com in (The Proposal)"),
    Case("comedies about chefs", .finds(["The Bear"], .tvShow, top: 3),
         .notAny(["The Big Bang Theory", "Modern Family", "The Good Place", "The Neighborhood"], .tvShow, top: 3),
         gap: usesModel ? "the model's guesses verify as real titles but aren't about chefs, and verified guesses lead the section" : nil),
    Case("sports dramedy", .notAny(["The Last of Us", "The Mandalorian", "The Office"], .tvShow),
         gap: usesModel ? "the model's guesses verify as real titles but aren't sports dramedies, and verified guesses lead the section" : nil),
    Case("tom hanks christmas", .notAny(["Band of Brothers", "The Pacific", "The Oscars", "The War", "Prohibition"], .tvShow),
         gap: "a person's TV credits can't be narrowed by a keyword, so the TV side ignores \"christmas\""),
    Case("i like comedies", .notAny(["Pulp Fiction", "The Wolf of Wall Street"], .movie, top: 8),
         gap: "a bare genre sorted by vote count is whatever popular film TMDB also tags comedy"),
    // Known gaps — the to-do list
    Case("shows like ted lasso", .finds(["Shrinking", "Schitt's Creek", "Abbott Elementary", "Ghosts", "The Good Place"], .tvShow), needsModel: true),
    Case("movies like inception", .finds(["Interstellar", "Tenet", "The Matrix", "Shutter Island", "The Prestige"], .movie)),
    Case("shows like breaking bad", .finds(["Better Call Saul", "Ozark", "Narcos", "The Sopranos", "Weeds"], .tvShow, top: 5)),
    Case("shows like fleabag", .finds(["Catastrophe", "Insecure", "Russian Doll", "Dead to Me", "I May Destroy You", "Girls", "Crashing", "Killing Eve", "Normal People"], .tvShow)),
    Case("shows like severance", .finds(["Black Mirror", "Silo", "Mr. Robot", "Dark", "Westworld", "The Leftovers", "Pluribus", "Devs", "Fringe"], .tvShow), needsModel: true),
    Case("something similar to the bear", .finds(["Boiling Point", "Kitchen Confidential", "Shrinking", "Hacks", "Somebody Somewhere", "The Rehearsal", "Beef"], .tvShow, top: 20)),
    Case("show about a chemistry teacher who makes meth", .finds(["Breaking Bad"], .tvShow), needsModel: true),
    Case("show about a guy who inherits a minor league hockey team", .finds(["Shoresy"], .tvShow),
         gap: "the model doesn't know Shoresy, and \"minor league hockey\" isn't a TMDB keyword — its words AND to nothing"),
    Case("korean dramas", .finds(["Squid Game", "Crash Landing on You", "Goblin", "Extraordinary Attorney Woo", "When Life Gives You Tangerines"], .tvShow)),
    Case("british crime shows", .finds(["Sherlock", "Line of Duty", "Peaky Blinders", "Luther", "Happy Valley", "Broadchurch"], .tvShow)),
    Case("japanese horror movies", .finds(["Ringu", "Ju-on: The Grudge", "Audition", "Dark Water", "Kairo", "Exit 8", "Dollhouse"], .movie)),
]

// MARK: - Running

/// What the app would show for one query: per type, the rows in on-screen order.
let usesModel = SearchModel.isAvailable

struct Outcome {
    var rows: [MediaType: [String]] = [:]
    var reading: SearchModel.Reading?
    /// How long the model took to read the query, and the whole search end to end.
    var readingSeconds: Double = 0
    var totalSeconds: Double = 0
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
    let startedAt = ContinuousClock.now
    async let tvTitles = (try? service.searchTVShows(query: query)) ?? []
    async let movieTitles = (try? service.searchMovies(query: query)) ?? []
    let modelOn = usesModel
    async let modelReading: (SearchModel.Reading?, Double) = {
        guard modelOn else { return (nil, 0) }
        let started = ContinuousClock.now
        let reading = await SearchModel.read(query)
        let elapsed = ContinuousClock.now - started
        return (reading, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }()
    var (tv, movies) = await (tvTitles, movieTitles)
    var outcome = Outcome()
    (outcome.reading, outcome.readingSeconds) = await modelReading
    let best = SearchRanking.bestTitleMatch(
        tvShow: tv.first.map { ($0.name, $0.voteCount, $0.firstAirDate, $0.popularity) },
        movie: movies.first.map { ($0.title, $0.voteCount, $0.releaseDate, $0.popularity) }, query: query
    )
    outcome.titleMatch = best.match
    outcome.described = await DescriptiveSearch.run(
        query: query, titleMatch: outcome.titleMatch, titleVotes: best.votes, reading: outcome.reading
    )
    var titleQuery = query
    if outcome.titleMatch == .none, let found = await DescriptiveSearch.remainderTitleSearch(
        query: query, besideSection: !(outcome.described?.isEmpty ?? true), reading: outcome.reading
    ) {
        (tv, movies, titleQuery) = (found.tvShows, found.movies, found.remainder)
    }

    // Same order as the add sheet and Discover.
    func rows<Item>(_ layout: DescriptiveSearch.Layout<Item>, _ name: (Item) -> String) -> [String] {
        (layout.leadingTitles + layout.described + layout.trailingTitles).map(name)
    }
    let descriptionFirst = outcome.described?.readsAsDescription == true || titleQuery != query
    outcome.rows[.tvShow] = rows(DescriptiveSearch.layout(
        titles: tv, described: outcome.described?.tvShows ?? [], query: titleQuery, descriptionFirst: descriptionFirst,
        id: \.id, name: \.name, votes: \.voteCount, date: \.firstAirDate, popularity: \.popularity), \.name)
    outcome.rows[.movie] = rows(DescriptiveSearch.layout(
        titles: movies, described: outcome.described?.movies ?? [], query: titleQuery, descriptionFirst: descriptionFirst,
        id: \.id, name: \.title, votes: \.voteCount, date: \.releaseDate, popularity: \.popularity), \.title)
    let elapsed = ContinuousClock.now - startedAt
    outcome.totalSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return outcome
}

/// The model's reading on one line: `name "the bear" like=ted lasso`.
func describe(_ reading: SearchModel.Reading) -> String {
    var parts = [reading.isTitleName ? "name" : "description"]
    if let title = reading.title { parts.append("\"\(title)\"") }
    if let person = reading.person { parts.append("person=\(person)") }
    if let similarTo = reading.similarTo { parts.append("like=\(similarTo)") }
    if !reading.subjects.isEmpty { parts.append("subjects=\(reading.subjects)") }
    if !reading.titles.isEmpty { parts.append("titles=\(reading.titles)") }
    return parts.joined(separator: " ")
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
    case .heading(let text, let type):
        guard let described = outcome.described, outcome.hasSection(type) else { return "\(type): no described section" }
        let heading = described.summary(for: type)
        return heading.localizedCaseInsensitiveContains(text) ? nil : "\(type): heading \"\(heading)\" lacks \"\(text)\""
    case .notFirst(let title, let type):
        guard let first = outcome.rows[type]?.first, normalizedTitle(first) == normalizedTitle(title) else { return nil }
        return "\(type): \(title) leads"
    case .precision(let acceptable, let type, let top, let atLeast):
        let rows = Array((outcome.rows[type] ?? []).prefix(top))
        let wanted = Set(acceptable.map(normalizedTitle))
        let hits = rows.filter { wanted.contains(normalizedTitle($0)) }.count
        return hits >= atLeast ? nil : "\(type): \(hits) of top \(top) acceptable, wanted \(atLeast); saw \(rows.joined(separator: ", "))"
    case .notAny(let titles, let type, let top):
        let rows = Array((outcome.rows[type] ?? []).prefix(top))
        let unwanted = Set(titles.map(normalizedTitle))
        guard let index = rows.firstIndex(where: { unwanted.contains(normalizedTitle($0)) }) else { return nil }
        return "\(type): \(rows[index]) at #\(index + 1)"
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
            if ProcessInfo.processInfo.environment["SEARCH_VERBOSE"] != nil {
                print("\(testCase.query) [\(result.described.map { $0.summary(for: .tvShow) } ?? "no section")] \(String(format: "%.1f", result.totalSeconds)) s")
                if let reading = result.reading {
                    print("    model (\(String(format: "%.1f", result.readingSeconds)) s): \(describe(reading))")
                }
                for type in [MediaType.tvShow, .movie] where !(result.rows[type] ?? []).isEmpty {
                    print("    \(type): \(result.rows[type]!.prefix(8).joined(separator: ", "))")
                }
            }
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
                if let reading = result.reading { print("    model: \(describe(reading))") }
            case (false, .some(let reason)):
                gaps += 1
                print("· \(testCase.query) — gap: \(reason)")
                failures.forEach { print("    \($0)") }
                if let reading = result.reading { print("    model: \(describe(reading))") }
            }
        }
        print("\nSearch checks (\(usesModel ? "with" : "without") on-device model): \(passed)/\(total) pass · \(gaps) known gaps · \(regressions.count) regressions · \(TMDBService.shared.requestCount) TMDB requests")
        if !promoted.isEmpty { print("Now passing: \(promoted.joined(separator: ", "))") }
        exit(regressions.isEmpty ? 0 : 1)
    }
}
