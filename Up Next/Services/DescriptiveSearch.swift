import Foundation

/// Search by description — "hulu hockey comedy", "slasher movies", "90s heist films" — for when
/// someone remembers what a title is about but not what it's called.
///
/// `/search` only matches names, so the query is interpreted into `/discover` filters instead.
/// Words are matched, longest phrase first, against what TMDB can filter on: streaming services,
/// genres, "movie"/"show", years and decades. Whatever's left is looked up as TMDB keywords, which
/// is where subject matter lives ("ice hockey", "slasher", "time travel"). The title search still
/// runs alongside; this adds a second section, never replaces it.
enum DescriptiveSearch {
    /// One subject term and the keyword ids that mean it. `ids[0]` is the keyword named exactly
    /// the term (there always is one, see `matchingKeyword`) — the one used when several terms
    /// must all match (see `filters`).
    nonisolated struct Keyword: Sendable, Equatable {
        let label: String
        let ids: [Int]
    }

    /// TV and movie genre ids differ ("Science Fiction" 878 vs "Sci-Fi & Fantasy" 10765) and some
    /// genres exist for one type only (TV has no Horror) — that type falls back to the TMDB
    /// keyword named `keywordTerm`.
    struct Genre: Equatable {
        let label: String
        let tvID: Int?
        let movieID: Int?
        let keywordTerm: String
        var keyword: Keyword?

        func id(for mediaType: MediaType) -> Int? { mediaType == .tvShow ? tvID : movieID }
    }

    struct Provider: Equatable {
        let id: Int
        let name: String
        /// Matched by a nickname that's also an ordinary word ("max", "apple", "prime").
        var isNamedByCommonWord = false
    }

    struct Interpretation: Equatable {
        var mediaType: MediaType?
        var providers: [Provider] = []
        var genres: [Genre] = []
        var keywords: [Keyword] = []
        var years: ClosedRange<Int>?
        var yearsLabel: String?
        /// "new", "old", "classic" — words that are as often part of a name ("New Amsterdam").
        var yearsAreVague = false

        /// Genres, services and years — facets that only a description has. Keywords don't count
        /// (most words in a name are some TMDB keyword: "the office us" → Office, US), nor do a
        /// vague year or a service named by a common word ("Mad Max", "Apple Cider Vinegar").
        var descriptiveFacetCount: Int {
            genres.count + providers.filter { !$0.isNamedByCommonWord }.count
                + (years != nil && !yearsAreVague ? 1 : 0)
        }

        /// Facets that narrow the results, not counting the media type.
        var filterCount: Int {
            providers.count + genres.count + keywords.count + (years == nil ? 0 : 1)
        }

        /// The section heading: "Comedy · Hockey · On Hulu". `matchedAny` is set when the subjects
        /// had to be loosened from all to any, so the heading says "Hockey or Christmas".
        func summary(for mediaType: MediaType, matchedAny: Bool = false) -> String {
            let subjects = genres.filter { $0.id(for: mediaType) == nil }.map(\.label) + keywords.map(\.label)
            var parts = genres.filter { $0.id(for: mediaType) != nil }.map(\.label)
            parts += matchedAny ? [subjects.joined(separator: " or ")] : subjects
            if let yearsLabel { parts.append(yearsLabel) }
            if !providers.isEmpty {
                parts.append("On " + providers.map(\.name).joined(separator: " or "))
            }
            return parts.joined(separator: " · ")
        }
    }

    struct Results {
        /// The (trimmed) query this answers — callers show it only while that's still the query.
        let query: String
        let interpretation: Interpretation
        let tvShows: [TMDBTVShowSearchResult]
        let movies: [TMDBMovieSearchResult]
        fileprivate(set) var tvMatchedAny = false
        fileprivate(set) var moviesMatchedAny = false

        func summary(for mediaType: MediaType) -> String {
            interpretation.summary(for: mediaType, matchedAny: mediaType == .tvShow ? tvMatchedAny : moviesMatchedAny)
        }
    }

    // MARK: - Running

    /// Interprets `query` and fetches matching titles, or nil when the query doesn't read as a
    /// description. `titleMatch` is how well the title search's best hit matched what was typed:
    ///
    /// - `.exact`: TMDB has a title named after nearly every common word ("Comedy", "Kids",
    ///   "War", "Zombies"), so this alone can't mean the user typed a name. Interpreted only when
    ///   every word is a descriptive facet (see `descriptiveFacetCount`) — "comedy", "kids", "1917",
    ///   "scary movie" — but not "family guy" or "the office", which carry other words.
    /// - `.strong`: a name prefix ("the office us", "mad max fury") — interpreted only with at
    ///   least one descriptive facet.
    /// - `.none`: anything goes.
    ///
    /// The title matches still lead the list whenever they're `.strong` or better, so "kids"
    /// shows the movie *Kids* first and the Kids genre after it. A keyword-only query that hits
    /// a title ("zombies") isn't interpreted — "zombie movies" is.
    ///
    /// `mediaType` limits the fetch to one type (an add sheet scoped to TV or movies).
    static func run(
        query: String, titleMatch: SearchRanking.TitleMatch, mediaType: MediaType? = nil,
        service: TMDBService = .shared
    ) async -> Results? {
        let selected = ProviderSettings.shared.selectedProviderIDs
        // Names for the user's own services; the majors have built-in names.
        let regionProviders = selected.isSubset(of: providerFallbackNames.keys)
            ? [] : (try? await service.fetchWatchProviders()) ?? []
        let parsed = parse(query, regionProviders: regionProviders, selectedProviderIDs: selected)
        var interpretation = parsed.interpretation
        guard interpretation.filterCount > 0 || !parsed.subjectRuns.isEmpty else { return nil }
        switch titleMatch {
        case .exact: guard interpretation.descriptiveFacetCount > 0, parsed.subjectRuns.isEmpty else { return nil }
        case .strong: guard interpretation.descriptiveFacetCount > 0 else { return nil }
        case .none: break
        }

        let fallbackIndices = interpretation.genres.indices.filter {
            interpretation.genres[$0].tvID == nil || interpretation.genres[$0].movieID == nil
        }
        let fallbackTerms = fallbackIndices.map { interpretation.genres[$0].keywordTerm }
        async let subjects = resolveKeywords(in: parsed.subjectRuns, genresAfter: parsed.genreAfterRun, service: service)
        async let fallbacks = concurrentMap(fallbackTerms) {
            await resolveKeyword($0, service: service)
        }
        let (resolved, genreKeywords) = await (subjects, fallbacks)
        guard !Task.isCancelled else { return nil }
        interpretation.keywords = resolved.keywords
        for (index, keyword) in zip(fallbackIndices, genreKeywords) {
            interpretation.genres[index].keyword = keyword
        }

        // "hulu shoresy": the subject was the point, and without it the section would just be
        // Hulu's whole catalogue under a heading that claims to have understood.
        if resolved.unresolvedWords > 0, interpretation.genres.isEmpty, interpretation.keywords.isEmpty {
            return nil
        }

        let type = mediaType ?? interpretation.mediaType
        let region = service.currentRegion
        let tvFilters = type != .movie ? filters(for: .tvShow, interpretation, region: region) : nil
        let movieFilters = type != .tvShow ? filters(for: .movie, interpretation, region: region) : nil
        guard tvFilters != nil || movieFilters != nil else { return nil }

        async let tv = fetch(tvFilters) { try await service.discoverTVShows(filters: $0) }
        async let movies = fetch(movieFilters) { try await service.discoverMovies(filters: $0) }
        let (tvFetch, movieFetch) = await (tv, movies)
        guard !Task.isCancelled else { return nil }
        var results = Results(query: query, interpretation: interpretation,
                              tvShows: tvFetch.results, movies: movieFetch.results)
        results.tvMatchedAny = tvFetch.matchedAny
        results.moviesMatchedAny = movieFetch.matchedAny
        return results
    }

    /// Tried strictest first, stopping at the first that finds anything: the 50-vote floor keeps
    /// popular-but-junk titles out of a broad query ("anime"); a niche subject needs it lowered;
    /// several subjects must all match ("hockey" and "christmas") and, when nothing carries them
    /// all, any of them will do — `matchedAny` tells the heading to say so. A failed request
    /// stops the ladder: an outage isn't "no matches".
    private static func fetch<T>(
        _ filters: Filters?, _ request: ([String: String]) async throws -> [T]
    ) async -> (results: [T], matchedAny: Bool) {
        guard let filters else { return ([], false) }
        var attempts = [(filters.all, false), (filters.all.merging(["vote_count.gte": "5"]) { _, new in new }, false)]
        if let any = filters.any { attempts.append((any, true)) }
        for (attempt, matchedAny) in attempts {
            guard !Task.isCancelled, let results = try? await request(attempt) else { return ([], false) }
            if !results.isEmpty { return (results, matchedAny) }
        }
        return ([], false)
    }

    struct Filters {
        /// Every subject must match.
        let all: [String: String]
        /// Either subject may match; only with exactly two.
        let any: [String: String]?
    }

    /// TMDB's `with_keywords` takes `,` (all) or `|` (any) but not both — `a|b,c` silently
    /// collapses each group to its first id. So a single subject ORs all of its keywords ("hockey"
    /// or "ice hockey"), while several subjects AND their exact keywords only.
    static func filters(for mediaType: MediaType, _ interpretation: Interpretation, region: String) -> Filters? {
        var genreIDs: [Int] = []
        var keywordGroups = interpretation.keywords.map(\.ids)
        for genre in interpretation.genres {
            if let id = genre.id(for: mediaType) {
                genreIDs.append(id)
            } else if let keyword = genre.keyword {
                keywordGroups.append(keyword.ids)
            } else {
                // "horror shows" with no horror keyword can't be expressed for TV at all.
                return nil
            }
        }
        guard !genreIDs.isEmpty || !keywordGroups.isEmpty || !interpretation.providers.isEmpty
                || interpretation.years != nil else { return nil }

        var filters = ["sort_by": "popularity.desc", "vote_count.gte": "50"]
        if !genreIDs.isEmpty {
            filters["with_genres"] = Set(genreIDs).sorted().map(String.init).joined(separator: ",")
        }
        if !interpretation.providers.isEmpty {
            filters["with_watch_providers"] = interpretation.providers.map { String($0.id) }.joined(separator: "|")
            filters["watch_region"] = region
            filters["with_watch_monetization_types"] = "flatrate|free|ads"
        }
        if let years = interpretation.years {
            let prefix = mediaType == .tvShow ? "first_air_date" : "primary_release_date"
            filters["\(prefix).gte"] = "\(years.lowerBound)-01-01"
            filters["\(prefix).lte"] = "\(years.upperBound)-12-31"
        }
        guard keywordGroups.count > 1 else {
            if let group = keywordGroups.first {
                filters["with_keywords"] = group.map(String.init).joined(separator: "|")
            }
            return Filters(all: filters, any: nil)
        }
        var all = filters
        all["with_keywords"] = keywordGroups.compactMap(\.first).map(String.init).joined(separator: ",")
        // Past two subjects, "any" is mostly generic words ("guy who finds a dog" → Guy or Find
        // or Dog) and finds anything at all.
        guard keywordGroups.count == 2 else { return Filters(all: all, any: nil) }
        var any = filters
        any["with_keywords"] = keywordGroups.joined().map(String.init).joined(separator: "|")
        any["vote_count.gte"] = "5"
        return Filters(all: all, any: any)
    }

    // MARK: - Keywords

    /// A run of two or three subject words is tried as one keyword first ("time travel", "high
    /// school"), then word by word. Failing that, a run right before a genre word tries its last
    /// word with the genre ("true crime", "dark comedy") — otherwise "true" becomes a keyword of
    /// its own that nothing carries alongside the genre. The genre stays either way. Runs and
    /// words resolve concurrently.
    private static func resolveKeywords(
        in runs: [[String]], genresAfter: [String?], service: TMDBService
    ) async -> (keywords: [Keyword], unresolvedWords: Int) {
        let perRun = await concurrentMap(Array(zip(runs, genresAfter))) { run, genre -> [Keyword?] in
            if (2...3).contains(run.count),
               let phrase = await resolveKeyword(run.joined(separator: " "), service: service) {
                return [phrase]
            }
            var run = run
            var compound: Keyword?
            if let genre, let last = run.last,
               let keyword = await resolveKeyword("\(last) \(genre)", service: service) {
                compound = keyword
                run.removeLast()
            }
            let words = await concurrentMap(run) { await resolveKeyword($0, service: service) }
            return compound.map { words + [$0] } ?? words
        }
        var seen = Set<[Int]>()
        let keywords = perRun.joined().compactMap { $0 }.filter { seen.insert($0.ids).inserted }
        return (keywords, perRun.joined().filter { $0 == nil }.count)
    }

    /// TMDB's keyword search is fuzzy rather than plural-aware ("zombies" surfaces "zombie", but
    /// "dogs" doesn't surface "dog" and "heists" doesn't surface "heist"), so a plural-looking word
    /// is searched as typed and as its likeliest singular at once, and the results are matched
    /// against every form, singular first.
    private static func resolveKeyword(_ term: String, service: TMDBService) async -> Keyword? {
        let forms = singularForms(term)
        guard !Task.isCancelled else { return nil }
        async let typed = try? service.searchKeywords(query: term)
        async let singular = forms.count > 1 ? try? service.searchKeywords(query: forms[0]) : []
        let results = await (typed ?? []) + (singular ?? [])
        var seen = Set<Int>()
        return matchingKeyword(results.filter { seen.insert($0.id).inserted }, forms: forms)
    }

    /// Keywords named exactly one of `forms` (earlier forms first), plus two-word kinds of a
    /// one-word term ("ice hockey", "teen slasher") — the modifier-first shape is reliably a
    /// subtype, while the term-first one ("hockey mask") is usually a prop. Kinds only widen an
    /// exact match; without one the term isn't a TMDB subject. TMDB's search is fuzzy, so
    /// everything else is noise.
    static func matchingKeyword(_ keywords: [TMDBKeyword], forms: [String]) -> Keyword? {
        let oneWord = !forms.contains { $0.contains(" ") }
        var exact: [(rank: Int, keyword: TMDBKeyword)] = []
        var kinds: [Int] = []
        for keyword in keywords {
            let name = SearchRanking.normalized(keyword.name)
            if let rank = forms.firstIndex(of: name) {
                exact.append((rank, keyword))
            } else if oneWord, case let words = name.split(separator: " "), words.count == 2,
                      forms.contains(String(words[1])) {
                kinds.append(keyword.id)
            }
        }
        exact.sort { $0.rank < $1.rank }
        guard let best = exact.first else { return nil }
        let ids = Array((exact.map(\.keyword.id) + kinds).prefix(6))
        return Keyword(label: titleCased(best.keyword.name), ids: ids)
    }

    /// "ice hockey" → "Ice Hockey", "1800s" stays, "nyc" → "NYC". TMDB keywords are all
    /// lowercase, so acronyms have to be known.
    static func titleCased(_ text: String) -> String {
        text.split(separator: " ").map { word in
            if acronyms.contains(String(word)) { return word.uppercased() }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static let acronyms: Set<String> = [
        "ai", "bbc", "cia", "cgi", "dc", "fbi", "kgb", "la", "lgbt", "lgbtq", "mlb", "nba", "nfl",
        "nhl", "nyc", "nypd", "tv", "uk", "ufo", "us", "usa", "wwi", "wwii",
    ]

    /// `items.map(transform)` with every transform running at once, results in order.
    private static func concurrentMap<T: Sendable, R: Sendable>(
        _ items: [T], _ transform: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await transform(item)) }
            }
            var results: [(Int, R)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Parsing

    struct Parse {
        var interpretation = Interpretation()
        /// Consecutive words nothing else claimed, split at stopwords and recognized facets.
        var subjectRuns: [[String]] = []
        /// For each subject run, the genre words right after it, if any — "true" before "crime".
        var genreAfterRun: [String?] = []
    }

    private enum Facet {
        case media(MediaType)
        case genres([Genre])
        case provider(Provider)
        case years(ClosedRange<Int>, label: String, isVague: Bool)
    }

    static func parse(
        _ query: String, regionProviders: [TMDBWatchProviderInfo], selectedProviderIDs: Set<Int>
    ) -> Parse {
        let words = SearchRanking.normalized(
            query.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        ).split(separator: " ").map(String.init)
        let providers = providerLookup(regionProviders, selectedIDs: selectedProviderIDs)

        var parse = Parse()
        var run: [String] = []
        func flushRun(beforeGenre genre: String? = nil) {
            if !run.isEmpty {
                parse.subjectRuns.append(run)
                parse.genreAfterRun.append(genre)
            }
            run = []
        }

        var index = 0
        while index < words.count {
            if let (length, facet) = longestFacet(in: words, at: index, providers: providers) {
                if case .genres = facet {
                    flushRun(beforeGenre: words[index..<index + length].joined(separator: " "))
                } else {
                    flushRun()
                }
                apply(facet, to: &parse.interpretation)
                index += length
                continue
            }
            if stopwords.contains(words[index]) {
                flushRun()
            } else {
                run.append(words[index])
            }
            index += 1
        }
        flushRun()
        return parse
    }

    private static func longestFacet(
        in words: [String], at start: Int, providers: [String: Provider]
    ) -> (Int, Facet)? {
        for length in stride(from: min(3, words.count - start), through: 1, by: -1) {
            let phrase = words[start..<start + length].joined(separator: " ")
            for form in singularForms(phrase) {
                if let type = mediaWords[form] { return (length, .media(type)) }
                if let genres = genreWords[form] { return (length, .genres(genres)) }
                if let provider = providers[form] { return (length, .provider(provider)) }
            }
            if length == 1, let years = yearRange(phrase) {
                return (1, .years(years.range, label: years.label, isVague: years.isVague))
            }
        }
        return nil
    }

    private static func apply(_ facet: Facet, to interpretation: inout Interpretation) {
        switch facet {
        case .media(let type):
            interpretation.mediaType = type
        case .genres(let genres):
            for genre in genres where !interpretation.genres.contains(where: { $0.label == genre.label }) {
                interpretation.genres.append(genre)
            }
        case .provider(let provider):
            if !interpretation.providers.contains(where: { $0.id == provider.id }) {
                interpretation.providers.append(provider)
            }
        case .years(let range, let label, let isVague):
            interpretation.years = range
            interpretation.yearsLabel = label
            interpretation.yearsAreVague = isVague
        }
    }

    /// Every plausible singular of the phrase's last word, most likely first: "movies" → "movie",
    /// "comedies" → "comedy", "witches" → "witch". Plain English rules can't tell "movies" from
    /// "comedies", so callers try each; the phrase itself comes last.
    static func singularForms(_ phrase: String) -> [String] {
        var words = phrase.split(separator: " ").map(String.init)
        guard let last = words.last, last.count > 3, last.hasSuffix("s"), !last.hasSuffix("ss") else { return [phrase] }
        var stems = [String(last.dropLast())]
        if last.hasSuffix("ies") { stems.append(String(last.dropLast(3)) + "y") }
        if last.hasSuffix("es") { stems.append(String(last.dropLast(2))) }
        let forms = stems.map { stem in
            words[words.count - 1] = stem
            return words.joined(separator: " ")
        }
        return (forms + [phrase]).uniqued()
    }

    /// "2019", "1990s", "90s", "nineties", and the vague "new", "classic".
    static func yearRange(_ word: String, now: Date = .now) -> (range: ClosedRange<Int>, label: String, isVague: Bool)? {
        let currentYear = Calendar.current.component(.year, from: now)
        if word.count == 4, let year = Int(word), (1900...currentYear + 2).contains(year) {
            return (year...year, word, false)
        }
        if word.hasSuffix("s"), let number = Int(word.dropLast()), number % 10 == 0 {
            let decade: Int? = switch word.count {
            case 5 where (1900...2090).contains(number): number
            case 3: number <= 20 ? 2000 + number : 1900 + number
            default: nil
            }
            if let decade { return (decade...decade + 9, "\(decade)s", false) }
        }
        if let decade = decadeWords[word] { return (decade...decade + 9, "\(decade)s", false) }
        if ["new", "newer", "recent", "latest"].contains(word) { return (currentYear - 2...currentYear, "Recent", true) }
        if ["old", "older", "classic", "classics"].contains(word) { return (1900...1989, "Classic", true) }
        return nil
    }

    private static let decadeWords = [
        "fifties": 1950, "sixties": 1960, "seventies": 1970, "eighties": 1980, "nineties": 1990,
    ]

    private static let mediaWords: [String: MediaType] = [
        "movie": .movie, "film": .movie, "flick": .movie,
        "show": .tvShow, "tv": .tvShow, "tv show": .tvShow, "series": .tvShow, "tv series": .tvShow,
        "miniseries": .tvShow, "mini series": .tvShow, "limited series": .tvShow,
    ]

    private static let action = Genre(label: "Action", tvID: 10759, movieID: 28, keywordTerm: "action")
    private static let adventure = Genre(label: "Adventure", tvID: 10759, movieID: 12, keywordTerm: "adventure")
    private static let animation = Genre(label: "Animation", tvID: 16, movieID: 16, keywordTerm: "animation")
    private static let comedy = Genre(label: "Comedy", tvID: 35, movieID: 35, keywordTerm: "comedy")
    private static let crime = Genre(label: "Crime", tvID: 80, movieID: 80, keywordTerm: "crime")
    private static let documentary = Genre(label: "Documentary", tvID: 99, movieID: 99, keywordTerm: "documentary")
    private static let drama = Genre(label: "Drama", tvID: 18, movieID: 18, keywordTerm: "drama")
    private static let family = Genre(label: "Family", tvID: 10751, movieID: 10751, keywordTerm: "family")
    private static let kids = Genre(label: "Kids", tvID: 10762, movieID: 10751, keywordTerm: "children")
    private static let fantasy = Genre(label: "Fantasy", tvID: 10765, movieID: 14, keywordTerm: "fantasy")
    private static let sciFi = Genre(label: "Sci-Fi", tvID: 10765, movieID: 878, keywordTerm: "science fiction")
    private static let history = Genre(label: "History", tvID: nil, movieID: 36, keywordTerm: "history")
    private static let horror = Genre(label: "Horror", tvID: nil, movieID: 27, keywordTerm: "horror")
    private static let music = Genre(label: "Musical", tvID: nil, movieID: 10402, keywordTerm: "musical")
    private static let mystery = Genre(label: "Mystery", tvID: 9648, movieID: 9648, keywordTerm: "mystery")
    private static let romance = Genre(label: "Romance", tvID: nil, movieID: 10749, keywordTerm: "romance")
    private static let thriller = Genre(label: "Thriller", tvID: nil, movieID: 53, keywordTerm: "thriller")
    private static let war = Genre(label: "War", tvID: 10768, movieID: 10752, keywordTerm: "war")
    private static let western = Genre(label: "Western", tvID: 37, movieID: 37, keywordTerm: "western")
    private static let reality = Genre(label: "Reality", tvID: 10764, movieID: nil, keywordTerm: "reality tv")

    private static let genreWords: [String: [Genre]] = [
        "action": [action], "adventure": [adventure],
        "animation": [animation], "animated": [animation], "cartoon": [animation],
        "comedy": [comedy], "funny": [comedy], "sitcom": [comedy],
        "crime": [crime],
        "documentary": [documentary], "doc": [documentary], "docuseries": [documentary],
        "drama": [drama], "family": [family],
        "kid": [kids], "kids": [kids], "children": [kids], "childrens": [kids],
        "fantasy": [fantasy],
        "sci fi": [sciFi], "scifi": [sciFi], "science fiction": [sciFi],
        "history": [history], "historical": [history],
        "horror": [horror], "scary": [horror],
        "music": [music], "musical": [music],
        "mystery": [mystery],
        "romance": [romance], "romantic": [romance],
        "rom com": [romance, comedy], "romcom": [romance, comedy], "romantic comedy": [romance, comedy],
        "thriller": [thriller], "suspense": [thriller],
        "war": [war], "western": [western], "reality": [reality],
    ]

    /// The services a query can name: the majors, by the short names people say, plus the user's
    /// own services by their full names. Not the region's whole list — it's ~300 services, many
    /// named like ordinary words ("True Story", "ARROW", "Runtime", "Chilling").
    private static let providerNicknames: [String: Int] = [
        "netflix": 8, "hulu": 15, "peacock": 386,
        "prime": 9, "prime video": 9, "amazon": 9, "amazon prime": 9, "amazon prime video": 9,
        "disney": 337, "disney plus": 337,
        "hbo": 1899, "max": 1899, "hbo max": 1899,
        "apple": 350, "apple tv": 350, "apple tv plus": 350, "appletv": 350,
        "paramount": 531, "paramount plus": 531,
    ]

    private static let commonWordNicknames: Set<String> = ["max", "apple", "prime", "amazon", "paramount"]

    private static let providerFallbackNames = [
        8: "Netflix", 15: "Hulu", 386: "Peacock", 9: "Prime Video", 337: "Disney+",
        1899: "HBO Max", 350: "Apple TV", 531: "Paramount+",
    ]

    private static func providerLookup(
        _ regionProviders: [TMDBWatchProviderInfo], selectedIDs: Set<Int>
    ) -> [String: Provider] {
        let namesByID = Dictionary(regionProviders.map { ($0.providerId, $0.providerName) }) { first, _ in first }
        var lookup: [String: Provider] = [:]
        for provider in regionProviders where selectedIDs.contains(provider.providerId) {
            let key = SearchRanking.normalized(provider.providerName)
            guard !key.isEmpty, !stopwords.contains(key) else { continue }
            lookup[key] = Provider(id: provider.providerId, name: provider.providerName)
        }
        for (nickname, id) in providerNicknames {
            guard let name = namesByID[id] ?? providerFallbackNames[id] else { continue }
            lookup[nickname] = Provider(id: id, name: name, isNamedByCommonWord: commonWordNicknames.contains(nickname))
        }
        return lookup
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "on", "in", "at", "to", "for", "from", "with", "about",
        "by", "set", "where", "that", "who", "which", "is", "are", "was", "it", "its", "i", "me", "my",
        "some", "any", "something", "anything", "good", "best", "great", "top", "really", "very",
        "one", "ones", "thing", "things", "kind", "type", "watch", "streaming", "stream", "available",
        "like", "plus", "only", "just", "free",
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
