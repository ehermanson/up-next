import Foundation

/// The names `CreateListView` suggests for a new collection, each with the TMDB `/discover`
/// queries that stand in for recommendation seeds until the collection has titles of its own.
/// Without them an empty collection's only starting pool is a title search for its name — which
/// for "Date Night" finds films called *Date Night* and for "Comfort Rewatches" finds nothing.
///
/// Matching is by name (case-insensitive), so a user who types "Halloween" by hand gets the same
/// pool. Keyword ids are TMDB's: 3335 = halloween, 207317 = christmas.
nonisolated struct CollectionIdea: Sendable {
    let name: String
    /// `/discover/movie` parameters; nil means the idea suggests no movies while empty.
    let movieQuery: [String: String]?
    /// `/discover/tv` parameters; nil means the idea suggests no shows while empty.
    let tvQuery: [String: String]?

    static func named(_ name: String) -> CollectionIdea? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// What the New Collection sheet offers: a holiday leads in the months before it and is left
    /// out the rest of the year (still matchable via `named` if typed).
    static func suggestions(on date: Date = .now) -> [CollectionIdea] {
        let seasonal: [String] = switch Calendar.current.component(.month, from: date) {
        case 8, 9: [halloween.name]
        case 10: [halloween.name, holiday.name]
        case 11, 12: [holiday.name]
        default: []
        }
        return seasonal.compactMap(named) + evergreen
    }

    private static let halloween = CollectionIdea(
        name: "Halloween",
        movieQuery: ["with_keywords": "3335", "vote_count.gte": "300", "sort_by": "popularity.desc"],
        tvQuery: nil
    )

    private static let holiday = CollectionIdea(
        name: "Holiday Movies",
        // Christmas-keyworded slashers (Terrifier) and thrillers aren't what anyone means.
        movieQuery: ["with_keywords": "207317", "without_genres": "27,53", "vote_count.gte": "300", "sort_by": "popularity.desc"],
        tvQuery: nil
    )

    private static let evergreen: [CollectionIdea] = [
        CollectionIdea(
            name: "Date Night",
            movieQuery: ["with_genres": "10749,35", "vote_count.gte": "1000", "vote_average.gte": "6.5", "sort_by": "popularity.desc"],
            tvQuery: nil
        ),
        CollectionIdea(
            name: "Family Movie Night",
            movieQuery: ["with_genres": "10751", "vote_count.gte": "2000", "vote_average.gte": "6.8", "sort_by": "popularity.desc"],
            tvQuery: nil
        ),
        CollectionIdea(
            name: "Comfort Rewatches",
            movieQuery: ["with_genres": "35", "without_genres": "80,18,53,27", "vote_count.gte": "4000", "vote_average.gte": "6.8", "sort_by": "vote_count.desc"],
            tvQuery: ["with_genres": "35", "without_genres": "16", "vote_count.gte": "1000", "vote_average.gte": "7.5", "sort_by": "vote_count.desc"]
        ),
        // TMDB has no awards data; "acclaimed drama" is the honest approximation.
        CollectionIdea(
            name: "Award Winners",
            movieQuery: ["with_genres": "18", "vote_count.gte": "5000", "vote_average.gte": "7.8", "sort_by": "vote_average.desc"],
            tvQuery: nil
        ),
        CollectionIdea(
            name: "Watch Together",
            movieQuery: ["vote_count.gte": "5000", "vote_average.gte": "7", "sort_by": "popularity.desc"],
            tvQuery: nil
        ),
        CollectionIdea(
            name: "Classics",
            movieQuery: ["primary_release_date.lte": "1979-12-31", "vote_count.gte": "1500", "sort_by": "vote_average.desc"],
            tvQuery: nil
        ),
        CollectionIdea(
            name: "Documentaries",
            movieQuery: ["with_genres": "99", "vote_count.gte": "300", "vote_average.gte": "7", "sort_by": "vote_count.desc"],
            tvQuery: ["with_genres": "99", "vote_count.gte": "100", "vote_average.gte": "7.5", "sort_by": "vote_count.desc"]
        ),
        CollectionIdea(
            name: "Guilty Pleasures",
            movieQuery: ["with_genres": "35|10749|28", "vote_count.gte": "2000", "vote_average.lte": "6.3", "sort_by": "popularity.desc"],
            tvQuery: ["with_genres": "10764", "vote_count.gte": "100", "sort_by": "vote_count.desc"]
        ),
    ]

    private static let all: [CollectionIdea] = [halloween, holiday] + evergreen
}
