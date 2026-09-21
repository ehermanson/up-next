import CoreData
import Foundation
import OSLog

@MainActor
@Observable
final class MediaLibraryViewModel {
    var tvShows: [ListItem] = []
    var movies: [ListItem] = []
    var watchingTVShows: [ListItem] = []
    var unwatchedTVShows: [ListItem] = []
    var unwatchedMovies: [ListItem] = []
    var watchedTVShows: [ListItem] = []
    var watchedMovies: [ListItem] = []
    var isLoaded = false
    /// True while a user-initiated (pull-to-refresh) run is in flight.
    private(set) var isRefreshing = false

    // Derived data — updated in syncUnwatched to avoid recomputation on every body call
    private(set) var availableTVGenres: [String] = []
    private(set) var availableMovieGenres: [String] = []
    private(set) var availableTVProviderCategories: [String] = []
    private(set) var availableMovieProviderCategories: [String] = []
    private(set) var existingTVShowIDs: Set<String> = []
    private(set) var existingMovieIDs: Set<String> = []

    private var persistence: PersistenceController?
    private var tvList: MediaList?
    private var movieList: MediaList?
    private var refreshTask: Task<Void, Never>?

    /// A swipe-deleted item that has been removed from the visible lists but not yet committed to
    /// the store, so it can be restored via `undoLastDeletion()`.
    private struct PendingDeletion {
        let item: ListItem
        let mediaType: MediaType
        let index: Int
    }
    private var pendingDeletion: PendingDeletion?
    private var pendingDeleteCommit: Task<Void, Never>?

    /// Titles added before the lists resolved — a fresh CloudKit launch waits up to 10 s for the
    /// first import, and the caller has already toasted "added" by then. Replayed by
    /// `flushPendingAdds()` as soon as `reloadFromStore()` sees the group land.
    private var pendingAdds: [(tvShow: TVShow?, movie: Movie?)] = []

    private static let lastRefreshVersionKey = "lastFullRefreshVersion"
    private static let lastRefreshDateKey = "lastFullRefreshDate"
    /// Refresh cached TMDB data (air dates, providers, season counts) at most this
    /// often on launch, so "Next" air dates don't go stale when the app version is
    /// unchanged but the app hasn't been opened in a while.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    private var needsFullRefresh: Bool {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let last = UserDefaults.standard.string(forKey: Self.lastRefreshVersionKey)
        if last != current { return true }
        guard let lastDate = UserDefaults.standard.object(forKey: Self.lastRefreshDateKey) as? Date else {
            return true
        }
        return Date.now.timeIntervalSince(lastDate) >= Self.refreshInterval
    }

    private func markRefreshComplete() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        UserDefaults.standard.set(current, forKey: Self.lastRefreshVersionKey)
        UserDefaults.standard.set(Date.now, forKey: Self.lastRefreshDateKey)
    }

    // `PersistenceController.shared` is main-actor isolated, so it can't be a default argument on a
    // nonisolated declaration — resolved inside instead, leaving `configure()` call sites unchanged.
    func configure(persistence: PersistenceController? = nil) async {
        guard self.persistence == nil else { return }
        let persistence = persistence ?? .shared
        self.persistence = persistence

        guard persistence.group != nil else {
            // Joining a shared library: the share hasn't landed yet, so there are no lists to
            // read. `ContentView` shows a placeholder; `reloadFromStore()` picks this back up once
            // `persistence.remoteChangeCount` bumps and `group` is set.
            return
        }

        resolveLists()
        let didSeed = await loadItems()
        isLoaded = true
        if !didSeed {
            scheduleLaunchRefresh()
        }
    }

    /// Starts the background launch refresh when the cached TMDB data is due one. Shared by
    /// `configure()` and `reloadFromStore()` — a participant whose library only arrives after the
    /// share import would otherwise never get one.
    private func scheduleLaunchRefresh() {
        guard needsFullRefresh else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            // Don't stamp the refresh when every fetch failed (e.g. an offline launch),
            // otherwise stale air dates are locked in for the whole refresh interval.
            if await refreshAllItems() {
                markRefreshComplete()
            }
        }
    }

    /// Pull-to-refresh: refreshes every item now, ignoring the 6-hour launch interval. Runs inline
    /// (not detached) so the refresh control can await it, and supersedes any launch refresh still
    /// in flight. Only stamps the run when something actually came back — same rule as `configure`.
    func refreshNow() async {
        guard !isRefreshing, persistence != nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = true
        defer { isRefreshing = false }
        if await refreshAllItems() {
            markRefreshComplete()
        }
    }

    /// Re-fetches both lists from the active store and re-syncs derived state. Called by
    /// `ContentView` whenever `persistence.remoteChangeCount` changes — a remote edit from another
    /// peer, or (when `group` was nil at `configure` time) the shared library finally landing.
    /// Any item mid-undo (`pendingDeletion`) is kept out of the visible arrays so a remote change
    /// can never resurrect something the user just swiped away. Also the single hook for the
    /// library disappearing: `acceptShare` / `leaveShare` purge a whole store, so every object
    /// these arrays hold is gone and must not be read again.
    func reloadFromStore() {
        guard let persistence else { return }

        guard persistence.group != nil else {
            // Joining or leaving a share: the store this view model was reading was purged, so the
            // arrays hold deleted objects. Drop everything (including the undo window — its item
            // no longer exists to commit) and wait for the group to land.
            refreshTask?.cancel()
            refreshTask = nil
            pendingDeleteCommit?.cancel()
            pendingDeleteCommit = nil
            pendingDeletion = nil
            tvList = nil
            movieList = nil
            tvShows = []
            movies = []
            watchingTVShows = []
            unwatchedTVShows = []
            unwatchedMovies = []
            watchedTVShows = []
            watchedMovies = []
            availableTVGenres = []
            availableMovieGenres = []
            availableTVProviderCategories = []
            availableMovieProviderCategories = []
            existingTVShowIDs = []
            existingMovieIDs = []
            isLoaded = false
            isRefreshing = false
            return
        }

        // The lists being nil means this is the first reload after the library landed.
        let wasAwaitingLibrary = tvList == nil
        resolveLists()

        let (fetchedTV, fetchedMovies) = fetchListItems()
        tvShows = fetchedTV.filter { $0 !== pendingDeletion?.item }
        movies = fetchedMovies.filter { $0 !== pendingDeletion?.item }

        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)
        flushPendingAdds()
        isLoaded = true

        if wasAwaitingLibrary {
            scheduleLaunchRefresh()
        }
    }

    /// Replays anything queued by `addTVShow` / `addMovie` while the lists were unresolved. Rows
    /// invalidated in the meantime (a purge between the add and the library landing) are dropped —
    /// reading their fields would fault.
    private func flushPendingAdds() {
        guard !pendingAdds.isEmpty else { return }
        let queued = pendingAdds
        pendingAdds.removeAll()
        for pending in queued {
            if let tvShow = pending.tvShow, isUsable(tvShow) {
                addTVShow(tvShow)
            } else if let movie = pending.movie, isUsable(movie) {
                addMovie(movie)
            } else {
                AppLog.library.notice("dropped a queued add whose media row no longer exists")
            }
        }
    }

    /// Whether a media row held across a wait can still be read: either never attached to a context
    /// (a freshly-mapped TMDB row) or still live in one.
    private func isUsable(_ object: NSManagedObject) -> Bool {
        guard !object.isDeleted else { return false }
        return object.managedObjectContext != nil || object.objectID.isTemporaryID
    }

    func containsItem(withID id: String, mediaType: MediaType) -> Bool {
        switch mediaType {
        case .tvShow: return tvShows.contains { $0.media?.id == id }
        case .movie: return movies.contains { $0.media?.id == id }
        }
    }

    /// Adds a show to the library. Returns whether the add was accepted — false only when the title
    /// is already there. When the lists haven't resolved yet (a fresh CloudKit launch waits for the
    /// first import) the row is queued and replayed by `reloadFromStore()`, so an "added" toast the
    /// caller already showed stays honest.
    @discardableResult
    func addTVShow(_ tvShow: TVShow) -> Bool {
        guard let persistence else { return false }
        commitPendingDeletion(ifTargeting: tvShow.id, mediaType: .tvShow)
        guard !containsItem(withID: tvShow.id, mediaType: .tvShow) else { return false }
        guard let list = tvList else {
            pendingAdds.append((tvShow: tvShow, movie: nil))
            return true
        }

        // Reuse the stored row when a collection already holds this title — one media row per id.
        let row = canonicalTVShowRow(for: tvShow, in: persistence.viewContext)
        let item = ListItem(
            tvShow: row,
            list: list,
            addedAt: Date.now,
            order: nextOrderValue(for: .tvShow)
        )
        persistence.insert(item)
        tvShows.append(item)

        syncUnwatched(for: .tvShow)
        persistence.save()
        return true
    }

    /// See `addTVShow(_:)`.
    @discardableResult
    func addMovie(_ movie: Movie) -> Bool {
        guard let persistence else { return false }
        commitPendingDeletion(ifTargeting: movie.id, mediaType: .movie)
        guard !containsItem(withID: movie.id, mediaType: .movie) else { return false }
        guard let list = movieList else {
            pendingAdds.append((tvShow: nil, movie: movie))
            return true
        }

        // Reuse the stored row when a collection already holds this title — one media row per id.
        let row = canonicalMovieRow(for: movie, in: persistence.viewContext)
        let item = ListItem(
            movie: row,
            list: list,
            addedAt: Date.now,
            order: nextOrderValue(for: .movie)
        )
        persistence.insert(item)
        movies.append(item)

        syncUnwatched(for: .movie)
        persistence.save()
        return true
    }

    /// Removes an item from the visible lists immediately but defers the Core Data delete briefly
    /// so it can be undone via `undoLastDeletion()`. Returns the removed item's title (for the
    /// toast), or nil if nothing was removed.
    @discardableResult
    func removeItem(withID id: String, mediaType: MediaType) -> String? {
        // Any previously-pending delete is now final (superseded by this one).
        commitPendingDeletion()
        guard persistence != nil else { return nil }

        let removed: ListItem
        switch mediaType {
        case .tvShow:
            guard let index = tvShows.firstIndex(where: { $0.media?.id == id }) else { return nil }
            removed = tvShows.remove(at: index)
            pendingDeletion = PendingDeletion(item: removed, mediaType: .tvShow, index: index)
        case .movie:
            guard let index = movies.firstIndex(where: { $0.media?.id == id }) else { return nil }
            removed = movies.remove(at: index)
            pendingDeletion = PendingDeletion(item: removed, mediaType: .movie, index: index)
        }

        syncUnwatched(for: mediaType)

        // Commit the delete to the store once the undo window passes (outlasts the 4.5s toast).
        pendingDeleteCommit?.cancel()
        pendingDeleteCommit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.commitPendingDeletion()
        }

        return removed.media?.title
    }

    /// Restores the most recently removed item if it hasn't been committed to the store yet.
    func undoLastDeletion() {
        pendingDeleteCommit?.cancel()
        pendingDeleteCommit = nil
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        // A remote history merge can delete the item inside the undo window (the partner removed
        // the same title, or the whole store was purged) — there's nothing left to restore.
        guard pending.item.managedObjectContext != nil, !pending.item.isDeleted else { return }

        switch pending.mediaType {
        case .tvShow:
            tvShows.insert(pending.item, at: min(pending.index, tvShows.count))
        case .movie:
            movies.insert(pending.item, at: min(pending.index, movies.count))
        }
        syncUnwatched(for: pending.mediaType)
    }

    /// Finalizes a pending delete by removing it from the store. No-op if nothing is pending.
    /// Also called when the app backgrounds, so a deferred delete can't resurrect on relaunch.
    func commitPendingDeletion() {
        pendingDeleteCommit?.cancel()
        pendingDeleteCommit = nil
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        guard let persistence else { return }
        // Already gone (a remote merge deleted it, or its store was purged) — deleting it again
        // would fault on a dead object.
        guard pending.item.managedObjectContext != nil, !pending.item.isDeleted else { return }
        let context = persistence.viewContext
        let movie = pending.item.movie
        let tvShow = pending.item.tvShow
        let itemID = pending.item.objectID
        context.delete(pending.item)
        deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: context)
        persistence.save()
    }

    /// Commits a pending delete only when it targets the same media. Re-adding an item that's
    /// awaiting deletion would otherwise leave a duplicate behind if the user then hit Undo, while
    /// adding anything *else* must leave the Undo window intact.
    private func commitPendingDeletion(ifTargeting id: String, mediaType: MediaType) {
        guard let pending = pendingDeletion,
              pending.mediaType == mediaType,
              pending.item.media?.id == id
        else { return }
        commitPendingDeletion()
    }

    func persistChanges(for mediaType: MediaType) {
        guard let persistence else { return }
        syncUnwatched(for: mediaType)
        persistence.save()
    }

    func syncUnwatched(for mediaType: MediaType) {
        switch mediaType {
        case .tvShow:
            unwatchedTVShows = syncUnwatchedItems(
                allItems: tvShows,
                currentUnwatched: unwatchedTVShows
            )
            watchingTVShows = tvShows.filter { $0.isWatching }
                .sorted { ($0.watchingStartedAt ?? .distantPast) < ($1.watchingStartedAt ?? .distantPast) }
            watchedTVShows = tvShows.filter { $0.isWatched && !$0.isWatching }
                .sorted(by: Self.mostRecentlyWatchedFirst)
            availableTVGenres = Array(Set(unwatchedTVShows.flatMap { $0.media?.genres ?? [] })).sorted()
            availableTVProviderCategories = providerCategoryLabels(from: unwatchedTVShows)
            existingTVShowIDs = Set(tvShows.compactMap { $0.media?.id })
        case .movie:
            unwatchedMovies = syncUnwatchedItems(
                allItems: movies,
                currentUnwatched: unwatchedMovies
            )
            watchedMovies = movies.filter { $0.isWatched }
                .sorted(by: Self.mostRecentlyWatchedFirst)
            availableMovieGenres = Array(Set(unwatchedMovies.flatMap { $0.media?.genres ?? [] })).sorted()
            availableMovieProviderCategories = providerCategoryLabels(from: unwatchedMovies)
            existingMovieIDs = Set(movies.compactMap { $0.media?.id })
        }
    }

    /// Watched-section order: most recently watched first, items missing a date at the bottom.
    private static func mostRecentlyWatchedFirst(_ lhs: ListItem, _ rhs: ListItem) -> Bool {
        switch (lhs.watchedAt, rhs.watchedAt) {
        case (let l?, let r?): return l > r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return false
        }
    }

    private func providerCategoryLabels(from items: [ListItem]) -> [String] {
        var rawCategories = Set<String>()
        for item in items {
            guard let categories = item.media?.providerCategories else { continue }
            for category in categories.values {
                rawCategories.insert(category)
            }
        }
        var labels: [String] = []
        if rawCategories.contains("stream") { labels.append("Stream") }
        if rawCategories.contains("ads") { labels.append("Free with Ads") }
        if rawCategories.contains("rent") || rawCategories.contains("buy") { labels.append("Rent or Buy") }
        return labels
    }

    func updateOrderAfterUnwatchedMove(mediaType: MediaType) {
        guard let persistence else { return }

        switch mediaType {
        case .tvShow:
            for (index, item) in unwatchedTVShows.enumerated() {
                item.order = index
            }
        case .movie:
            for (index, item) in unwatchedMovies.enumerated() {
                item.order = index
            }
        }

        persistence.save()
    }

    /// Re-derives watched state after a show's TMDB metadata changed. The season count itself is no
    /// longer interesting: `syncWatchedStateFromSeasons` counts only seasons that have actually
    /// started airing, so it already moves a caught-up show back to Up Next the moment a new season
    /// becomes watchable — and un-marking on the raw count would eject the show while its new season
    /// is still just an announcement with no episodes.
    func handleSeasonCountUpdate(for listItem: ListItem, previousSeasonCount: Int?) {
        guard listItem.droppedAt == nil else { return }
        listItem.syncWatchedStateFromSeasons()
        persistChanges(for: .tvShow)
    }

    // MARK: - Private helpers

    private func resolveLists() {
        guard let persistence else { return }
        tvList = persistence.list(named: "TV Shows")
        movieList = persistence.list(named: "Movies")
    }

    /// Raw fetch of every library `ListItem` (`list != nil` excludes any stray wrapper `ListItem` a
    /// collection's detail sheet left behind — see `CustomListDetailView.discardTransientItem`).
    /// Shared by `loadItems()` and `reloadFromStore()`.
    private func fetchListItems() -> (tv: [ListItem], movie: [ListItem]) {
        guard let persistence else { return ([], []) }

        let sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "addedAtRaw", ascending: true),
        ]

        let tvRequest = NSFetchRequest<ListItem>(entityName: "ListItem")
        tvRequest.predicate = NSPredicate(format: "tvShow != nil AND list != nil")
        tvRequest.sortDescriptors = sortDescriptors

        let movieRequest = NSFetchRequest<ListItem>(entityName: "ListItem")
        movieRequest.predicate = NSPredicate(format: "movie != nil AND list != nil")
        movieRequest.sortDescriptors = sortDescriptors

        return (persistence.fetch(tvRequest), persistence.fetch(movieRequest))
    }

    /// Refreshes cached TMDB metadata for every item. Returns whether the refresh can be considered
    /// complete — true when at least one detail fetch succeeded (or there was nothing to fetch),
    /// false when every fetch failed, so the caller can retry rather than stamping the run.
    private func refreshAllItems() async -> Bool {
        guard let persistence else { return false }
        let context = persistence.viewContext
        let service = TMDBService.shared
        let maxConcurrent = 8

        // Collect value-type inputs — no NSManagedObject captures in task closures. `inLibrary`
        // marks the rows a `ListItem` owns; the rest are media rows only custom lists refer to,
        // which get their metadata refreshed but none of the library's watched-state bookkeeping.
        var tvInputs: [(id: Int, inLibrary: Bool)] = tvShows.compactMap { item in
            guard let tvShow = item.tvShow, let id = Int(tvShow.id) else { return nil }
            return (id, true)
        }
        var movieInputs: [(id: Int, inLibrary: Bool)] = movies.compactMap { item in
            guard let movie = item.movie, let id = Int(movie.id) else { return nil }
            return (id, true)
        }

        // Every exit applies what was already written: the per-batch `update(from:)` /
        // `syncWatchedStateFromSeasons()` below are in-memory edits, so a run cancelled midway
        // (a pull-to-refresh, or a tab switch, superseding the launch refresh) would otherwise
        // leave rows sitting in the wrong section, unsaved, until the next launch.
        defer {
            syncUnwatched(for: .tvShow)
            syncUnwatched(for: .movie)
            persistence.save()
        }

        var seenTVIDs = Set(tvInputs.map(\.id))
        var seenMovieIDs = Set(movieInputs.map(\.id))
        let customItemsRequest = NSFetchRequest<CustomListItem>(entityName: "CustomListItem")
        for item in persistence.fetch(customItemsRequest) {
            if let tvShow = item.tvShow, let id = Int(tvShow.id), seenTVIDs.insert(id).inserted {
                tvInputs.append((id, false))
            }
            if let movie = item.movie, let id = Int(movie.id), seenMovieIDs.insert(id).inserted {
                movieInputs.append((id, false))
            }
        }
        var successfulFetches = 0

        // Fetch TV details in batches, returning Codable results. Bail between batches if this run
        // was superseded (pull-to-refresh cancels the launch refresh) so two runs don't interleave.
        for batch in stride(from: 0, to: tvInputs.count, by: maxConcurrent) {
            guard !Task.isCancelled else { return false }
            let slice = tvInputs[batch..<min(batch + maxConcurrent, tvInputs.count)]
            let results = await withTaskGroup(of: (Int, Bool, TMDBTVShowDetail?).self) { group in
                for input in slice {
                    group.addTask {
                        let detail = try? await service.getTVShowMetadata(id: input.id)
                        return (input.id, input.inLibrary, detail)
                    }
                }
                var out: [(Int, Bool, TMDBTVShowDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            // Apply updates on main actor (no isolation crossing). Match by TMDB id rather than
            // index — a delete, undo or add during the refresh shifts indices.
            for (id, inLibrary, detail) in results {
                guard let detail else { continue }
                successfulFetches += 1
                let providers = detail.watchProviders?.results?[service.currentRegion]
                let mapped = await service.mapToTVShow(detail, providers: providers)
                // The map above suspends; a join/leave purge or a committed delete can land in
                // that gap, so re-check the row is still live before writing to it.
                if inLibrary {
                    guard let listItem = tvShows.first(where: { $0.tvShow?.id == String(id) }),
                          let tvShow = listItem.tvShow,
                          Self.isLive(listItem), Self.isLive(tvShow) else { continue }
                    tvShow.update(from: mapped)
                    // Re-derive for every refreshed show, not just ones that gained a season:
                    // an announced season becoming watchable changes nothing about the count.
                    // The batched `syncUnwatched` + save below picks the results up.
                    listItem.syncWatchedStateFromSeasons()
                } else {
                    guard let tvShow = existingTVShow(id: String(id), in: context),
                          Self.isLive(tvShow) else { continue }
                    tvShow.update(from: mapped)
                }
            }
        }

        // Fetch movie details in batches
        for batch in stride(from: 0, to: movieInputs.count, by: maxConcurrent) {
            guard !Task.isCancelled else { return false }
            let slice = movieInputs[batch..<min(batch + maxConcurrent, movieInputs.count)]
            let results = await withTaskGroup(of: (Int, Bool, TMDBMovieDetail?).self) { group in
                for input in slice {
                    group.addTask {
                        let detail = try? await service.getMovieMetadata(id: input.id)
                        return (input.id, input.inLibrary, detail)
                    }
                }
                var out: [(Int, Bool, TMDBMovieDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            for (id, inLibrary, detail) in results {
                guard let detail else { continue }
                successfulFetches += 1
                let row = inLibrary
                    ? movies.first(where: { $0.movie?.id == String(id) })?.movie
                    : existingMovie(id: String(id), in: context)
                guard let movie = row else { continue }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                let mapped = await service.mapToMovie(detail, providers: providers)
                guard Self.isLive(movie) else { continue }
                movie.update(from: mapped)
            }
        }

        // Nothing to fetch counts as done; otherwise require at least one success.
        return tvInputs.isEmpty && movieInputs.isEmpty ? true : successfulFetches > 0
    }

    /// A row that's still in the context and not deleted — the only kind it's safe to write to
    /// after an `await`.
    private static func isLive(_ object: NSManagedObject) -> Bool {
        object.managedObjectContext != nil && !object.isDeleted
    }

    @discardableResult
    private func loadItems() async -> Bool {
        guard persistence != nil else { return false }
        var didSeed = false

        let (fetchedTV, fetchedMovies) = fetchListItems()
        tvShows = fetchedTV
        movies = fetchedMovies

        #if DEBUG
        if allowsDemoSeeding, tvShows.isEmpty && movies.isEmpty {
            await seedStubData()
            didSeed = true
        }
        #endif

        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)
        return didSeed
    }

    private func nextOrderValue(for mediaType: MediaType) -> Int {
        switch mediaType {
        case .tvShow:
            return (tvShows.map(\.order).max() ?? -1) + 1
        case .movie:
            return (movies.map(\.order).max() ?? -1) + 1
        }
    }

    #if DEBUG
    /// The demo library is for screenshot capture and manual UI work only. "Library is empty" is
    /// not a safe trigger on its own: a participant whose partner's library happens to be empty
    /// would push 21 demo titles into the partner's CloudKit zone, and so would any dev device
    /// signed into iCloud on a fresh install.
    private var allowsDemoSeeding: Bool {
        ScreenshotMode.isEnabled || ProcessInfo.processInfo.arguments.contains("--seed-demo")
    }
    #endif

    private func seedStubData() async {
        guard let persistence, let tvList, let movieList else { return }
        let context = persistence.viewContext
        let service = TMDBService.shared

        // TV show IDs to seed: (tmdbID, isWatched, userRating, userNotes)
        let tvSeeds: [(id: Int, watched: Bool, rating: Int?, notes: String?)] = [
            (1396, false, nil, nil),   // Breaking Bad
            (2316, false, nil, nil),   // The Office
            (97546, false, nil, nil),  // Ted Lasso
            (76479, false, nil, nil),  // The Boys
            (82856, false, nil, nil),  // The Mandalorian
            (94997, false, nil, nil),  // House of the Dragon
            (103768, false, nil, nil), // Sweet Tooth
            (95557, false, nil, nil),  // Invincible
            (1399, true, 0, "Great first 4 seasons, ending was disappointing"),  // Game of Thrones
            (66732, true, 1, nil),          // Stranger Things
            (87108, true, 1, "Intense and brilliantly made"),  // Chernobyl
            (60625, true, -1, "Got too weird after season 3"), // Rick and Morty
        ]

        // Movie IDs to seed: (tmdbID, isWatched, userRating, userNotes)
        let movieSeeds: [(id: Int, watched: Bool, rating: Int?, notes: String?)] = [
            (603692, false, nil, nil), // John Wick: Chapter 4
            (693134, false, nil, nil), // Dune: Part Two
            (545611, false, nil, nil), // Everything Everywhere All at Once
            (346698, false, nil, nil), // Barbie
            (872585, false, nil, nil), // Oppenheimer
            (438631, true, 1, "Visually stunning, can’t wait for Part Two"),   // Dune
            (299536, true, 1, nil),    // Avengers: Infinity War
            (550, true, 1, "First rule: you don’t talk about it"),             // Fight Club
            (278, true, 1, "Perfect film"),  // The Shawshank Redemption
        ]

        // Fetch all TMDB details concurrently (raw Codable structs, not managed objects)
        let tvDetails: [(Int, TMDBTVShowDetail?)] = await withTaskGroup(
            of: (Int, TMDBTVShowDetail?).self
        ) { group in
            for (index, seed) in tvSeeds.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getTVShowDetails(id: seed.id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBTVShowDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        let movieDetails: [(Int, TMDBMovieDetail?)] = await withTaskGroup(
            of: (Int, TMDBMovieDetail?).self
        ) { group in
            for (index, seed) in movieSeeds.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getMovieDetails(id: seed.id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBMovieDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        // Map to managed objects on the main actor. Detail fetches map to unattached rows, so each
        // goes through `canonical*Row` to get inserted (with its networks) and assigned to the
        // active store before the wrapping `ListItem` relates to it.
        var seedTVItems: [ListItem] = []
        for (index, detail) in tvDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let mapped = await service.mapToTVShow(detail, providers: providers)
            let row = canonicalTVShowRow(for: mapped, in: context)
            let seed = tvSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                tvShow: row,
                list: tvList,
                addedAt: Date.now.addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date.now.addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index,
                userRating: seed.rating,
                userNotes: seed.notes
            )
            persistence.insert(item)
            seedTVItems.append(item)
        }

        var seedMovieItems: [ListItem] = []
        for (index, detail) in movieDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let mapped = await service.mapToMovie(detail, providers: providers)
            let row = canonicalMovieRow(for: mapped, in: context)
            let seed = movieSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                movie: row,
                list: movieList,
                addedAt: Date.now.addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date.now.addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index,
                userRating: seed.rating,
                userNotes: seed.notes
            )
            persistence.insert(item)
            seedMovieItems.append(item)
        }

        tvShows = seedTVItems
        movies = seedMovieItems
        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)

        // Seed a "Christmas Stuff" custom list. `group:` goes through the init so the list joins
        // the group's context and store up front — setting it afterwards on a context-less object
        // is a Core Data exception (see `inferredContext`).
        let christmasList = CustomList(name: "Christmas Stuff", iconName: "gift", group: persistence.group)
        persistence.insert(christmasList)

        let christmasMovieIDs = [10719, 12540, 771, 13675]  // Elf, Four Christmases, Home Alone, Rudolph
        let christmasDetails: [(Int, TMDBMovieDetail?)] = await withTaskGroup(
            of: (Int, TMDBMovieDetail?).self
        ) { group in
            for (index, id) in christmasMovieIDs.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getMovieDetails(id: id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBMovieDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        for (_, detail) in christmasDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let mapped = await service.mapToMovie(detail, providers: providers)
            let row = canonicalMovieRow(for: mapped, in: context)
            // `customList:` maintains `christmasList.itemSet` through the Core Data inverse —
            // assigning `items` afterwards would double up the bookkeeping.
            let item = CustomListItem(movie: row, customList: christmasList, addedAt: Date.now)
            persistence.insert(item)
        }

        persistence.save()
    }
}
