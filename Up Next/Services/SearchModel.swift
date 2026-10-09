import Foundation
import FoundationModels
import os
import Synchronization

/// Apple's on-device language model (Foundation Models) reading the *shape* of a search query:
/// a name or a description; the bare title in "the bear hulu"; the person in "tom hanks
/// christmas"; the title in "anything in the vein of ted lasso"; the subjects of a sentence-long
/// description ("movie where a guy relives the same day" → time loop); and, for a description,
/// the well-known titles that fit it (→ Groundhog Day).
///
/// It is deliberately not asked for genres, services, years or origins: those are closed
/// vocabularies TMDB can filter on, and `DescriptiveSearch`'s lexicons read them off the query
/// text directly. Asked for them, a small model fills every field with something plausible
/// ("1917" came back on Netflix, from 2019, British, by David Bowie, like The Godfather). What
/// it is asked for is open-ended, and `DescriptiveSearch.ground` keeps each answer only when
/// the words appear in the query and TMDB knows them — so a misreading drops a facet rather
/// than inventing a filter, and the fix for a misread query shape is this prompt, not a rule.
///
/// Runs only where Apple Intelligence is available and enabled; everywhere else `read` returns
/// nil and search is `DescriptiveSearch`'s rules alone. Nothing leaves the device. The model
/// invents titles now and then ("Minor League"), so a guess is kept only when a title search
/// finds that exact, known title. Apple's guardrails refuse some descriptions outright ("…makes
/// meth") — those fall back to the rules too.
enum SearchModel {
    /// What the model made of a query. Strings are as the model wrote them — `DescriptiveSearch`
    /// normalizes and grounds them. Nil means "the query doesn't say".
    nonisolated struct Reading: Sendable, Equatable {
        /// The query is a specific title's name, or the start of one.
        let isTitleName: Bool
        /// That name on its own, without service or type words ("the bear hulu" → "The Bear").
        var title: String?
        /// An actor, director or creator the query names.
        var person: String?
        /// The title in "shows like ted lasso".
        var similarTo: String?
        /// What a sentence-long description is about, as TMDB might tag it ("time loop").
        var subjects: [String] = []
        /// Well-known titles the description fits, most likely first; empty for a name.
        var titles: [String] = []
    }

    @Generable
    nonisolated struct Output {
        @Guide(description: "True if the query is the name of one specific movie or TV show, or the start of one, even with a streaming service or \"movie\"/\"show\" next to it (\"the office\", \"family guy\", \"mad max\", \"the bear hulu\", \"1917\"). False if it describes what the person wants to watch (\"zombies\", \"cozy mysteries\", \"show about a chef\", \"shows like ted lasso\", \"tom hanks movies\").")
        var isTitleName: Bool

        @Guide(description: "For a description: up to five real, well-known movies or TV shows that fit it best, most likely first, by their exact official titles. Only the kind asked for when the query says movies or shows. Empty for a name, or when unsure.", .maximumCount(5))
        var titles: [String]

        @Guide(description: "When isTitleName: that title alone, copied from the query without the service or type words around it (\"the bear hulu\" → \"the bear\", \"breaking bad netflix\" → \"breaking bad\"). Otherwise empty.")
        var title: String

        @Guide(description: "An actor, director or creator the query names, copied from the query (\"tom hanks movies\" → \"tom hanks\"). Empty unless the query contains a person's name.")
        var person: String

        @Guide(description: "The title the query wants things similar to, copied from the query (\"shows like ted lasso on netflix\" → \"ted lasso\", \"something similar to the bear\" → \"the bear\"). Empty unless the query asks for things like a title.")
        var similarTo: String

        @Guide(description: "Only when the query describes a plot or premise in a sentence (\"movie where a guy relives the same day\"): one or two subjects TMDB might tag it with (\"time loop\"). Empty for a name, a genre, or a short phrase.", .maximumCount(2))
        var subjects: [String]
    }

    private nonisolated static let instructions = """
        You read what someone typed into the search field of an app for tracking movies and TV \
        shows. Decide whether it names a specific title or describes what they want to watch. \
        Copy a title, person or "like" title from the query's own words; never add one the query \
        doesn't contain. For a description, suggest the titles that fit it best. Never invent titles.
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
        @Guide(description: "Five real, well-known titles of the type asked for, most similar in tone, feel and viewing experience, by exact official title, most similar first. Not the title itself.", .maximumCount(5))
        var titles: [String]
    }

    /// Titles like `title` in tone and feel — what TMDB's recommendations miss: for Ted Lasso
    /// they're sports shows (*Ballers*, *Shoresy*), while this names *The Office*, *Abbott
    /// Elementary*, *Schitt's Creek*. A prompt of its own: asked as part of reading a query, the
    /// model's answers were much worse. Nil like `read`.
    ///
    /// The asked-for type can differ from the title's ("movies like the office").
    /// `qualities` are genres the results must have too ("severance that are funny" → comedy).
    static func similarTitles(
        to title: String, referenceIsTVShow: Bool, wantsTVShows: Bool, qualities: [String] = []
    ) async -> [String]? {
        guard isAvailable else { return nil }
        let prompt = "Someone searched for \(wantsTVShows ? "TV shows" : "movies") like \(title) "
            + "(\(referenceIsTVShow ? "TV show" : "movie"))"
            + (qualities.isEmpty ? "." : " that are \(qualities.joined(separator: " and ")).")
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

    /// `body`'s result, or nil when it throws or outlives `timeout` — returning at the timeout
    /// even if `body` hasn't stopped (a task group would wait for it). Failures other than
    /// cancellation are logged.
    private static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
        let gate = FirstResult<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Task {
                    do {
                        gate.finish(try await body())
                    } catch {
                        if !(error is CancellationError) {
                            AppLog.search.info("Search model gave no answer: \(error.localizedDescription, privacy: .public)")
                        }
                        gate.finish(nil)
                    }
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    gate.finish(nil)
                }
                gate.install(continuation, cancelling: [work, timer])
            }
        } onCancel: {
            gate.finish(nil)
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
        return Reading(isTitleName: true, title: query)
    }

    /// Nil when the model is unavailable, refuses, errors or runs past `timeout`.
    static func read(_ query: String) async -> Reading? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // "a", "th": still being typed, and nothing to read.
        guard isAvailable, query.count >= 3, query.count <= 200 else { return nil }
        let reading = await withTimeout {
            // A fresh session per query: a session keeps its transcript, and an earlier query
            // would color this one.
            let session = LanguageModelSession(model: model, instructions: instructions)
            let output = try await session.respond(
                to: "Search query: \(query)", generating: Output.self, options: GenerationOptions(samplingMode: .greedy)
            ).content
            func text(_ value: String) -> String? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Reading(
                isTitleName: output.isTitleName, title: text(output.title), person: text(output.person),
                similarTo: text(output.similarTo), subjects: output.subjects.compactMap(text),
                titles: output.titles.compactMap(text)
            )
        }
        return reading.map { consistent($0, query: query) }
    }
}

/// The first of several racing outcomes resumes the continuation; the rest are dropped and the
/// racers cancelled. An outcome may arrive before the continuation is installed.
private nonisolated final class FirstResult<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var outcome: T??
        var racers: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T?, Never>, cancelling racers: [Task<Void, Never>]) {
        let early: T?? = state.withLock { state in
            guard state.outcome == nil else { return state.outcome }
            state.continuation = continuation
            state.racers = racers
            return nil
        }
        if let early {
            racers.forEach { $0.cancel() }
            continuation.resume(returning: early)
        }
    }

    func finish(_ value: T?) {
        let (continuation, racers): (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) = state.withLock { state in
            guard state.outcome == nil else { return (nil, []) }
            state.outcome = .some(value)
            defer { state.continuation = nil; state.racers = [] }
            return (state.continuation, state.racers)
        }
        racers.forEach { $0.cancel() }
        continuation?.resume(returning: value)
    }
}
