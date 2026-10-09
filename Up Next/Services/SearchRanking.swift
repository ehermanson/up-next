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
        // Popularity is capped below the exact-match tier (4.0) so a single viral title can never
        // outrank a cold exact match by volume alone: 0.6·log1p(400) ≈ 3.6. Vote count is a
        // slower-moving "people have actually seen this" signal.
        let popularity = 0.6 * log1p(min(signals.popularity ?? 0, 400))
        let votes = 0.2 * log1p(Double(signals.voteCount ?? 0))
        return titleMatch + popularity + votes
    }

    /// How surely the user typed a name: `.exact` when the title is the query, `.strong` when it
    /// starts with the query or the query starts with a title of two or more words plus extra
    /// words ("the office us"). One-word titles don't count that way — "zombie movies" isn't a
    /// name just because a film is called *Zombie*.
    ///
    /// A title hardly anyone has rated counts only as an exact match, and only if it's unreleased
    /// or just out (`isNewOrUpcoming`) *and* people are looking at it (popularity ≥ 10):
    /// "avengers doomsday" (out in December, 0 votes, popularity 94) is a name, while TMDB's
    /// 0-vote 2017 *Time Travel* — or a fresh 0-vote upload called *Haunted House* — doesn't make
    /// the phrase one. TMDB has an obscure title for nearly every phrase.
    nonisolated enum TitleMatch: Comparable, Sendable {
        case none, strong, exact
    }

    static let knownTitleVoteCount = 20

    /// An exact title this well known is what the user meant even when the on-device model reads
    /// the query as a description: *You* (4,100 votes), *Scandal* (625), *Industry* (283) — but
    /// not the 44-vote *Zombies*.
    static let wellKnownTitleVoteCount = 200

    static func titleMatch(
        _ title: String, query: String, voteCount: Int?, releaseDate: String? = nil, popularity: Double? = nil
    ) -> TitleMatch {
        let title = normalized(title), query = normalized(query)
        let score = matchScore(title: title, query: query)
        if (voteCount ?? 0) < knownTitleVoteCount {
            return score >= 4 && isNewOrUpcoming(releaseDate) && (popularity ?? 0) >= 10 ? .exact : .none
        }
        if score >= 4 { return .exact }
        if score >= 2.5 || (title.contains(" ") && query.hasPrefix(title + " ")) { return .strong }
        return .none
    }

    /// Released in the last four months or not yet — too new to have votes. TMDB dates are
    /// `yyyy-MM-dd`.
    static func isNewOrUpcoming(_ date: String?, now: Date = .now) -> Bool {
        guard let date, date.count >= 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let released = formatter.date(from: String(date.prefix(10))) else { return false }
        return released > now.addingTimeInterval(-120 * 24 * 60 * 60)
    }

    /// The better of the two types' top title hits, with that title's vote count.
    static func bestTitleMatch(
        tvShow: (name: String, votes: Int?, date: String?, popularity: Double?)?,
        movie: (name: String, votes: Int?, date: String?, popularity: Double?)?,
        query: String
    ) -> (match: TitleMatch, votes: Int?) {
        let candidates = [tvShow, movie].compactMap { $0 }.map {
            (match: titleMatch($0.name, query: query, voteCount: $0.votes, releaseDate: $0.date, popularity: $0.popularity),
             votes: $0.votes)
        }
        return candidates.max { ($0.match, $0.votes ?? 0) < ($1.match, $1.votes ?? 0) } ?? (.none, nil)
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

    /// Case- and diacritic-folded, apostrophes dropped ("Schitt's" → "schitts", one word as TMDB
    /// searches it), other punctuation collapsed to single spaces ("The Walk-In" → "the walk in").
    /// The one normalizer: titles, queries and the model's readings all go through it, so they
    /// compare equal.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
