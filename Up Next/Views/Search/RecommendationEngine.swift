import Foundation

protocol RecommendableResult: Sendable {
    var id: Int { get }
    var voteAverage: Double? { get }
    var displayTitle: String { get }
    var overview: String? { get }
}

extension TMDBTVShowSearchResult: RecommendableResult {
    var displayTitle: String { name }
}

extension TMDBMovieSearchResult: RecommendableResult {
    var displayTitle: String { title }
}

enum RecommendationEngine {

    // MARK: - Seed Selection

    static func selectSeeds(from items: [ListItem]) -> [Int] {
        // Priority 1: Thumbs-up rated items (strongest quality signal for "more like this")
        let thumbsUp = items
            .filter { $0.userRating == 1 }
            .sorted { $0.addedAt > $1.addedAt }

        // Priority 2: Recently added unwatched items (current-interest signal)
        let unwatched = items
            .filter { !$0.isWatched && $0.userRating != 1 }
            .sorted { $0.addedAt > $1.addedAt }

        // Priority 3: Recently watched items (fallback)
        let recentlyWatched = items
            .filter { $0.isWatched && $0.userRating != 1 }
            .sorted { ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast) }

        var seeds: [Int] = []
        var seenIDs = Set<String>()

        for item in thumbsUp + unwatched + recentlyWatched {
            guard seeds.count < 5 else { break }
            guard let id = item.media?.id, !seenIDs.contains(id), let intID = Int(id) else { continue }
            seenIDs.insert(id)
            seeds.append(intID)
        }

        return seeds
    }

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

    static func minimumFrequency(seedCount: Int, isListMode: Bool) -> Int {
        guard isListMode else { return 1 }
        return seedCount >= 2 ? 2 : 1
    }

    // MARK: - Fetching & Aggregation

    static func fetchRecommendations<T: RecommendableResult>(
        seeds: [Int],
        excluding existingIDs: Set<String>,
        minimumFrequency: Int,
        thematicKeywords: Set<String>,
        fetcher: @escaping @Sendable (Int) async throws -> [T]
    ) async -> [T] {
        var allResults: [T] = []

        await withTaskGroup(of: [T].self) { group in
            for seedID in seeds {
                group.addTask {
                    (try? await fetcher(seedID)) ?? []
                }
            }
            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        return aggregate(allResults, excluding: existingIDs, minimumFrequency: minimumFrequency, thematicKeywords: thematicKeywords)
    }

    static func aggregate<T: RecommendableResult>(
        _ results: [T],
        excluding existingIDs: Set<String>,
        minimumFrequency: Int,
        thematicKeywords: Set<String>
    ) -> [T] {
        var frequency: [Int: Int] = [:]
        var bestByID: [Int: T] = [:]
        var thematicScoreByID: [Int: Int] = [:]

        for result in results {
            guard !existingIDs.contains(String(result.id)) else { continue }
            guard (result.voteAverage ?? 0) >= 6.0 else { continue }
            frequency[result.id, default: 0] += 1
            if bestByID[result.id] == nil {
                bestByID[result.id] = result
            }
            let combinedText = "\(result.displayTitle) \(result.overview ?? "")"
            thematicScoreByID[result.id] = thematicScore(in: combinedText, keywords: thematicKeywords)
        }

        let strictSorted = bestByID.values
            .filter { (frequency[$0.id] ?? 0) >= minimumFrequency }
            .sorted { a, b in
                let freqA = frequency[a.id] ?? 0
                let freqB = frequency[b.id] ?? 0
                if freqA != freqB { return freqA > freqB }
                let thematicA = thematicScoreByID[a.id] ?? 0
                let thematicB = thematicScoreByID[b.id] ?? 0
                if thematicA != thematicB { return thematicA > thematicB }
                return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
            }

        let sorted: [T]
        if strictSorted.isEmpty && minimumFrequency > 1 {
            sorted = bestByID.values
                .filter { (frequency[$0.id] ?? 0) >= 1 }
                .sorted { a, b in
                    let freqA = frequency[a.id] ?? 0
                    let freqB = frequency[b.id] ?? 0
                    if freqA != freqB { return freqA > freqB }
                    let thematicA = thematicScoreByID[a.id] ?? 0
                    let thematicB = thematicScoreByID[b.id] ?? 0
                    if thematicA != thematicB { return thematicA > thematicB }
                    return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
                }
        } else {
            sorted = strictSorted
        }

        if !thematicKeywords.isEmpty {
            let themed = sorted.filter { (thematicScoreByID[$0.id] ?? 0) > 0 }
            if themed.count >= 3 {
                return themed.prefix(20).map { $0 }
            }
        }

        return sorted.prefix(20).map { $0 }
    }

    static func searchThematicResults<T: RecommendableResult>(
        query: String,
        excluding existingIDs: Set<String>,
        thematicKeywords: Set<String>,
        searcher: (String) async throws -> [T]
    ) async -> [T] {
        guard let results = try? await searcher(query) else { return [] }

        var scoreByID: [Int: Int] = [:]
        var bestByID: [Int: T] = [:]

        for result in results {
            guard !existingIDs.contains(String(result.id)) else { continue }
            let score = thematicScore(in: "\(result.displayTitle) \(result.overview ?? "")", keywords: thematicKeywords)
            guard score > 0 else { continue }
            if bestByID[result.id] == nil {
                bestByID[result.id] = result
                scoreByID[result.id] = score
            }
        }

        return bestByID.values
            .sorted { a, b in
                let scoreA = scoreByID[a.id] ?? 0
                let scoreB = scoreByID[b.id] ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
            }
            .prefix(20)
            .map { $0 }
    }

    // MARK: - Thematic Analysis

    static let themeExpansions: [String: Set<String>] = [
        "christmas": ["christmas", "xmas", "holiday", "santa", "reindeer", "snow", "grinch", "noel", "nutcracker"],
        "xmas": ["christmas", "xmas", "holiday", "santa", "reindeer", "snow", "grinch", "noel", "nutcracker"],
        "holiday": ["christmas", "xmas", "holiday", "santa", "thanksgiving", "halloween"],
        "halloween": ["halloween", "horror", "haunted", "ghost", "witch", "zombie", "vampire", "monster"],
        "horror": ["horror", "scary", "haunted", "ghost", "slasher", "zombie", "vampire", "demon"],
        "anime": ["anime", "manga", "japanese", "animation", "studio ghibli"],
        "sci fi": ["sci fi", "science fiction", "space", "alien", "robot", "future", "dystopia"],
        "romance": ["romance", "romantic", "love", "wedding", "valentine"],
        "war": ["war", "military", "soldier", "battle", "army", "combat"],
        "superhero": ["superhero", "marvel", "dc comics", "avengers", "batman", "spider man"],
    ]

    static let stopWords: Set<String> = ["list", "lists", "stuff", "things", "my", "the", "and", "for", "best", "top", "all", "time"]

    static func thematicKeywords(for listName: String?) -> Set<String> {
        guard let listName else { return [] }

        let words = normalizedWords(from: listName)
        let tokens = words.filter { $0.count >= 3 && !stopWords.contains($0) }

        var keywords = Set(tokens)
        let normalizedListText = normalizedText(from: listName)

        for (theme, expansion) in themeExpansions {
            let themeWords = theme.split(separator: " ").map(String.init)
            if themeWords.allSatisfy({ words.contains($0) }) || normalizedListText.contains(theme) {
                for item in expansion {
                    let normalized = normalizedText(from: item)
                    if !normalized.isEmpty {
                        keywords.insert(normalized)
                    }
                }
            }
        }

        return keywords
    }

    static func thematicScore(in text: String, keywords: Set<String>) -> Int {
        guard !keywords.isEmpty else { return 0 }
        let normalizedHaystack = normalizedText(from: text)
        let words = Set(normalizedWords(from: text))

        return keywords.reduce(into: 0) { score, keyword in
            let normalizedKeyword = normalizedText(from: keyword)
            guard !normalizedKeyword.isEmpty else { return }

            if normalizedKeyword.contains(" ") {
                let keywordWords = normalizedKeyword.split(separator: " ").map(String.init)
                if normalizedHaystack.contains(normalizedKeyword)
                    || keywordWords.allSatisfy({ words.contains($0) })
                {
                    score += 1
                }
            } else {
                if words.contains(normalizedKeyword) { score += 1 }
            }
        }
    }

    static func thematicSearchQuery(for listName: String) -> String {
        let words = normalizedWords(from: listName)
        let tokens = words.filter { $0.count >= 3 && !stopWords.contains($0) }
        let normalizedListText = normalizedText(from: listName)

        if let thematic = themeExpansions.keys.first(
            where: { theme in
                let themeWords = theme.split(separator: " ").map(String.init)
                return themeWords.allSatisfy({ words.contains($0) }) || normalizedListText.contains(theme)
            }
        ) {
            return thematic
        }
        return tokens.joined(separator: " ")
    }

    static func normalizedWords(from text: String) -> [String] {
        normalizedText(from: text)
            .split(separator: " ")
            .map(String.init)
    }

    static func normalizedText(from text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
