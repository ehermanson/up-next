import Foundation

/// One search, start to finish — what Discover, the add sheet and `check_search.sh` all run, so
/// the order of operations lives in one place:
///
/// 1. `/search/tv` and `/search/movie` run concurrently, with the on-device model reading the
///    query alongside (`SearchModel.read`). The title rows are handed to `titlesLanded` as soon
///    as they arrive — unless the query reads as a description to the rules
///    (`DescriptiveSearch.looksDescriptive`), whose section would lead and push them down a
///    moment later. Those are held: released when the model says it's a name after all and the
///    title search matched it, else published together with the section. Rows land once.
/// 2. `DescriptiveSearch.run` interprets the query as a description, using how well the best
///    title hit matched (`SearchRanking.bestTitleMatch`) and the model's reading.
/// 3. When the whole query matched no title, `remainderTitleSearch` tries its name part ("the
///    bear hulu" → "the bear"); those rows replace the title rows. A name found that way also
///    retires a section made only of the name's own words ("Studio · On Apple TV").
///
/// Nil when the task was cancelled — a superseded keystroke must not overwrite the current one.
enum SearchSession {
    /// The title search, both types. A failed type carries its message; callers keep that
    /// type's previous rows rather than blanking them.
    struct Titles {
        var tvShows: [TMDBTVShowSearchResult] = []
        var movies: [TMDBMovieSearchResult] = []
        var tvError: String?
        var movieError: String?
    }

    struct Outcome {
        /// The title rows were on screen before the section arrived.
        var titlesShownEarly = false
        /// Whether a section the model read as a description may lead the rows
        /// (`DescriptiveSearch.layout`'s `descriptionFirst`): yes when the rows were held for it;
        /// yes under an exact title ("zombies" — *Zombies* stays first and the section lands
        /// right under it, nudging only what's below); no when a name prefix's rows were already
        /// on screen — nothing moves down to make room above them.
        var sectionMayLead = true
        var described: DescriptiveSearch.Results?
        /// Rows for the name part of the query, replacing the whole query's.
        var remainder: (query: String, tvShows: [TMDBTVShowSearchResult], movies: [TMDBMovieSearchResult])?
        var reading: SearchModel.Reading?
        var titleMatch: SearchRanking.TitleMatch = .none
    }

    /// `mediaType` scopes the described section to one type (an add sheet opened for TV or movies).
    static func run(
        query: String, mediaType: MediaType? = nil, service: TMDBService = .shared, titlesLanded: (Titles) -> Void
    ) async -> Outcome? {
        async let tvFetch = fetch { try await service.searchTVShows(query: query) }
        async let movieFetch = fetch { try await service.searchMovies(query: query) }
        async let modelReading = SearchModel.read(query)
        let (tv, movies) = await (tvFetch, movieFetch)
        guard !Task.isCancelled else { return nil }
        let titles = Titles(tvShows: tv.results, movies: movies.results, tvError: tv.error, movieError: movies.error)
        var titlesPublished = false
        func publishTitles() {
            guard !titlesPublished else { return }
            titlesPublished = true
            titlesLanded(titles)
        }
        if !DescriptiveSearch.looksDescriptive(query) { publishTitles() }

        let best = SearchRanking.bestTitleMatch(
            tvShow: tv.results.first.map { ($0.name, $0.voteCount, $0.firstAirDate, $0.popularity) },
            movie: movies.results.first.map { ($0.title, $0.voteCount, $0.releaseDate, $0.popularity) }, query: query
        )
        let reading = await modelReading
        guard !Task.isCancelled else { return nil }
        // "modern family": the rules saw a genre word, the model saw a name, and the title search
        // found it — no reason to keep the rows waiting on a section that won't lead.
        if reading?.isTitleName == true, best.match != .none { publishTitles() }
        var outcome = Outcome(
            titlesShownEarly: titlesPublished, sectionMayLead: !titlesPublished || best.match == .exact,
            reading: reading, titleMatch: best.match
        )
        outcome.described = await DescriptiveSearch.run(
            query: query, titleMatch: best.match, titleVotes: best.votes, mediaType: mediaType, reading: reading,
            service: service
        )
        guard !Task.isCancelled else { return nil }
        defer { publishTitles() }
        if best.match == .none, let found = await DescriptiveSearch.remainderTitleSearch(
            query: query, besideSection: !(outcome.described?.isEmpty ?? true), reading: reading, service: service
        ) {
            guard !Task.isCancelled else { return nil }
            outcome.remainder = (found.remainder, found.tvShows, found.movies)
            // "the studio apple tv": the section's subjects were the name's own words. A type word
            // ("christmas movies on disney plus") or a genre says the person described something.
            if let interpretation = outcome.described?.interpretation, interpretation.mediaType == nil,
               interpretation.genres.isEmpty, interpretation.person == nil, interpretation.reference == nil,
               interpretation.origin == nil {
                outcome.described = nil
            }
        }
        return outcome
    }

    private struct Fetched<Element> {
        var results: [Element] = []
        var error: String?
    }

    private static func fetch<Element>(_ request: () async throws -> [Element]) async -> Fetched<Element> {
        do {
            return Fetched(results: try await request())
        } catch {
            return Fetched(error: errorText(error))
        }
    }

    /// A message for the error banner; nil for a cancellation, which isn't news.
    static func errorText(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        return error.localizedDescription
    }
}
