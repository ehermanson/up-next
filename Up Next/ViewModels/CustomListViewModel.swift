import Foundation
import SwiftData

@MainActor
@Observable
final class CustomListViewModel {
    var customLists: [CustomList] = []
    var activeListID: UUID?

    private var modelContext: ModelContext?

    /// An item removed from a list's visible contents but not yet deleted from the store, so it can
    /// be restored via `undoLastRemoval()`. Mirrors the watchlist's deferred swipe-delete.
    private struct PendingRemoval {
        let item: CustomListItem
        let list: CustomList
        let index: Int
    }
    private var pendingRemoval: PendingRemoval?
    private var pendingRemovalCommit: Task<Void, Never>?

    /// Set once the one-time duplicate-media-row migration has run on this install.
    private static let didMigrateKey = "customListMediaRowsMigrated"

    func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        loadLists()
        migrateDuplicateMediaRows()
    }

    func createList(name: String, iconName: String) {
        guard let context = modelContext else { return }
        let list = CustomList(name: name, iconName: iconName)
        context.insert(list)
        customLists.append(list)
        save()
    }

    func deleteList(_ list: CustomList) {
        guard let context = modelContext else { return }
        // A deferred removal from this list can't outlive it.
        commitPendingRemoval()
        customLists.removeAll { $0.id == list.id }
        context.delete(list)
        save()
    }

    func updateList(_ list: CustomList, name: String, iconName: String) {
        list.name = name
        list.iconName = iconName
        save()
    }

    /// Adds a title to a list. `movie`/`tvShow` may be a freshly-mapped TMDB instance — when the
    /// title already has a stored row (in the library or another list) that row is reused and
    /// refreshed instead, so a title never ends up with two media rows.
    func addItem(movie: Movie? = nil, tvShow: TVShow? = nil, to list: CustomList) {
        guard let context = modelContext else { return }
        let mediaID = movie?.id ?? tvShow?.id
        guard let mediaID else { return }
        // Re-adding something awaiting removal would leave a duplicate behind on Undo.
        commitPendingRemoval(ifTargeting: mediaID, in: list)
        guard !containsItem(mediaID: mediaID, in: list) else { return }

        let row = (
            movie: movie.map { canonicalMovieRow(for: $0, in: context) },
            tvShow: tvShow.map { canonicalTVShowRow(for: $0, in: context) }
        )
        let item = CustomListItem(movie: row.movie, tvShow: row.tvShow, customList: list, addedAt: Date.now)
        context.insert(item)
        if list.items == nil {
            list.items = []
        }
        list.items?.append(item)
        save()
    }

    /// Removes an item from the list's visible contents immediately but defers the SwiftData delete
    /// briefly so it can be undone via `undoLastRemoval()`. Returns the removed item's title (for
    /// the toast), or nil if nothing was removed.
    @discardableResult
    func removeItem(_ item: CustomListItem, from list: CustomList) -> String? {
        // Any previously-pending removal is now final (superseded by this one).
        commitPendingRemoval()
        guard modelContext != nil else { return nil }
        guard let index = list.items?.firstIndex(where: { $0.persistentModelID == item.persistentModelID })
        else { return nil }

        let title = item.media?.title
        list.items?.remove(at: index)
        pendingRemoval = PendingRemoval(item: item, list: list, index: index)

        // Commit the delete once the undo window passes (outlasts the 4.5s toast).
        pendingRemovalCommit?.cancel()
        pendingRemovalCommit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
        }

        return title
    }

    /// Restores the most recently removed item if it hasn't been committed to the store yet.
    func undoLastRemoval() {
        pendingRemovalCommit?.cancel()
        pendingRemovalCommit = nil
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil

        // Removing from `items` nulls the inverse; restore it, then put the item back where it was
        // unless SwiftData already re-appended it while maintaining the relationship.
        pending.item.customList = pending.list
        if pending.list.items == nil {
            pending.list.items = []
        }
        let alreadyPresent = pending.list.items?
            .contains { $0.persistentModelID == pending.item.persistentModelID } ?? false
        if !alreadyPresent {
            let index = min(pending.index, pending.list.items?.count ?? 0)
            pending.list.items?.insert(pending.item, at: index)
        }
    }

    /// Finalizes a pending removal by deleting it from the store. No-op if nothing is pending.
    /// Also called when the app backgrounds, so a deferred delete can't resurrect on relaunch.
    func commitPendingRemoval() {
        pendingRemovalCommit?.cancel()
        pendingRemovalCommit = nil
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        guard let context = modelContext else { return }
        let movie = pending.item.movie
        let tvShow = pending.item.tvShow
        let itemID = pending.item.persistentModelID
        context.delete(pending.item)
        deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: context)
        save()
    }

    /// Commits a pending removal only when it targets the same title in the same list; adding
    /// anything *else* must leave the Undo window intact.
    private func commitPendingRemoval(ifTargeting mediaID: String, in list: CustomList) {
        guard let pending = pendingRemoval,
              pending.list.persistentModelID == list.persistentModelID,
              pending.item.media?.id == mediaID
        else { return }
        commitPendingRemoval()
    }

    func containsItem(mediaID: String, in list: CustomList) -> Bool {
        list.items?.contains { $0.media?.id == mediaID } ?? false
    }

    // MARK: - Watched state

    /// Flips a collection entry's own watched state. Collections track this independently — the
    /// Movies / TV Shows tabs are never created, read or modified from here.
    func toggleWatched(_ item: CustomListItem) {
        item.toggleWatched()
        save()
    }

    /// Clears the watched stamp on every entry in a collection — the "start the season over" reset.
    func markAllUnwatched(in list: CustomList) {
        for item in list.items ?? [] {
            item.watchedAt = nil
        }
        save()
    }

    // MARK: - Private

    private func loadLists() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<CustomList>(
                sortBy: [SortDescriptor(\CustomList.createdAt, order: .forward)]
            )
            customLists = try context.fetch(descriptor)
        } catch { }
    }

    private func save() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch { }
    }

    // MARK: - Migration

    /// Custom lists used to insert their own `Movie`/`TVShow` row for every title, so a title in
    /// both the watchlist and a list had two rows and the list's copy never tracked watched state.
    /// Repoints every `CustomListItem` at the canonical row for its TMDB id and deletes what's left
    /// over. Runs once per install (and is a no-op if it somehow runs again).
    private func migrateDuplicateMediaRows() {
        guard let context = modelContext else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didMigrateKey) else { return }

        do {
            let items = try context.fetch(FetchDescriptor<CustomListItem>())
            guard !items.isEmpty else {
                defaults.set(true, forKey: Self.didMigrateKey)
                return
            }

            // The canonical row for an id is the one a `ListItem` refers to, else the first stored.
            var canonicalMovies: [String: Movie] = [:]
            for movie in try context.fetch(FetchDescriptor<Movie>()) {
                guard let current = canonicalMovies[movie.id] else {
                    canonicalMovies[movie.id] = movie
                    continue
                }
                if (current.listItems ?? []).isEmpty, !(movie.listItems ?? []).isEmpty {
                    canonicalMovies[movie.id] = movie
                }
            }
            var canonicalTVShows: [String: TVShow] = [:]
            for tvShow in try context.fetch(FetchDescriptor<TVShow>()) {
                guard let current = canonicalTVShows[tvShow.id] else {
                    canonicalTVShows[tvShow.id] = tvShow
                    continue
                }
                if (current.listItems ?? []).isEmpty, !(tvShow.listItems ?? []).isEmpty {
                    canonicalTVShows[tvShow.id] = tvShow
                }
            }

            // Repoint everything first — an orphan candidate may still back other list items.
            var orphanMovies: [Movie] = []
            var orphanTVShows: [TVShow] = []
            for item in items {
                if let movie = item.movie, let canonical = canonicalMovies[movie.id], canonical !== movie {
                    item.movie = canonical
                    orphanMovies.append(movie)
                }
                if let tvShow = item.tvShow, let canonical = canonicalTVShows[tvShow.id], canonical !== tvShow {
                    item.tvShow = canonical
                    orphanTVShows.append(tvShow)
                }
            }

            guard !orphanMovies.isEmpty || !orphanTVShows.isEmpty else {
                defaults.set(true, forKey: Self.didMigrateKey)
                return
            }

            for movie in orphanMovies {
                guard (movie.listItems ?? []).isEmpty, (movie.customListItems ?? []).isEmpty else { continue }
                deleteUnreferencedNetworks(movie.networks, excludingOwner: movie.persistentModelID, in: context)
                context.delete(movie)
            }
            for tvShow in orphanTVShows {
                guard (tvShow.listItems ?? []).isEmpty, (tvShow.customListItems ?? []).isEmpty else { continue }
                deleteUnreferencedNetworks(tvShow.networks, excludingOwner: tvShow.persistentModelID, in: context)
                context.delete(tvShow)
            }

            try context.save()
            defaults.set(true, forKey: Self.didMigrateKey)
        } catch {
            // Leave the flag unset so the next launch can retry; the pass is idempotent.
        }
    }
}
