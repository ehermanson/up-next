import Foundation

/// TMDB supplies real candidates; Jev interprets the collection's unmodified name.
/// No theme aliases, inferred keyword filters, or rating floor determine membership — the one
/// exception is an empty collection named after a `CollectionIdea`, whose fixed discover query
/// is its starting pool.
enum CollectionRecommendationEngine {
    static func load<T: RecommendableResult>(
        name: String, seeds: [Int], excluding existing: Set<String>,
        recommendations: @escaping @Sendable (Int) async throws -> [T],
        member: @escaping @Sendable (Int) async throws -> JevTitle,
        candidate: @escaping @Sendable (T) -> JevTitle,
        initialPool: @escaping @Sendable (String) async throws -> [T],
        jev: JevRecommendationService = .shared
    ) async -> [T] {
        let uniqueSeeds = Array(Set(seeds).sorted().prefix(8))
        let sources = await withTaskGroup(of: (Int, [T], JevTitle?).self) { group in
            for id in uniqueSeeds {
                group.addTask {
                    async let results = try? await recommendations(id)
                    // Metadata is unnecessary when the optional Jev credential is absent.
                    async let info = jev.isConfigured ? try? await member(id) : nil
                    return await (id, results ?? [], info)
                }
            }
            var values: [(Int, [T], JevTitle?)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return [] }
        // A new collection has no recommendation seeds. A suggested name's discover query, else
        // a literal TMDB title search, gives it a starting pool (see `TMDBService.collectionMovies`).
        let initial: [T]
        if uniqueSeeds.isEmpty {
            let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
            initial = query.isEmpty ? [] : (try? await initialPool(query)) ?? []
        } else {
            initial = []
        }
        let baseline = rank(seedResults: sources.map { $0.1 }, initial: initial, excluding: existing)
        guard !Task.isCancelled else { return [] }
        let members = sources.compactMap { $0.2 }
        guard members.count == uniqueSeeds.count,
              let ids = await jev.rank(name: name, members: members, candidates: baseline.map(candidate))
        else { return Array(baseline.prefix(20)) }
        guard !Task.isCancelled else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        return ids.prefix(20).compactMap { byID[$0] }
    }

    /// A bounded retrieval pool and the full fallback order if any Jev batch fails.
    static func rank<T: RecommendableResult>(seedResults: [[T]], initial: [T], excluding existing: Set<String>) -> [T] {
        var candidates: [Int: T] = [:]
        var scores: [Int: Double] = [:]
        for results in seedResults + (initial.isEmpty ? [] : [initial]) {
            var seen: Set<Int> = []
            for (index, result) in results.enumerated() {
                guard seen.insert(result.id).inserted, !existing.contains(String(result.id)),
                      RecommendationEngine.hasEnoughVotes(result) else { continue }
                candidates[result.id] = candidates[result.id] ?? result
                scores[result.id, default: 0] += RecommendationEngine.rankDecay(index)
            }
        }
        return candidates.values.sorted { a, b in
            let left = scores[a.id, default: 0], right = scores[b.id, default: 0]
            return left == right ? a.id < b.id : left > right
        }.prefix(36).map { $0 }
    }
}
