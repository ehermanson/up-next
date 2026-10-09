import Foundation

/// Search by description — "hulu hockey comedy", "slasher movies", "90s heist films" — for when
/// someone remembers what a title is about but not what it's called.
///
/// `/search` only matches names, so the query is interpreted into `/discover` filters instead:
/// streaming services, genres, "movie"/"show", years, origin, a person, "like X", and TMDB
/// keywords for whatever subject matter is left ("ice hockey", "slasher", "time travel").
///
/// The on-device model reads the query (`SearchModel.read`) and `ground` checks each thing it
/// read against what TMDB can filter on — a facet it can't name is dropped, never guessed at.
/// Where the model isn't available, `parse` does the reading with rules instead: words matched,
/// longest phrase first, against the same lexicons, and "like X" as the words after the cue. New
/// query shapes belong in the model's prompt, not in `parse`. The title search still runs alongside;
/// this adds a second section, never replaces it.
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

    /// "korean", "british": the original language or country of origin.
    struct Origin: Equatable {
        let label: String
        var language: String?
        var country: String?
    }

    /// Someone the query names ("tom hanks movies", "christopher nolan").
    nonisolated struct Person: Sendable, Equatable {
        let id: Int
        let name: String
    }

    /// The title in "shows like Ted Lasso".
    struct Reference: Equatable {
        let title: String
        let id: Int
        let mediaType: MediaType
        var genreIDs: [Int] = []
        /// TMDB's synopsis — what the model is told X is about when ranking candidates.
        var overview: String?
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
        var origin: Origin?
        var person: Person?
        var reference: Reference?

        /// Genres, services, years, origins, people and "like X" — facets that only a description
        /// has. Keywords don't count (most words in a name are some TMDB keyword: "the office us"
        /// → Office, US), nor do a vague year or a service named by a common word ("Mad Max",
        /// "Apple Cider Vinegar").
        var descriptiveFacetCount: Int {
            genres.count + providers.filter { !$0.isNamedByCommonWord }.count
                + (years != nil && !yearsAreVague ? 1 : 0)
                + [origin != nil, person != nil, reference != nil].filter { $0 }.count
        }

        /// Facets that narrow the results, not counting the media type.
        var filterCount: Int {
            providers.count + genres.count + keywords.count + (years == nil ? 0 : 1)
                + [origin != nil, person != nil, reference != nil].filter { $0 }.count
        }

        /// The section heading: "Comedy · Hockey · On Hulu". `matchedAny` is set when the subjects
        /// had to be loosened from all to any, so the heading says "Hockey or Christmas".
        func summary(for mediaType: MediaType, matchedAny: Bool = false) -> String {
            let subjects = genres.filter { $0.id(for: mediaType) == nil }.map(\.label) + keywords.map(\.label)
            var parts = [reference.map { "Like \($0.title)" }, person?.name, origin?.label].compactMap { $0 }
            parts += genres.filter { $0.id(for: mediaType) != nil }.map(\.label)
            parts += matchedAny ? [subjects.joined(separator: " or ")] : subjects
            if let yearsLabel { parts.append(yearsLabel) }
            if !providers.isEmpty {
                parts.append("On " + providers.map(\.name).joined(separator: " or "))
            }
            // Only the model's guesses, nothing the rules could name.
            return parts.isEmpty ? "Suggested Titles" : parts.joined(separator: " · ")
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
        /// The on-device model read the query as a description, not a name — so this section
        /// leads even over a title that matches it exactly ("zombies" over *Zombies*).
        fileprivate(set) var readsAsDescription = false
        /// The model's verified guesses lead the rows.
        fileprivate(set) var suggestionsLead = false

        var isEmpty: Bool { tvShows.isEmpty && movies.isEmpty }

        /// When the model's guesses lead and the rules found nothing to name the rows by.
        func summary(for mediaType: MediaType) -> String {
            if suggestionsLead, interpretation.descriptiveFacetCount == 0, interpretation.keywords.isEmpty {
                return "Suggested Titles"
            }
            return interpretation.summary(for: mediaType, matchedAny: mediaType == .tvShow ? tvMatchedAny : moviesMatchedAny)
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
    /// shows the movie *Kids* first and the Kids genre after it. For the rules a keyword-only
    /// query that hits a title ("zombies") isn't interpreted — "zombie movies" is; the model's
    /// "description" lifts that for an exact, less-known title (the section goes under it), never
    /// for a name being typed (`.strong`).
    ///
    /// `mediaType` limits the fetch to one type (an add sheet scoped to TV or movies).
    ///
    /// `reading` is the on-device model's take (`SearchModel`), nil where it's unavailable — then
    /// the rules parse the query instead. Its name-or-description call overrides `titleMatch`
    /// when it says description (an exact title people know still wins — `wellKnownTitleVoteCount`;
    /// a less-known one leads the list with the section under it), and its title guesses that
    /// check out (`verifiedTitles`) lead the section — unless the query carries filters a guess
    /// might not meet: a service, a year, an origin, a person or "like X".
    static func run(
        query: String, titleMatch: SearchRanking.TitleMatch, titleVotes: Int? = nil, mediaType: MediaType? = nil,
        reading: SearchModel.Reading? = nil, service: TMDBService = .shared
    ) async -> Results? {
        let providers = await providerLookup(service: service)
        let parsed = reading.map { ground($0, query: query, providers: providers) } ?? parse(query, providers: providers)
        let words = parsed.interpretation
        let hasReference = parsed.referenceQuery != nil
        // The model misreads a plain name now and then ("you", "industry", "scandal"), so its
        // "description" never overrides an exact title people know — nor one with "like" in it
        // ("something like summer" isn't "like Summer").
        // …and a multi-word exact title ("apple cider vinegar", 3 words, few votes) is a name even
        // when the model says otherwise, unless the rules found a real facet in it; the override
        // is for the one-word case ("zombies", "kids"), where TMDB has a title for every noun.
        let modelSaysDescription = reading?.isTitleName == false
            && !(titleMatch == .exact && (titleVotes ?? 0) >= SearchRanking.wellKnownTitleVoteCount)
            && !(titleMatch == .exact && hasReference)
            && !(titleMatch == .exact && query.split(separator: " ").count > 1 && words.descriptiveFacetCount == 0)
        // "the bear hulu", "the office sitcom": a name with a service, type or genre word beside it
        // is the title search's job (`remainderTitleSearch`), not a section of the service's or
        // genre's whole catalogue under a heading that claims to have understood.
        if parsed.title != nil, parsed.subjectRuns.isEmpty, parsed.personName == nil, !hasReference { return nil }
        // "like X" is answered by `similarPool`; a person's titles by their credits.
        let guessesApply = modelSaysDescription && !hasHardFacets(words) && !hasReference && parsed.personName == nil
        async let ruled = interpret(
            parsed, query: query, titleMatch: modelSaysDescription ? .none : titleMatch, mediaType: mediaType, service: service
        )
        async let verified = verifiedTitles(guessesApply ? reading?.titles ?? [] : [], service: service)
        let (rules, guesses) = await (ruled, verified)
        guard !Task.isCancelled else { return nil }

        // A name being typed ("the walking", "squid"): the model reads a prefix as a description
        // and guesses nothing, and its one leftover word is some TMDB keyword — that section
        // must not jump above the title it's a prefix of. (An exact, less-known title still gets
        // the section under it: "zombies".)
        if modelSaysDescription, titleMatch == .strong, guesses.tvShows.isEmpty, guesses.movies.isEmpty,
           (rules?.interpretation.descriptiveFacetCount ?? 0) == 0 {
            return nil
        }
        var results = rules
        results?.readsAsDescription = modelSaysDescription
        if let interpretation = rules?.interpretation, hasHardFacets(interpretation) { return results }
        guard guessesApply else { return results }

        let type = mediaType ?? words.mediaType
        let tvGuesses = type == .movie
            ? [] : narrowed(guesses.tvShows, words, .tvShow, genreIDs: \.genreIds, date: \.firstAirDate)
        let movieGuesses = type == .tvShow
            ? [] : narrowed(guesses.movies, words, .movie, genreIDs: \.genreIds, date: \.releaseDate)
        guard !tvGuesses.isEmpty || !movieGuesses.isEmpty else { return results }

        let tvIDs = Set(tvGuesses.map(\.id)), movieIDs = Set(movieGuesses.map(\.id))
        var merged = Results(
            query: query, interpretation: rules?.interpretation ?? words,
            tvShows: tvGuesses + (rules?.tvShows ?? []).filter { !tvIDs.contains($0.id) },
            movies: movieGuesses + (rules?.movies ?? []).filter { !movieIDs.contains($0.id) }
        )
        merged.tvMatchedAny = rules?.tvMatchedAny ?? false
        merged.moviesMatchedAny = rules?.moviesMatchedAny ?? false
        merged.readsAsDescription = modelSaysDescription
        merged.suggestionsLead = true
        return merged
    }

    /// Filters a model guess isn't checked against: a service, a real year, an origin, a person
    /// or "like X".
    private static func hasHardFacets(_ interpretation: Interpretation) -> Bool {
        !interpretation.providers.isEmpty || (interpretation.years != nil && !interpretation.yearsAreVague)
            || interpretation.origin != nil || interpretation.person != nil || interpretation.reference != nil
    }

    // MARK: - Grounding

    /// The model's reading as a `Parse`. The model is trusted on the query's *shape* — which
    /// words are a title, a person, a "like X" title — and each of those is kept only when it
    /// appears in the query (`evidenced`; the model paraphrases and, now and then, invents) and,
    /// later, when TMDB knows it (`interpret`). Everything else is read off the remaining words
    /// by the same lexicon scan the rules use: genres, services, years, origins and type are
    /// closed vocabularies, and asking a small model for them only adds invented filters.
    ///
    /// Subjects stay the leftover words (phrases like "haunted house" resolve as TMDB keywords)
    /// except for a sentence, where word-by-word keywords are junk ("Guy · Relive · Day") and the
    /// model's subjects stand in ("Time Loop").
    static func ground(_ reading: SearchModel.Reading, query: String, providers: [String: Provider]) -> Parse {
        var remaining = " " + normalizedWords(query).joined(separator: " ") + " "
        /// `value` normalized when the query contains it as whole words — cut out of `remaining`.
        func evidenced(_ value: String?) -> String? {
            guard let value = value.map(SearchRanking.normalized), !value.isEmpty,
                  let range = remaining.range(of: " " + value + " ") else { return nil }
            remaining.replaceSubrange(range, with: " ")
            return value
        }
        /// Nothing but facets and stopwords ("true crime", "scary movie"): a genre, not a name.
        func namesSomething(_ text: String) -> Bool {
            var scanned = Parse()
            scan(text.split(separator: " ").map(String.init), into: &scanned, providers: providers)
            return !scanned.subjectRuns.isEmpty
        }
        var parse = Parse()
        if reading.isTitleName, let title = reading.title.map(SearchRanking.normalized), namesSomething(title) {
            parse.title = evidenced(title)
        }
        parse.personName = evidenced(reading.person)
        // "like X" needs a cue in the query ("the bear comedy" isn't "like The Bear"). The model
        // echoes the query's own framing into X ("like=shows like ted lasso", "like=heist
        // movies"), so leading cue, type and placeholder words are shed and then leading words
        // dropped until what's left — two words at least — is in the query, isn't all of it, and
        // names something a genre word doesn't.
        if let similarTo = reading.similarTo.map(SearchRanking.normalized), !similarTo.isEmpty,
           remaining.split(separator: " ").contains(where: { referenceCues.contains(String($0)) }) {
            var candidate = similarTo.split(separator: " ").map(String.init)
            let whole = remaining.trimmingCharacters(in: .whitespaces)
            while !candidate.isEmpty {
                while let first = candidate.first, isReferenceFraming(first) { candidate.removeFirst() }
                guard candidate.count >= 2 || candidate.count == similarTo.split(separator: " ").count,
                      !candidate.isEmpty else { break }
                let text = candidate.joined(separator: " ")
                if text != whole, namesSomething(text), let found = evidenced(text) {
                    parse.referenceQuery = found
                    break
                }
                candidate.removeFirst()
            }
        }
        // The model read no reference but the query asks for one: the words after the cue.
        if parse.referenceQuery == nil { parse.referenceQuery = referenceAfterCue(in: &remaining, providers: providers) }
        scan(remaining.split(separator: " ").map(String.init), into: &parse, providers: providers)

        if parse.referenceQuery != nil {
            // With a reference the words around it ("in the vein of", "same vibe as") would only
            // become keywords in the heading — `similarPool` doesn't use them.
            parse.subjectRuns = []
            parse.genreAfterRun = []
        } else if parse.subjectRuns.reduce(0, { $0 + $1.count }) > 3, !reading.subjects.isEmpty {
            // A sentence — more than a phrase's worth of words left over, usually split into
            // short runs by its stopwords ("guy" / "inherits" / "minor league hockey team").
            parse.subjectRuns = []
            parse.genreAfterRun = []
            for subject in reading.subjects.prefix(2) {
                // "comedy", "90s" filed as subjects: the facet they are.
                if let facet = facet(naming: subject, providers: providers) {
                    apply(facet, to: &parse.interpretation)
                } else {
                    addSubject(subject, to: &parse)
                }
            }
        }
        return parse
    }

    /// "shows like ted lasso on netflix" without the model: everything after the last "like" /
    /// "similar to", minus leading placeholders and trailing stopwords, services and years ("on
    /// netflix" stays in `remaining` to be scanned), when it names something. Cut out of
    /// `remaining`. The plainest reading, no grammar — "i like comedies" leaves a genre, which
    /// isn't a title, and "severance that are funny" stays whole (the model reads that one).
    private static func referenceAfterCue(in remaining: inout String, providers: [String: Provider]) -> String? {
        let words = remaining.split(separator: " ").map(String.init)
        // The last cue: "i would like something like ted lasso".
        guard let cue = words.lastIndex(where: { $0 == "like" || $0 == "similar" }) else { return nil }
        var title = Array(words[(cue + 1)...])
        while let first = title.first, isReferenceFraming(first) { title.removeFirst() }
        while !title.isEmpty {
            let facet = tailFacetLength(title, providers: providers)
            if facet > 0 { title.removeLast(facet) } else if stopwords.contains(title[title.count - 1]) { title.removeLast() } else { break }
        }
        guard !title.isEmpty else { return nil }
        var scanned = Parse()
        scan(title, into: &scanned, providers: providers)
        guard !scanned.subjectRuns.isEmpty else { return nil }
        let text = title.joined(separator: " ")
        guard let range = remaining.range(of: " " + text + " ") else { return nil }
        remaining.replaceSubrange(range, with: " ")
        return text
    }

    /// How many of `words`' last words name a service or a year ("…ted lasso netflix" → 1,
    /// "…inception 2010" → 1); 0 when none do. Only those: titles end in genre and type words
    /// all the time ("modern family", "the morning show"), never in "netflix" or "2010".
    private static func tailFacetLength(_ words: [String], providers: [String: Provider]) -> Int {
        for length in stride(from: min(3, words.count), through: 1, by: -1) {
            if let (found, facet) = longestFacet(in: Array(words.suffix(length)), at: 0, providers: providers), found == length {
                switch facet {
                case .provider, .years: return length
                default: return 0
                }
            }
        }
        return 0
    }

    /// A word the model copies into "like X" from around the title, not from it: "shows like
    /// ted lasso" → "ted lasso".
    private static func isReferenceFraming(_ word: String) -> Bool {
        referenceCues.contains(word) || word == "to" || referencePlaceholders.contains(word)
            || singularForms(word).contains { mediaWords[$0] != nil }
    }

    /// Words that ask for something like a title — how people say it.
    private static let referenceCues: Set<String> = [
        "like", "similar", "vein", "vibe", "vibes", "style", "reminiscent", "akin", "comparable", "reminds",
    ]

    /// The one facet `text` names in full, if any ("sci fi", "disney plus", "1990s").
    private static func facet(naming text: String, providers: [String: Provider]) -> Facet? {
        let words = SearchRanking.normalized(text).split(separator: " ").map(String.init)
        guard !words.isEmpty, let (length, facet) = longestFacet(in: words, at: 0, providers: providers),
              length == words.count else { return nil }
        return facet
    }

    private static func addSubject(_ text: String, to parse: inout Parse) {
        var words = SearchRanking.normalized(text).split(separator: " ").map(String.init)
            .filter { !stopwords.contains($0) || runJoiners.contains($0) }
        while let last = words.last, runJoiners.contains(last) { words.removeLast() }
        while let first = words.first, runJoiners.contains(first) { words.removeFirst() }
        guard !words.isEmpty, !parse.subjectRuns.contains(words) else { return }
        parse.subjectRuns.append(words)
        parse.genreAfterRun.append(nil)
    }

    // MARK: - Layout

    /// How the title matches and the described section share one list: titles, the section,
    /// then any titles it pushed down. Each title appears once, in the first block that has it.
    struct Layout<Item> {
        var leadingTitles: [Item] = []
        var described: [Item] = []
        var trailingTitles: [Item] = []
    }

    /// - No confident title match: the section leads.
    /// - The query starts a title's name ("the office us"): the titles lead — unless the model
    ///   read a description, then the section does.
    /// - A title is exactly the query: the titles lead — unless `descriptionFirst` (the model read
    ///   a description, as for "zombies", or the titles came from `remainderTitleSearch`), then
    ///   only the best exact title leads, the section follows, and the rest of the title matches
    ///   come after it. *Zombies* stays first; zombie titles are right below.
    ///
    /// `query` is what the titles were searched with.
    static func layout<Item>(
        titles: [Item], described: [Item], query: String, descriptionFirst: Bool,
        id: (Item) -> Int, name: (Item) -> String, votes: (Item) -> Int?, date: (Item) -> String?,
        popularity: (Item) -> Double?
    ) -> Layout<Item> {
        func match(_ item: Item) -> SearchRanking.TitleMatch {
            SearchRanking.titleMatch(name(item), query: query, voteCount: votes(item), releaseDate: date(item),
                                     popularity: popularity(item))
        }
        func removing(_ items: [Item], from list: [Item]) -> [Item] {
            let ids = Set(items.map(id))
            return list.filter { !ids.contains(id($0)) }
        }
        guard !described.isEmpty else { return Layout(leadingTitles: titles) }
        switch (titles.first.map(match) ?? .none, descriptionFirst) {
        case (.none, _), (.strong, true):
            return Layout(described: described, trailingTitles: removing(described, from: titles))
        case (.exact, true):
            // One title: TMDB has five films called *Zombies* and several called *High School*.
            let exact = titles.first { match($0) == .exact }.map { [$0] } ?? []
            let section = removing(exact, from: described)
            return Layout(leadingTitles: exact, described: section,
                          trailingTitles: removing(exact + section, from: titles))
        case (.strong, false), (.exact, false):
            return Layout(leadingTitles: titles, described: removing(titles, from: described))
        }
    }

    /// The model's guesses that a title search finds by exactly that name among titles people
    /// know (`SearchRanking.knownTitleVoteCount`) — it invents some ("Minor League", "Hockey").
    private static func verifiedTitles(
        _ guesses: [String], service: TMDBService
    ) async -> (tvShows: [TMDBTVShowSearchResult], movies: [TMDBMovieSearchResult]) {
        guard !guesses.isEmpty, !Task.isCancelled else { return ([], []) }
        let found = await concurrentMap(Array(guesses.prefix(5))) { guess -> (TMDBTVShowSearchResult?, TMDBMovieSearchResult?) in
            async let tv = try? service.searchTVShows(query: guess)
            async let movies = try? service.searchMovies(query: guess)
            let (shows, films) = await (tv ?? [], movies ?? [])
            return (
                shows.first { SearchRanking.titleMatch($0.name, query: guess, voteCount: $0.voteCount) == .exact },
                films.first { SearchRanking.titleMatch($0.title, query: guess, voteCount: $0.voteCount) == .exact }
            )
        }
        // One guess is one title. When both types have it, the type most of the other guesses
        // resolved to decides — "find me a thriller" guesses films, so not the namesake shows;
        // "sports dramedy" guesses shows, so *Friday Night Lights* the series, not the film.
        let showsOnly = found.filter { $0.0 != nil && $0.1 == nil }.count
        let filmsOnly = found.filter { $0.0 == nil && $0.1 != nil }.count
        let decided = found.map { show, film -> (TMDBTVShowSearchResult?, TMDBMovieSearchResult?) in
            guard show != nil, film != nil, showsOnly != filmsOnly else { return (show, film) }
            return showsOnly > filmsOnly ? (show, nil) : (nil, film)
        }
        var tvSeen = Set<Int>(), movieSeen = Set<Int>()
        return (
            decided.compactMap(\.0).filter { tvSeen.insert($0.id).inserted },
            decided.compactMap(\.1).filter { movieSeen.insert($0.id).inserted }
        )
    }

    /// Resolves what the reading left to TMDB — keywords, the person, the "like X" title — and
    /// fetches the section.
    private static func interpret(
        _ parsed: Parse, query: String, titleMatch: SearchRanking.TitleMatch, mediaType: MediaType?, service: TMDBService
    ) async -> Results? {
        var interpretation = parsed.interpretation
        let hasReference = parsed.referenceQuery != nil
        guard interpretation.filterCount > 0 || !parsed.subjectRuns.isEmpty || hasReference || parsed.personName != nil
        else { return nil }
        let descriptive = interpretation.descriptiveFacetCount > 0 || hasReference || parsed.personName != nil
        switch titleMatch {
        // "something like summer" is a title, not "like Summer".
        case .exact: guard interpretation.descriptiveFacetCount > 0, parsed.subjectRuns.isEmpty, !hasReference else { return nil }
        case .strong: guard descriptive || parsed.subjectRuns.contains(where: { $0.count <= 3 }) else { return nil }
        case .none: break
        }
        // A name prefix with nothing descriptive yet can still name a person ("christopher nolan"
        // over the documentaries about him) — but its words aren't worth keyword lookups.
        let peopleOnly = titleMatch == .strong && !descriptive

        let fallbackIndices = interpretation.genres.indices.filter {
            interpretation.genres[$0].tvID == nil || interpretation.genres[$0].movieID == nil
        }
        let fallbackTerms = fallbackIndices.map { interpretation.genres[$0].keywordTerm }
        async let subjects = resolveSubjects(
            in: parsed.subjectRuns, genresAfter: parsed.genreAfterRun, peopleOnly: peopleOnly, service: service
        )
        async let fallbacks = concurrentMap(fallbackTerms) {
            await resolveKeyword($0, service: service)
        }
        let preferredType = mediaType ?? interpretation.mediaType
        async let reference = resolveReference(parsed.referenceQuery, preferring: preferredType, service: service)
        // The model's named person — kept only if TMDB knows them, never retried as keywords.
        async let named: Person? = {
            guard let name = parsed.personName else { return nil }
            return await resolvePerson(name.split(separator: " ").map(String.init), service: service)
        }()
        let (resolved, genreKeywords, referenced, explicitPerson) = await (subjects, fallbacks, reference, named)
        guard !Task.isCancelled else { return nil }
        interpretation.keywords = resolved.keywords
        interpretation.person = explicitPerson ?? resolved.person
        interpretation.reference = referenced
        for (index, keyword) in zip(fallbackIndices, genreKeywords) {
            interpretation.genres[index].keyword = keyword
        }

        if hasReference, referenced == nil { return nil }
        if titleMatch == .strong, interpretation.descriptiveFacetCount == 0 { return nil }
        // "hulu shoresy": the subject was the point, and without it the section would just be
        // Hulu's whole catalogue under a heading that claims to have understood. A named person
        // TMDB doesn't know counts the same.
        let unresolved = resolved.unresolvedWords + (parsed.personName != nil && interpretation.person == nil ? 1 : 0)
        if unresolved > 0, interpretation.genres.isEmpty, interpretation.keywords.isEmpty,
           interpretation.person == nil, interpretation.origin == nil, interpretation.reference == nil {
            return nil
        }

        // "like X" with no type asked for means X's type.
        let type = mediaType ?? interpretation.mediaType ?? interpretation.reference?.mediaType
        let region = service.currentRegion
        let resolvedInterpretation = interpretation
        async let tv = type != .movie
            ? fetchTVShows(resolvedInterpretation, region: region, service: service) : (results: [], matchedAny: false)
        async let movies = type != .tvShow
            ? fetchMovies(resolvedInterpretation, region: region, service: service) : (results: [], matchedAny: false)
        let (tvFetch, movieFetch) = await (tv, movies)
        guard !Task.isCancelled else { return nil }
        var results = Results(query: query, interpretation: interpretation,
                              tvShows: tvFetch.results, movies: movieFetch.results)
        results.tvMatchedAny = tvFetch.matchedAny
        results.moviesMatchedAny = movieFetch.matchedAny
        return results
    }

    /// "hulu shoresy", "the bear hulu": a name with a service or type word attached. The title
    /// search was given the whole string; the name alone finds it. Nil unless the rest of the
    /// query leaves a name that matches confidently. Callers try it whenever the whole query
    /// matched no title, even beside a described section — "the bear" is also a keyword, and the
    /// section alone would bury the show (`layout` puts an exact name first).
    ///
    /// The name is the model's (`reading.title`) when it read one; otherwise the words no facet
    /// claimed (majors only — no provider list fetch). For the rules, `besideSection` — a
    /// described section is showing — means only a service word makes it a name: "heist movies",
    /// "road trip movies", "the heist movies" are descriptions though films carry those names,
    /// and promoting one would bury the section.
    static func remainderTitleSearch(
        query: String, besideSection: Bool, reading: SearchModel.Reading? = nil, service: TMDBService = .shared
    ) async -> (remainder: String, tvShows: [TMDBTVShowSearchResult], movies: [TMDBMovieSearchResult])? {
        let remainder: String
        if let reading, reading.isTitleName, let title = reading.title.map(SearchRanking.normalized), !title.isEmpty,
           case let whole = SearchRanking.normalized(query), (" " + whole + " ").contains(" " + title + " ") {
            guard title != whole else { return nil }
            remainder = title
        } else {
            let parsed = parse(query, providers: providerLookup([], selectedIDs: []))
            let interpretation = parsed.interpretation
            guard interpretation.filterCount > 0 || interpretation.mediaType != nil, !parsed.subjectRuns.isEmpty,
                  parsed.referenceQuery == nil else { return nil }
            if besideSection, interpretation.providers.isEmpty { return nil }
            remainder = parsed.nameWords.joined(separator: " ")
        }
        guard !Task.isCancelled else { return nil }
        async let tv = try? service.searchTVShows(query: remainder)
        async let movies = try? service.searchMovies(query: remainder)
        let (shows, films) = await (tv ?? [], movies ?? [])
        let match = max(
            shows.first.map {
                SearchRanking.titleMatch($0.name, query: remainder, voteCount: $0.voteCount, releaseDate: $0.firstAirDate,
                                         popularity: $0.popularity)
            } ?? .none,
            films.first.map {
                SearchRanking.titleMatch($0.title, query: remainder, voteCount: $0.voteCount, releaseDate: $0.releaseDate,
                                         popularity: $0.popularity)
            } ?? .none
        )
        guard match != .none, !Task.isCancelled else { return nil }
        return (remainder, shows, films)
    }

    /// Shows for the interpretation: the reference's recommendations, the person's shows, or
    /// `/discover/tv`.
    private static func fetchTVShows(
        _ interpretation: Interpretation, region: String, service: TMDBService
    ) async -> (results: [TMDBTVShowSearchResult], matchedAny: Bool) {
        if let reference = interpretation.reference {
            let pool = await similarPool(
                to: reference, wantsTVShows: true, interpretation: interpretation, region: region, service: service,
                recommendations: { reference.mediaType == .tvShow ? try await service.fetchTVRecommendations(id: reference.id) : [] },
                discover: { try await service.discoverTVShows(filters: $0) },
                search: { try await service.searchTVShows(query: $0) },
                id: \.id, name: \.name, genreIDs: \.genreIds, votes: \.voteCount
            )
            let fitting = narrowed(pool, interpretation, .tvShow, genreIDs: \.genreIds, date: \.firstAirDate)
            let ranked = await judged(fitting, like: reference, wantsTVShows: true, interpretation: interpretation, id: \.id) {
                candidateLine($0.name, date: $0.firstAirDate, overview: $0.overview)
            }
            return (Array(ranked.prefix(20)), false)
        }
        if let person = interpretation.person {
            // Credits can't be checked against a service without a request per show.
            guard interpretation.providers.isEmpty,
                  let credits = try? await service.personTVCredits(id: person.id) else { return ([], false) }
            return (personShows(credits, interpretation), false)
        }
        return await fetch(filters(for: .tvShow, interpretation, region: region)) {
            try await service.discoverTVShows(filters: $0)
        }
    }

    /// Movies for the interpretation: the reference's recommendations, or `/discover/movie`
    /// (which takes the person as `with_people`).
    private static func fetchMovies(
        _ interpretation: Interpretation, region: String, service: TMDBService
    ) async -> (results: [TMDBMovieSearchResult], matchedAny: Bool) {
        if let reference = interpretation.reference {
            let pool = await similarPool(
                to: reference, wantsTVShows: false, interpretation: interpretation, region: region, service: service,
                recommendations: { reference.mediaType == .movie ? try await service.fetchMovieRecommendations(id: reference.id) : [] },
                discover: { try await service.discoverMovies(filters: $0) },
                search: { try await service.searchMovies(query: $0) },
                id: \.id, name: \.title, genreIDs: \.genreIds, votes: \.voteCount
            )
            let fitting = narrowed(pool, interpretation, .movie, genreIDs: \.genreIds, date: \.releaseDate)
            let ranked = await judged(fitting, like: reference, wantsTVShows: false, interpretation: interpretation, id: \.id) {
                candidateLine($0.title, date: $0.releaseDate, overview: $0.overview)
            }
            return (Array(ranked.prefix(20)), false)
        }
        return await fetch(filters(for: .movie, interpretation, region: region)) {
            try await service.discoverMovies(filters: $0)
        }
    }

    /// The pool's top two dozen, re-ordered with the on-device model's sense of tone
    /// (`SearchModel.rank`): the fused rank and the model's pick rank are blended by reciprocal
    /// rank, so a pick rises by how sure the model was but no single source promotes a weak
    /// candidate on its own — the judge once put *Shameless* and *The Chi* first for The Bear on
    /// shared setting alone. The fusion finds candidates; this is what tells *Abbott Elementary*
    /// from *Ballers* for Ted Lasso. Without the model the fused order stands.
    private static func judged<T>(
        _ pool: [T], like reference: Reference, wantsTVShows: Bool, interpretation: Interpretation,
        id: (T) -> Int, line: (T) -> String
    ) async -> [T] {
        let candidates = Array(pool.prefix(24))
        guard candidates.count >= 4, !Task.isCancelled,
              let picks = await SearchModel.rank(
                candidates: candidates.map(line), like: reference.title, overview: reference.overview,
                referenceIsTVShow: reference.mediaType == .tvShow, wantsTVShows: wantsTVShows,
                qualities: interpretation.genres.map { $0.label.lowercased() }
              ), !picks.isEmpty
        else { return pool }
        // Reciprocal rank fusion: 1/(k + rank) per source. The judge leads — its first pick
        // outscores anything unpicked — while the pool's own first few stay near the top rather
        // than dropping behind every pick.
        let k = 3.0
        var score = pool.indices.map { 1 / (k + Double($0)) }
        for (rank, index) in picks.enumerated() { score[index] += 3 / (k + Double(rank)) }
        return pool.indices.sorted { score[$0] > score[$1] }.map { pool[$0] }
    }

    /// "Ted Lasso (2020) — An American football coach…", the overview cut to a line.
    private static func candidateLine(_ name: String, date: String?, overview: String?) -> String {
        var line = name
        if let year = date?.prefix(4), year.count == 4 { line += " (\(year))" }
        if let overview = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
            let cut = overview.count > 160 ? String(overview.prefix(157)).trimmingCharacters(in: .whitespaces) + "…" : overview
            line += " — \(cut)"
        }
        return line
    }

    /// "Like X" from three sources, fused by rank so a title more than one of them names rises:
    ///
    /// - the on-device model's titles like X in tone (`SearchModel.similarTitles`), kept when a
    ///   title search finds them exactly — the only source that gets Ted Lasso → *Abbott
    ///   Elementary*, *Schitt's Creek* rather than more soccer;
    /// - TMDB's recommendations, re-ranked toward titles people have seen;
    /// - titles sharing X's keywords — one popularity-sorted discover per keyword, X's genres
    ///   counting more — strong for plot-led titles (Breaking Bad → *Better Call Saul*, *Narcos*),
    ///   blind to tone.
    ///
    /// Vote count breaks near-ties: someone asking for "like X" wants titles people have seen.
    ///
    /// The other type ("movies like the office") has no TMDB recommendations — the model and the
    /// keywords carry it. A service ("…on netflix") can only be checked by `/discover`, so then
    /// it's keywords alone, filtered to the service, and one shared keyword is enough.
    private static func similarPool<T: Sendable>(
        to reference: Reference, wantsTVShows: Bool, interpretation: Interpretation, region: String,
        service: TMDBService,
        recommendations: @escaping @Sendable () async throws -> [T],
        discover: @escaping @Sendable ([String: String]) async throws -> [T],
        search: @escaping @Sendable (String) async throws -> [T],
        id: (T) -> Int, name: (T) -> String, genreIDs: (T) -> [Int]?, votes: (T) -> Int?
    ) async -> [T] {
        let restriction: [String: String] = interpretation.providers.isEmpty ? [:] : [
            "with_watch_providers": interpretation.providers.map { String($0.id) }.joined(separator: "|"),
            "watch_region": region,
            "with_watch_monetization_types": "flatrate|free|ads",
        ]
        let restricted = !restriction.isEmpty
        let referenceIsTVShow = reference.mediaType == .tvShow
        // "severance that are funny": the model's picks should be funny too.
        let qualities = interpretation.genres.map { $0.label.lowercased() }
        async let recommended = restricted ? [] : (try? recommendations()) ?? []
        async let neighbours = keywordNeighbours(of: reference, restriction: restriction, service: service, discover: discover)
        async let picks: [(guess: String, results: [T])] = {
            guard !restricted, let titles = await SearchModel.similarTitles(
                to: reference.title, referenceIsTVShow: referenceIsTVShow, wantsTVShows: wantsTVShows, qualities: qualities
            ) else { return [] }
            return await concurrentMap(Array(titles.prefix(5))) { ($0, (try? await search($0)) ?? []) }
        }()
        let (recs, lists, searched) = await (recommended, neighbours, picks)
        guard !Task.isCancelled else { return [] }

        var score: [Int: Double] = [:]
        var byID: [Int: T] = [:]
        func add(_ item: T, _ points: Double) {
            guard id(item) != reference.id else { return }
            score[id(item), default: 0] += points
            byID[id(item)] = byID[id(item)] ?? item
        }
        // Each pick is the search result named exactly that, among known titles (see `verifiedTitles`).
        for (rank, (guess, results)) in searched.enumerated() {
            if let match = results.first(where: {
                SearchRanking.titleMatch(name($0), query: guess, voteCount: votes($0)) == .exact
            }) {
                add(match, 3 * (1 - Double(rank) / 10))
            }
        }
        // TMDB's own order buries the obvious (Inception → *The Matrix* 11th, *Interstellar* 16th,
        // behind *Paycheck*); vote count leads, with a tenth of a log-vote per place of TMDB's order.
        let recognized = recs.enumerated()
            .map { (item: $0.element, score: log1p(Double(votes($0.element) ?? 0)) - Double($0.offset) / 10) }
            .sorted { $0.score > $1.score }
            .map(\.item)
        for (rank, item) in recognized.prefix(20).enumerated() {
            add(item, 1.5 * (1 - Double(rank) / 25))
        }
        // A title sharing a single keyword with X is mostly a popular title with a generic one
        // (Severance → *Grey's Anatomy*); it takes two to count.
        var overlap: [Int: Double] = [:]
        var hits: [Int: Int] = [:]
        let referenceGenres = Set(reference.genreIDs)
        for list in lists {
            for (rank, item) in list.prefix(20).enumerated() where id(item) != reference.id {
                let sharesGenre = !referenceGenres.isDisjoint(with: genreIDs(item) ?? [])
                overlap[id(item), default: 0] += (sharesGenre ? 1 : 0.4) * (1 - Double(rank) / 40)
                hits[id(item), default: 0] += 1
                byID[id(item)] = byID[id(item)] ?? item
            }
        }
        // Filtered to a service or across types (shows rarely carry two of a film's keywords),
        // one shared keyword has to do.
        let crossType = referenceIsTVShow != wantsTVShows
        overlap = overlap.filter { hits[$0.key, default: 0] >= (restricted || crossType ? 1 : 2) }
        let topOverlap = max(overlap.values.max() ?? 0, 1)
        for (key, value) in overlap { score[key, default: 0] += 1.5 * value / topOverlap }
        for key in score.keys { score[key, default: 0] += 0.1 * log1p(Double(byID[key].flatMap(votes) ?? 0)) }
        // Unbounded: callers narrow by the query's genres and years before taking the top.
        return score.sorted { $0.value > $1.value }.compactMap { byID[$0.key] }
    }

    /// For each of X's first dozen keywords, the most popular known titles carrying it (of
    /// whatever type `discover` asks for), within `restriction`.
    private static func keywordNeighbours<T: Sendable>(
        of reference: Reference, restriction: [String: String], service: TMDBService,
        discover: @escaping @Sendable ([String: String]) async throws -> [T]
    ) async -> [[T]] {
        guard !Task.isCancelled,
              let keywords = try? await service.titleKeywords(id: reference.id, isTVShow: reference.mediaType == .tvShow)
        else { return [] }
        return await concurrentMap(Array(keywords.prefix(12))) { keyword in
            let filters = ["with_keywords": String(keyword.id), "sort_by": "popularity.desc", "vote_count.gte": "50"]
            return (try? await discover(filters.merging(restriction) { _, new in new })) ?? []
        }
    }

    /// Recommendations and credits can't be filtered server-side, so genres and years are
    /// applied here (a fallback genre's keyword can't be — those genres are skipped).
    private static func narrowed<T>(
        _ items: [T], _ interpretation: Interpretation, _ mediaType: MediaType,
        genreIDs: (T) -> [Int]?, date: (T) -> String?
    ) -> [T] {
        let wanted = interpretation.genres.compactMap { $0.id(for: mediaType) }
        return items.filter { item in
            let ids = Set(genreIDs(item) ?? [])
            guard wanted.allSatisfy(ids.contains) else { return false }
            guard let years = interpretation.years else { return true }
            guard let year = date(item).flatMap({ Int($0.prefix(4)) }) else { return false }
            return years.contains(year)
        }
    }

    /// A person's shows: roles across two or more episodes, or ones they created, wrote or
    /// directed — not guest spots, talk-show appearances ("Self") or news/reality/talk shows.
    /// Best known first.
    private static func personShows(
        _ credits: TMDBPersonTVCredits, _ interpretation: Interpretation
    ) -> [TMDBTVShowSearchResult] {
        let roles = credits.cast.filter { credit in
            let character = (credit.character ?? "").lowercased()
            return (credit.episodeCount ?? 0) >= 2 && !character.hasPrefix("self")
                && !character.contains("himself") && !character.contains("herself")
        }
        let work = credits.crew.filter { ["Creator", "Director", "Writer", "Screenplay"].contains($0.job ?? "") }
        let nonFiction: Set<Int> = [10763, 10764, 10767]
        var seen = Set<Int>()
        let shows = (roles + work).map(\.show).filter { show in
            seen.insert(show.id).inserted && nonFiction.isDisjoint(with: show.genreIds ?? [])
        }
        return narrowed(shows, interpretation, .tvShow, genreIDs: \.genreIds, date: \.firstAirDate)
            .sorted { ($0.voteCount ?? 0) > ($1.voteCount ?? 0) }
    }

    /// The reference as TMDB knows it, if it does.
    private static func resolveReference(
        _ title: String?, preferring mediaType: MediaType?, service: TMDBService
    ) async -> Reference? {
        guard let title else { return nil }
        return await bestReference(for: title, preferring: mediaType, service: service)?.0
    }

    /// The title in "shows like ted lasso": the closest confident title match, then the better
    /// known, and only then the asked-for type — "movies like friends" means the show, not
    /// *Friends with Benefits*; `similarPool` finds movies for it.
    private static func bestReference(
        for query: String, preferring mediaType: MediaType?, service: TMDBService
    ) async -> (Reference, SearchRanking.TitleMatch)? {
        guard !Task.isCancelled else { return nil }
        async let tv = try? service.searchTVShows(query: query)
        async let movies = try? service.searchMovies(query: query)
        let (shows, films) = await (tv ?? [], movies ?? [])
        var candidates: [(reference: Reference, match: SearchRanking.TitleMatch, votes: Int)] = []
        if let show = shows.first {
            candidates.append((Reference(title: show.name, id: show.id, mediaType: .tvShow, genreIDs: show.genreIds ?? [],
                                         overview: show.overview),
                               SearchRanking.titleMatch(show.name, query: query, voteCount: show.voteCount, releaseDate: show.firstAirDate,
                                                        popularity: show.popularity),
                               show.voteCount ?? 0))
        }
        if let film = films.first {
            candidates.append((Reference(title: film.title, id: film.id, mediaType: .movie, genreIDs: film.genreIds ?? [],
                                         overview: film.overview),
                               SearchRanking.titleMatch(film.title, query: query, voteCount: film.voteCount, releaseDate: film.releaseDate,
                                                        popularity: film.popularity),
                               film.voteCount ?? 0))
        }
        return candidates.filter { $0.match != .none }.max { lhs, rhs in
            (lhs.match, lhs.votes, lhs.reference.mediaType == mediaType ? 1 : 0)
                < (rhs.match, rhs.votes, rhs.reference.mediaType == mediaType ? 1 : 0)
        }.map { ($0.reference, $0.match) }
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
                || interpretation.years != nil || interpretation.origin != nil
                || interpretation.person != nil else { return nil }

        // Most-voted first: a description wants the titles that define it — "slasher movies" →
        // *Psycho*, *Scream*; "coming of age movies" → *Dead Poets Society* — where popularity put
        // whatever's trending (*Moana 2*). Discover's carousels cover what's new.
        var filters = ["sort_by": "vote_count.desc", "vote_count.gte": "50"]
        if !genreIDs.isEmpty {
            filters["with_genres"] = Set(genreIDs).sorted().map(String.init).joined(separator: ",")
        }
        if !interpretation.providers.isEmpty {
            filters["with_watch_providers"] = interpretation.providers.map { String($0.id) }.joined(separator: "|")
            filters["watch_region"] = region
            filters["with_watch_monetization_types"] = "flatrate|free|ads"
        }
        if let origin = interpretation.origin {
            if let language = origin.language { filters["with_original_language"] = language }
            if let country = origin.country { filters["with_origin_country"] = country }
        }
        // Movies only — `/discover/tv` ignores it (see `fetchTVShows`).
        if let person = interpretation.person { filters["with_people"] = String(person.id) }
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

    /// Each run is looked up as a person ("tom hanks", "zendaya") and as keywords at once; a
    /// person wins. For keywords, a run of two or three words is tried as one keyword first ("time
    /// travel", "high school"), then word by word. Failing that, a run right before a genre word
    /// tries its last word with the genre ("true crime", "dark comedy") — otherwise "true" becomes
    /// a keyword of its own that nothing carries alongside the genre. The genre stays either way.
    /// `peopleOnly` skips the keywords. Runs resolve concurrently.
    private static func resolveSubjects(
        in runs: [[String]], genresAfter: [String?], peopleOnly: Bool, service: TMDBService
    ) async -> (keywords: [Keyword], unresolvedWords: Int, person: Person?) {
        let perRun = await concurrentMap(Array(zip(runs, genresAfter))) { run, genre -> ([Keyword?], Person?) in
            async let person = resolvePerson(run, service: service)
            // "tom hanks christmas": a name, then a subject.
            async let leadingPerson = run.count >= 3 ? resolvePerson(Array(run.prefix(2)), service: service) : nil
            async let keywords = peopleOnly ? [] : resolveKeywords(in: run, genreAfter: genre, service: service)
            let (named, leading, found) = await (person, leadingPerson, keywords)
            if let named { return ([], named) }
            if let leading {
                let rest = peopleOnly ? [] : await resolveKeywords(in: Array(run.dropFirst(2)), genreAfter: genre, service: service)
                return (rest, leading)
            }
            return (peopleOnly ? run.map { _ in nil } : found, nil)
        }
        var seen = Set<[Int]>()
        let keywords = perRun.flatMap(\.0).compactMap { $0 }.filter { seen.insert($0.ids).inserted }
        return (keywords, perRun.flatMap(\.0).filter { $0 == nil }.count, perRun.lazy.compactMap(\.1).first)
    }

    private static func resolveKeywords(in run: [String], genreAfter genre: String?, service: TMDBService) async -> [Keyword?] {
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
        let words = await concurrentMap(run.filter { !stopwords.contains($0) }) { await resolveKeyword($0, service: service) }
        return compound.map { words + [$0] } ?? words
    }

    /// The TMDB person named exactly the run, if they're well known. A one-word name needs more
    /// popularity — TMDB has a "Dog" and a "Drake" (1.6); Zendaya is ~17, Tom Hanks ~13.
    private static func resolvePerson(_ run: [String], service: TMDBService) async -> Person? {
        guard (1...3).contains(run.count), !Task.isCancelled else { return nil }
        let name = run.joined(separator: " ")
        guard let people = try? await service.searchPeople(query: name),
              let match = people.first(where: { SearchRanking.normalized($0.name) == name }),
              (match.popularity ?? 0) >= (run.count == 1 ? 5 : 1) else { return nil }
        return Person(id: match.id, name: match.name)
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

    /// "ice hockey" → "Ice Hockey", "coming of age" → "Coming of Age", "1800s" stays, "nyc" →
    /// "NYC". TMDB keywords are all lowercase, so acronyms have to be known.
    static func titleCased(_ text: String) -> String {
        text.split(separator: " ").enumerated().map { index, word in
            if acronyms.contains(String(word)) { return word.uppercased() }
            if index > 0, minorWords.contains(String(word)) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static let minorWords: Set<String> = ["of", "the", "and", "in", "on", "a", "an", "to", "for", "at", "by"]

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
        /// The title in "shows like ted lasso" — the model's, present in the query (`ground`).
        var referenceQuery: String?
        /// The words no facet claimed, stopwords included — the name in "the studio apple tv".
        var nameWords: [String] = []
        /// The model's, each present in the query: the title a name query names, and a person.
        var title: String?
        var personName: String?
    }

    private enum Facet {
        case media(MediaType)
        case genres([Genre])
        case provider(Provider)
        case years(ClosedRange<Int>, label: String, isVague: Bool)
        case origin(Origin, genres: [Genre])
    }

    /// The rules' reading of `query` — the fallback where the on-device model isn't available:
    /// facets, subjects, and the plainest "like X" (`referenceAfterCue`).
    static func parse(_ query: String, providers: [String: Provider]) -> Parse {
        var parse = Parse()
        var remaining = " " + normalizedWords(query).joined(separator: " ") + " "
        parse.referenceQuery = referenceAfterCue(in: &remaining, providers: providers)
        scan(remaining.split(separator: " ").map(String.init), into: &parse, providers: providers)
        return parse
    }

    private static func normalizedWords(_ query: String) -> [String] {
        SearchRanking.normalized(query).split(separator: " ").map(String.init)
    }

    /// Facets matched longest phrase first; the words nothing claims become subject runs, split
    /// at stopwords, and `nameWords`.
    private static func scan(_ words: [String], into parse: inout Parse, providers: [String: Provider]) {
        var run: [String] = []
        func flushRun(beforeGenre genre: String? = nil) {
            while let last = run.last, runJoiners.contains(last) { run.removeLast() }
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
            parse.nameWords.append(words[index])
            if runJoiners.contains(words[index]), !run.isEmpty {
                // "coming of age": kept so the phrase can be tried as one keyword.
                run.append(words[index])
            } else if stopwords.contains(words[index]) {
                flushRun()
            } else {
                run.append(words[index])
            }
            index += 1
        }
        flushRun()
    }

    /// Stopwords kept inside a subject run so a phrase holds together ("coming of age").
    private static let runJoiners: Set<String> = ["of", "and", "the"]

    /// "something like…", "anything like…": stand-ins for a title, not part of one.
    private static let referencePlaceholders: Set<String> = [
        "something", "anything", "stuff", "more", "titles", "things", "others", "ones",
    ]

    private static func longestFacet(
        in words: [String], at start: Int, providers: [String: Provider]
    ) -> (Int, Facet)? {
        for length in stride(from: min(3, words.count - start), through: 1, by: -1) {
            let phrase = words[start..<start + length].joined(separator: " ")
            for form in singularForms(phrase) {
                if let type = mediaWords[form] { return (length, .media(type)) }
                if let genres = genreWords[form] { return (length, .genres(genres)) }
                if let (origin, genres) = originWords[form] { return (length, .origin(origin, genres: genres)) }
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
        case .origin(let origin, let genres):
            interpretation.origin = origin
            apply(.genres(genres), to: &interpretation)
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

    private static let korean = Origin(label: "Korean", language: "ko")

    /// Language and country words. "kdrama" brings its genre along.
    private static let originWords: [String: (Origin, [Genre])] = [
        "korean": (korean, []), "kdrama": (korean, [drama]), "k drama": (korean, [drama]),
        "japanese": (Origin(label: "Japanese", language: "ja"), []),
        "chinese": (Origin(label: "Chinese", language: "zh"), []),
        "mandarin": (Origin(label: "Mandarin", language: "zh"), []),
        "cantonese": (Origin(label: "Cantonese", language: "cn"), []),
        "french": (Origin(label: "French", language: "fr"), []),
        "spanish": (Origin(label: "Spanish", language: "es"), []),
        "italian": (Origin(label: "Italian", language: "it"), []),
        "german": (Origin(label: "German", language: "de"), []),
        "danish": (Origin(label: "Danish", language: "da"), []),
        "swedish": (Origin(label: "Swedish", language: "sv"), []),
        "norwegian": (Origin(label: "Norwegian", language: "no"), []),
        "turkish": (Origin(label: "Turkish", language: "tr"), []),
        "thai": (Origin(label: "Thai", language: "th"), []),
        "hindi": (Origin(label: "Hindi", language: "hi"), []),
        "bollywood": (Origin(label: "Bollywood", language: "hi"), []),
        "british": (Origin(label: "British", country: "GB"), []),
        "australian": (Origin(label: "Australian", country: "AU"), []),
        "canadian": (Origin(label: "Canadian", country: "CA"), []),
        "irish": (Origin(label: "Irish", country: "IE"), []),
        "mexican": (Origin(label: "Mexican", country: "MX"), []),
        "indian": (Origin(label: "Indian", country: "IN"), []),
    ]

    private static let genreWords: [String: [Genre]] = [
        "true crime": [crime, documentary],
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

    /// Names for the user's own services; the majors have built-in names, so the region's list
    /// is fetched only when the user subscribes to something else.
    private static func providerLookup(service: TMDBService) async -> [String: Provider] {
        let selected = ProviderSettings.shared.selectedProviderIDs
        let regionProviders = selected.isSubset(of: providerFallbackNames.keys)
            ? [] : (try? await service.fetchWatchProviders()) ?? []
        return providerLookup(regionProviders, selectedIDs: selected)
    }

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
        // How people ask: "i would like…", "looking for…", "recommend me…"
        "would", "want", "wanna", "need", "looking", "find", "recommend", "recommendations", "suggest",
        "suggestions", "please", "give", "something",
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
