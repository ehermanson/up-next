import Foundation
import FoundationModels
import os

/// Apple's on-device language model (Foundation Models) reading a search query, for the two
/// things `DescriptiveSearch`'s rules can't do: tell a title's name from a description when TMDB
/// has a title for nearly every word ("zombies", "kids"), and name the well-known titles a
/// description fits ("movie where a guy relives the same day" → Groundhog Day).
///
/// Runs only where Apple Intelligence is available and enabled; everywhere else `read` returns
/// nil and search is the rules alone. Nothing leaves the device. The model is small and invents
/// titles now and then ("Minor League"), so `DescriptiveSearch` keeps a guess only when a title
/// search finds that exact, known title. Apple's guardrails refuse some descriptions outright
/// ("…makes meth") — those fall back to the rules too.
enum SearchModel {
    /// What the model made of a query.
    nonisolated struct Reading: Sendable, Equatable {
        /// The query is a specific title's name, or the start of one.
        let isTitleName: Bool
        /// Well-known titles the description fits, most likely first; empty for a name.
        let titles: [String]
    }

    @Generable
    nonisolated struct Output {
        @Guide(description: "True if the query is the name of one specific movie or TV show, or the start of one (\"the office\", \"family guy\", \"mad max\"). False if it describes what the person wants to watch (\"zombies\", \"cozy mysteries\", \"show about a chef\").")
        var isTitleName: Bool

        @Guide(description: "For a description: up to five real, well-known movies or TV shows that fit it best, most likely first, by their exact official titles. Only the type asked for when the query says movies or shows. Empty for a name, or when unsure.", .maximumCount(5))
        var titles: [String]
    }

    private nonisolated static let instructions = """
        You read what someone typed into the search field of an app for tracking movies and TV \
        shows. Decide whether it names a specific title or describes what they want to watch, and \
        for a description, suggest the titles that fit it best. Never invent titles.
        """

    /// The model's queries are untrusted text to classify, not requests to act on — the
    /// permissive guardrails let ordinary genre words ("slasher", "killer") through.
    private nonisolated static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// `SEARCH_MODEL=off` in the environment turns it off — how `check_search.sh` scores the
    /// rules alone.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["SEARCH_MODEL"] != "off" && SystemLanguageModel.default.isAvailable
    }

    /// Past this the title search's results are long on screen and a reading would only reorder
    /// them under the user; the rules carry on without it. A warm call takes ~1 s, a cold ~3 s.
    private nonisolated static let timeout: Duration = .seconds(4)

    /// Loads the model ahead of the first query — call when a search field appears.
    static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(model: model, instructions: instructions).prewarm()
    }

    @Generable
    nonisolated struct SimilarOutput {
        @Guide(description: "Eight real, well-known titles of the same type most similar in tone, feel and viewing experience, by exact official title, most similar first. Not the title itself.", .maximumCount(8))
        var titles: [String]
    }

    /// Titles like `title` in tone and feel — what TMDB's recommendations miss: for Ted Lasso
    /// they're sports shows (*Ballers*, *Shoresy*), while this names *The Office*, *Abbott
    /// Elementary*, *Schitt's Creek*. A prompt of its own: asked as part of reading a query, the
    /// model's answers were much worse. Nil like `read`.
    static func similarTitles(to title: String, isTVShow: Bool) async -> [String]? {
        guard isAvailable else { return nil }
        let prompt = "Someone searched for titles like \(title) (\(isTVShow ? "TV show" : "movie"))."
        return await withTimeout {
            let session = LanguageModelSession(
                model: model,
                instructions: "You recommend movies and TV shows. Match tone and feel, not just surface subject matter."
            )
            let response = try await session.respond(
                to: prompt, generating: SimilarOutput.self, options: GenerationOptions(samplingMode: .greedy)
            )
            // It sometimes labels them ("Normal People (TV show)"), which no title search matches.
            return response.content.titles.map {
                $0.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            }
        }
    }

    /// `body`'s result, or nil when it throws or outlives `timeout`. Failures other than
    /// cancellation are logged.
    private static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
        let outcome = await withTaskGroup(of: Result<T, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error) where !(error is CancellationError):
            AppLog.search.info("Search model gave no answer: \(error.localizedDescription, privacy: .public)")
            return nil
        default:
            return nil
        }
    }

    /// A "description" whose guess is the query itself is a name: the model reads "arrow" as a
    /// description and then suggests *The Arrow*.
    private static func consistent(_ reading: Reading, query: String) -> Reading {
        func core(_ text: String) -> String {
            let normalized = SearchRanking.normalized(text)
            return normalized.hasPrefix("the ") ? String(normalized.dropFirst(4)) : normalized
        }
        guard !reading.isTitleName, reading.titles.contains(where: { core($0) == core(query) }) else { return reading }
        return Reading(isTitleName: true, titles: [])
    }

    /// Nil when the model is unavailable, refuses, errors or runs past `timeout`.
    static func read(_ query: String) async -> Reading? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !query.isEmpty, query.count <= 200 else { return nil }
        let reading = await withTimeout {
            // A fresh session per query: a session keeps its transcript, and an earlier query
            // would color this one.
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: "Search query: \(query)", generating: Output.self, options: GenerationOptions(samplingMode: .greedy)
            )
            return Reading(isTitleName: response.content.isTitleName, titles: response.content.titles)
        }
        return reading.map { consistent($0, query: query) }
    }
}
