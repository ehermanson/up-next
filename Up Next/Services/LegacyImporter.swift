import Foundation
import OSLog

/// One-time migration of an Up Next 1.x library into the 2.0 store.
///
/// 1.x kept its own SwiftData store and its own CloudKit container, so a user who updates lands in
/// an empty app with the old file still sitting untouched on disk. `LegacyStoreReader` parses that
/// file; this type turns the result into real rows by going through the same view-model APIs the
/// rest of the app adds titles with (`addTVShow` / `addMovie` / `addItem`), so canonical media
/// rows, store assignment and saving all behave exactly as they do for a manual add.
///
/// Re-running is safe: every title is checked against the library first, so a partial import
/// picked up again only adds what's missing. The 1.x store is never modified or deleted — a
/// downgrade back to 1.7 still finds its data.
@MainActor
@Observable
final class LegacyImporter {
    static let shared = LegacyImporter()

    enum State {
        case idle
        case reading
        case importing(done: Int, total: Int)
        case finished(ImportResult)
        case failed(any Error)
    }

    enum ImportError: LocalizedError {
        case libraryNotReady

        var errorDescription: String? {
            switch self {
            case .libraryNotReady:
                return "Up Next is still loading. Try again in a moment."
            }
        }
    }

    struct ImportResult: Sendable {
        /// Titles added to the TV Shows / Movies tabs.
        let imported: Int
        /// Titles that were already there (a rerun, or the user re-added them by hand).
        let skippedExisting: Int
        let failed: Int
        /// Collections created or matched by name.
        let collections: Int
    }

    private(set) var state: State = .idle

    private static let completedKey = "legacyImport.completedAt"
    private static let dismissedKey = "legacyImport.dismissed"

    /// Whether the offer sheet should be shown: a 1.x store is on disk and the user has neither
    /// imported it nor said "Not Now".
    static var isOfferPending: Bool {
        guard !hasCompletedImport else { return false }
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return false }
        return LegacyStoreReader.storeExists()
    }

    /// True once a run finished. The Settings row disappears at that point — the 1.x file stays
    /// on disk, but there's nothing left to offer.
    static var hasCompletedImport: Bool {
        UserDefaults.standard.object(forKey: completedKey) != nil
    }

    private var isRunning = false

    private init() {}

    func dismissOffer() {
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
    }

    /// Clears a previous run's outcome. The sheet can be reopened from Settings, and it should
    /// open on the offer rather than on the last run's result.
    func resetState() {
        guard !isRunning else { return }
        state = .idle
    }

    /// Counts for the offer sheet. Reading the whole store costs one pass over a few hundred rows,
    /// which is cheaper than keeping a second, summary-only query in sync with the real one.
    func summary() throws -> LegacyLibrary.Summary {
        try LegacyStoreReader.read().summary
    }

    // MARK: - Import

    func run(library: MediaLibraryViewModel, lists: CustomListViewModel) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        // A 1.x library arriving isn't "someone added 80 titles" — keep it out of the activity log.
        PersistenceController.shared.isSuppressingActivity = true
        defer { PersistenceController.shared.isSuppressingActivity = false }

        // Until the view model's lists resolve, `addTVShow` / `addMovie` queue the row and replay
        // it later — there'd be no `ListItem` to copy the 1.x watched state onto. Wait it out.
        guard library.isLoaded else {
            AppLog.importer.notice("legacy import refused: the library hasn't loaded yet")
            state = .failed(ImportError.libraryNotReady)
            return
        }

        state = .reading
        do {
            // The reader is nonisolated and does file I/O, so keep it off the main actor.
            let legacy = try await Task.detached(priority: .userInitiated) {
                try LegacyStoreReader.read()
            }.value

            let result = await performImport(legacy, library: library, lists: lists)
            guard !Task.isCancelled else {
                state = .idle
                return
            }
            UserDefaults.standard.set(Date.now, forKey: Self.completedKey)
            AppLog.importer.notice(
                "legacy import finished: \(result.imported) imported, \(result.skippedExisting) already present, \(result.failed) failed, \(result.collections) collections"
            )
            state = .finished(result)
        } catch {
            AppLog.importer.error("legacy import failed: \(error)")
            state = .failed(error)
        }
    }

    private func performImport(
        _ legacy: LegacyLibrary,
        library: MediaLibraryViewModel,
        lists: CustomListViewModel
    ) async -> ImportResult {
        let entries = legacy.libraryEntries
        let collectionEntries = legacy.collections.flatMap(\.entries)

        // One row per distinct title, whether it's on a watchlist, in a collection, or both.
        var wanted: [LegacyLibrary.Title] = []
        var seenKeys = Set<String>()
        for title in entries.map(\.title) + collectionEntries.map(\.title) {
            guard seenKeys.insert(Self.key(for: title)).inserted else { continue }
            wanted.append(title)
        }

        state = .importing(done: 0, total: wanted.count)
        let rows = await resolveRows(for: wanted)

        var imported = 0
        var skippedExisting = 0
        var failed = 0

        for entry in entries {
            guard !Task.isCancelled else { break }
            let title = entry.title
            let mediaID = String(title.tmdbID)
            guard !library.containsItem(withID: mediaID, mediaType: title.mediaType.mediaType) else {
                skippedExisting += 1
                continue
            }

            let listItem: ListItem?
            switch title.mediaType {
            case .tvShow:
                guard let row = rows.tvShows[title.tmdbID] else { failed += 1; continue }
                library.addTVShow(row)
                listItem = library.tvShows.first { $0.tvShow?.id == mediaID }
            case .movie:
                guard let row = rows.movies[title.tmdbID] else { failed += 1; continue }
                library.addMovie(row)
                listItem = library.movies.first { $0.movie?.id == mediaID }
            }

            guard let listItem else {
                failed += 1
                continue
            }
            apply(entry, to: listItem)
            imported += 1
        }

        library.persistChanges(for: .tvShow)
        library.persistChanges(for: .movie)

        let collections = importCollections(legacy.collections, rows: rows, into: lists)

        PersistenceController.shared.save()
        return ImportResult(
            imported: imported, skippedExisting: skippedExisting,
            failed: failed, collections: collections
        )
    }

    /// Copies 1.x viewing state onto a freshly added item. Season marks are clamped: a 1.x mark can
    /// name a season TMDB has since renumbered away, and `nextSeasonToWatch` would then never
    /// settle.
    private func apply(_ entry: LegacyLibrary.ListEntry, to item: ListItem) {
        item.addedAt = entry.addedAt
        item.order = entry.order
        item.userRating = entry.userRating
        item.userNotes = entry.userNotes
        item.droppedAt = entry.droppedAt
        item.isWatched = entry.isWatched
        item.watchedAt = entry.watchedAt
        let total = item.tvShow?.numberOfSeasons
        item.watchedSeasons = entry.watchedSeasons.filter { season in
            season >= 1 && (total.map { season <= $0 } ?? true)
        }
    }

    private func importCollections(
        _ collections: [LegacyLibrary.Collection],
        rows: ResolvedRows,
        into lists: CustomListViewModel
    ) -> Int {
        var touched = 0
        for collection in collections {
            guard !Task.isCancelled else { break }
            guard let target = destination(for: collection, in: lists) else { continue }
            touched += 1

            for entry in collection.entries {
                let mediaID = String(entry.title.tmdbID)
                let mediaType = entry.title.mediaType.mediaType
                if !lists.containsItem(mediaID: mediaID, mediaType: mediaType, in: target) {
                    switch entry.title.mediaType {
                    case .tvShow:
                        guard let row = rows.tvShows[entry.title.tmdbID] else { continue }
                        lists.addItem(tvShow: row, to: target)
                    case .movie:
                        guard let row = rows.movies[entry.title.tmdbID] else { continue }
                        lists.addItem(movie: row, to: target)
                    }
                }
                guard let item = lists.item(mediaID: mediaID, mediaType: mediaType, in: target) else { continue }
                item.addedAt = entry.addedAt
                item.watchedAt = entry.watchedAt
            }
        }
        return touched
    }

    /// An existing collection with the same name (the user may already have re-created it by hand),
    /// otherwise a new one.
    private func destination(
        for collection: LegacyLibrary.Collection, in lists: CustomListViewModel
    ) -> CustomList? {
        if let existing = lists.customLists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(collection.name) == .orderedSame
        }) {
            return existing
        }
        lists.createList(name: collection.name)
        // `createList` is a no-op while the group is unresolved; never fall through to some other
        // list that happens to be last.
        guard let created = lists.customLists.last, created.name == collection.name else { return nil }
        // The Collections tab sorts by creation date, so keep the 1.x order.
        created.createdAt = collection.createdAt
        return created
    }

    // MARK: - TMDB rows

    private struct ResolvedRows {
        var tvShows: [Int: TVShow] = [:]
        var movies: [Int: Movie] = [:]
    }

    /// Fetches full TMDB detail for every distinct title, eight at a time — the same batching and
    /// provider handling `MediaLibraryViewModel.refreshAllItems` uses. A failed fetch (offline, or
    /// a title TMDB has since removed) falls back to the same stub a search result produces, so the
    /// import still works without a connection; the 6-hour refresh fills the rest in later.
    private func resolveRows(for titles: [LegacyLibrary.Title]) async -> ResolvedRows {
        let service = TMDBService.shared
        let maxConcurrent = 8
        let total = titles.count
        var rows = ResolvedRows()
        var done = 0

        let tvTitles = titles.filter { $0.mediaType == .tvShow }
        let movieTitles = titles.filter { $0.mediaType == .movie }

        for batch in stride(from: 0, to: tvTitles.count, by: maxConcurrent) {
            guard !Task.isCancelled else { return rows }
            let slice = tvTitles[batch..<min(batch + maxConcurrent, tvTitles.count)]
            let byID = Dictionary(uniqueKeysWithValues: slice.map { ($0.tmdbID, $0) })
            let results = await withTaskGroup(of: (Int, TMDBTVShowDetail?).self) { group in
                for title in slice {
                    let id = title.tmdbID
                    group.addTask { (id, try? await service.getTVShowDetails(id: id)) }
                }
                var out: [(Int, TMDBTVShowDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            for (id, detail) in results {
                guard let title = byID[id] else { continue }
                if let detail {
                    let providers = detail.watchProviders?.results?[service.currentRegion]
                    rows.tvShows[id] = await service.mapToTVShow(detail, providers: providers)
                } else {
                    rows.tvShows[id] = service.mapToTVShow(Self.tvStub(for: title))
                }
                done += 1
                state = .importing(done: done, total: total)
            }
        }

        for batch in stride(from: 0, to: movieTitles.count, by: maxConcurrent) {
            guard !Task.isCancelled else { return rows }
            let slice = movieTitles[batch..<min(batch + maxConcurrent, movieTitles.count)]
            let byID = Dictionary(uniqueKeysWithValues: slice.map { ($0.tmdbID, $0) })
            let results = await withTaskGroup(of: (Int, TMDBMovieDetail?).self) { group in
                for title in slice {
                    let id = title.tmdbID
                    group.addTask { (id, try? await service.getMovieDetails(id: id)) }
                }
                var out: [(Int, TMDBMovieDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            for (id, detail) in results {
                guard let title = byID[id] else { continue }
                if let detail {
                    let providers = detail.watchProviders?.results?[service.currentRegion]
                    rows.movies[id] = await service.mapToMovie(detail, providers: providers)
                } else {
                    rows.movies[id] = service.mapToMovie(Self.movieStub(for: title))
                }
                done += 1
                state = .importing(done: done, total: total)
            }
        }

        return rows
    }

    private static func tvStub(for title: LegacyLibrary.Title) -> TMDBTVShowSearchResult {
        TMDBTVShowSearchResult(
            id: title.tmdbID, name: title.title, overview: nil,
            posterPath: title.posterPath, backdropPath: title.backdropPath,
            firstAirDate: nil, voteAverage: nil, genreIds: nil, voteCount: nil,
            originalName: nil, popularity: nil
        )
    }

    private static func movieStub(for title: LegacyLibrary.Title) -> TMDBMovieSearchResult {
        TMDBMovieSearchResult(
            id: title.tmdbID, title: title.title, overview: nil,
            posterPath: title.posterPath, backdropPath: title.backdropPath,
            releaseDate: nil, voteAverage: nil, genreIds: nil, voteCount: nil,
            originalTitle: nil, popularity: nil
        )
    }

    /// TMDB movie and TV ids are separate namespaces (see `MediaIDKey`).
    private static func key(for title: LegacyLibrary.Title) -> String {
        "\(title.mediaType.rawValue):\(title.tmdbID)"
    }
}

extension LegacyMediaType {
    /// `LegacyStoreReader` is app-type-free, so the bridge to the app's own enum lives here.
    var mediaType: MediaType {
        switch self {
        case .tvShow: .tvShow
        case .movie: .movie
        }
    }
}
