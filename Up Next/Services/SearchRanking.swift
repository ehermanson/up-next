import Foundation

/// Client-side re-ranking for TMDB `/search` results.
///
/// TMDB orders search hits by text relevance alone and ignores how well known a title is, so
/// "the walk" lists fourteen zero-vote shows ("Walk the Prank", "Walk the Line"…) above
/// The Walking Dead (popularity ~140, 18k votes), which lands 15th on page 1 with every spinoff
/// pushed to page 2. The score below keeps title match quality as the primary signal but lets
/// popularity and vote count break the near-ties that make up most of a result set.
enum SearchRanking {
    struct Signals {
        var title: String
        /// `original_name` / `original_title` — lets a query in the original language match.
        var alternateTitle: String?
        var popularity: Double?
        var voteCount: Int?
    }

    /// Stable: equal scores keep TMDB's order.
    static func ranked<T>(_ results: [T], query: String, signals: (T) -> Signals) -> [T] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return results }
        return results.enumerated()
            .map { (index: $0.offset, item: $0.element, score: score(signals($0.element), normalizedQuery: normalizedQuery)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    static func score(_ signals: Signals, normalizedQuery query: String) -> Double {
        let titleMatch = max(
            matchScore(title: normalized(signals.title), query: query),
            signals.alternateTitle.map { matchScore(title: normalized($0), query: query) } ?? 0
        )
        // Popularity is capped so a single viral title can't outrank an exact match by volume
        // alone; vote count is a slower-moving "people have actually seen this" signal.
        let popularity = 0.6 * log1p(min(signals.popularity ?? 0, 1000))
        let votes = 0.2 * log1p(Double(signals.voteCount ?? 0))
        return titleMatch + popularity + votes
    }

    /// Tiers, best first: exact title → title starts with the query → the query appears at a
    /// word boundary ("fear the walk…") → every query token prefixes some title token in any
    /// order ("walk the prank" for "the walk") → nothing.
    private static func matchScore(title: String, query: String) -> Double {
        if title == query { return 4.0 }
        if title.hasPrefix(query) { return 2.5 }
        if (" " + title).contains(" " + query) { return 1.5 }
        let titleTokens = title.split(separator: " ")
        let queryTokens = query.split(separator: " ")
        if queryTokens.allSatisfy({ token in titleTokens.contains { $0.hasPrefix(token) } }) {
            return 1.0
        }
        return 0
    }

    /// Case- and diacritic-folded, punctuation collapsed to single spaces ("The Walk-In" →
    /// "the walk in").
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
