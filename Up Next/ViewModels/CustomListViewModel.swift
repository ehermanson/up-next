import Foundation
import CoreData

@MainActor
@Observable
final class CustomListViewModel {
    var customLists: [CustomList] = []
    var activeListID: UUID?

    /// Bumped on every mutation. Views derive their rows from `visibleItems(in:)` /
    /// `containsItem(mediaID:mediaType:in:)`, which read this — a child `CustomListItem` changing its
    /// `watchedAt` doesn't republish the parent `CustomList`, so without it a toggled row would
    /// update its badge but never move between the Unwatched / Watched sections.
    private(set) var changeToken = 0

    private var persistence: PersistenceController?

    /// An item removed from a list's visible contents but not yet deleted from the store, so it can
    /// be restored via `undoLastRemoval()`. Mirrors the watchlist's deferred swipe-delete. The
    /// relationship to `list` is left untouched during the pending window — `visibleItems(in:)` is
    /// what hides it from the UI — so an undo is just clearing `pendingRemoval` (the defensive
    /// re-attach below covers the case where something else nulled it in the meantime, e.g. a
    /// remote merge).
    private struct PendingRemoval {
        let item: CustomListItem
        let list: CustomList
    }
    private var pendingRemoval: PendingRemoval?
    private var pendingRemovalCommit: Task<Void, Never>?

    // `PersistenceController.shared` is main-actor isolated, so it can't be a default argument on a
    // nonisolated declaration — resolved inside instead, leaving `configure()` call sites unchanged.
    func configure(persistence: PersistenceController? = nil) {
        guard self.persistence == nil else { return }
        self.persistence = persistence ?? .shared
        loadLists()
    }

    /// Re-fetches `customLists` from the store — called by `ContentView` when
    /// `PersistenceController.remoteChangeCount` changes (a remote peer's edit landed), and when a
    /// share is joined or left, which purges a whole store out from under these objects.
    func reloadFromStore() {
        guard let persistence else { return }
        guard persistence.group != nil else {
            // Joining or leaving a share: every collection this view model held was purged, so the
            // deferred removal has nothing left to commit either.
            pendingRemovalCommit?.cancel()
            pendingRemovalCommit = nil
            pendingRemoval = nil
            customLists = []
            changeToken += 1
            return
        }
        loadLists()
        changeToken += 1
    }

    func createList(name: String) {
        // No root while a join is still importing: a list created now would be an orphan in the
        // active store, unreachable from the share and invisible to the partner. `ContentView`
        // shows the joining placeholder instead of the tabs in that state, so this is only a guard.
        guard let persistence, persistence.group != nil else { return }
        // `group:` is passed into the init (rather than assigned after a context-less init) so the
        // list joins the group's context/store up front — relating a context-less object to a
        // stored one raises a Core Data exception. `persistence.insert` is a harmless no-op when
        // that succeeded.
        let list = CustomList(name: name, group: persistence.group)
        persistence.insert(list)
        persistence.recordActivity(.collectionCreated, title: name)
        persistence.save()
        customLists.append(list)
        changeToken += 1
    }

    func deleteList(_ list: CustomList) {
        guard let persistence else { return }
        // A deferred removal from this list can't outlive it.
        commitPendingRemoval()
        customLists.removeAll { $0 === list }
        let context = persistence.viewContext
        // The cascade takes the `CustomListItem`s, but not the `Movie` / `TVShow` (and `Network`)
        // rows they were the last referrer of — those would leak, and keep their CloudKit records.
        for item in list.items ?? [] {
            let movie = item.movie
            let tvShow = item.tvShow
            let itemID = item.objectID
            context.delete(item)
            deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: context)
        }
        persistence.recordActivity(.collectionDeleted, title: list.name)
        context.delete(list)
        persistence.save()
        changeToken += 1
    }

    func renameList(_ list: CustomList, to name: String) {
        guard list.name != name else { return }
        persistence?.recordActivity(.collectionRenamed, title: name)
        list.name = name
        persistence?.save()
        changeToken += 1
    }

    /// Adds a title to a list. `movie`/`tvShow` may be a freshly-mapped TMDB instance — when the
    /// title already has a stored row (in the library or another list) that row is reused and
    /// refreshed instead, so a title never ends up with two media rows.
    func addItem(movie: Movie? = nil, tvShow: TVShow? = nil, to list: CustomList) {
        guard let persistence else { return }
        let mediaID = movie?.id ?? tvShow?.id
        guard let mediaID else { return }
        // Re-adding something awaiting removal would leave a duplicate behind on Undo.
        commitPendingRemoval(ifTargeting: mediaID, mediaType: movie != nil ? .movie : .tvShow, in: list)
        // Movie and TV IDs are separate TMDB namespaces; a mixed collection may contain both.
        guard !visibleItems(in: list).contains(where: { item in
            movie != nil ? item.movie?.id == mediaID : item.tvShow?.id == mediaID
        }) else { return }

        let context = persistence.viewContext
        let canonicalMovie = movie.map { canonicalMovieRow(for: $0, in: context) }
        let canonicalTVShow = tvShow.map { canonicalTVShowRow(for: $0, in: context) }
        // Setting `customList` on the item maintains `list.itemSet` via the Core Data inverse —
        // don't also append to `list.items`, that would double up the bookkeeping. The init joins
        // `list`'s context automatically; `persistence.insert` is a harmless no-op once that's done.
        let item = CustomListItem(movie: canonicalMovie, tvShow: canonicalTVShow, customList: list, addedAt: .now)
        persistence.insert(item)
        if let media = item.media {
            persistence.recordActivity(.collectionAdded, title: media.title, mediaKey: item.mediaKey, contextName: list.name)
        }
        persistence.save()
        changeToken += 1
    }

    /// Removes an item from the list's visible contents immediately but defers the Core Data delete
    /// briefly so it can be undone via `undoLastRemoval()`. Returns the removed item's title (for
    /// the toast), or nil if nothing was removed.
    @discardableResult
    func removeItem(_ item: CustomListItem, from list: CustomList) -> String? {
        // Any previously-pending removal is now final (superseded by this one).
        commitPendingRemoval()
        guard persistence != nil else { return nil }
        guard (list.items ?? []).contains(where: { $0 === item }) else { return nil }

        let title = item.media?.title
        pendingRemoval = PendingRemoval(item: item, list: list)
        changeToken += 1

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
        // A remote merge (or a store purge) can delete either side inside the undo window; there's
        // nothing to restore then, but the rows still have to re-derive.
        guard pending.item.managedObjectContext != nil, !pending.item.isDeleted,
              pending.list.managedObjectContext != nil, !pending.list.isDeleted
        else {
            changeToken += 1
            return
        }
        // Defensive re-attach — the relationship is never actually broken during the pending
        // window (only `visibleItems(in:)` hides it), but this keeps undo correct even if
        // something else (a remote merge) touched it in the meantime.
        pending.item.customList = pending.list
        changeToken += 1
    }

    /// Finalizes a pending removal by deleting it from the store. No-op if nothing is pending.
    /// Also called when the app backgrounds, so a deferred delete can't resurrect on relaunch.
    func commitPendingRemoval() {
        pendingRemovalCommit?.cancel()
        pendingRemovalCommit = nil
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        guard let persistence else { return }
        // Already gone (a remote merge deleted it, or its store was purged) — deleting it again
        // would fault on a dead object.
        guard pending.item.managedObjectContext != nil, !pending.item.isDeleted else {
            changeToken += 1
            return
        }
        let context = persistence.viewContext
        let movie = pending.item.movie
        let tvShow = pending.item.tvShow
        let itemID = pending.item.objectID
        // Logged at commit, not in `removeItem`, so an undone removal leaves no trace. Read before
        // the delete — the media row may go with it.
        if let media = pending.item.media, pending.list.managedObjectContext != nil, !pending.list.isDeleted {
            persistence.recordActivity(
                .collectionRemoved,
                title: media.title,
                mediaKey: pending.item.mediaKey,
                contextName: pending.list.name
            )
        }
        context.delete(pending.item)
        deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: context)
        persistence.save()
        changeToken += 1
    }

    /// Commits a pending removal only when it targets the same title in the same list; adding
    /// anything *else* must leave the Undo window intact.
    private func commitPendingRemoval(ifTargeting mediaID: String, mediaType: MediaType, in list: CustomList) {
        guard let pending = pendingRemoval,
              pending.list === list,
              (mediaType == .movie ? pending.item.movie?.id : pending.item.tvShow?.id) == mediaID
        else { return }
        commitPendingRemoval()
    }

    /// `list.items` minus anything mid-removal in the undo window. Views should read this instead
    /// of `list.items` directly so a swiped-away row disappears immediately without the relationship
    /// actually being broken until the removal commits.
    func visibleItems(in list: CustomList) -> [CustomListItem] {
        // Read (not used) so any view body calling this re-renders on the next mutation.
        _ = changeToken
        let all = list.items ?? []
        guard let pending = pendingRemoval, pending.list === list else { return all }
        return all.filter { $0 !== pending.item }
    }

    func item(mediaID: String, mediaType: MediaType, in list: CustomList) -> CustomListItem? {
        visibleItems(in: list).first {
            (mediaType == .movie ? $0.movie?.id : $0.tvShow?.id) == mediaID
        }
    }

    func containsItem(mediaID: String, mediaType: MediaType, in list: CustomList) -> Bool {
        item(mediaID: mediaID, mediaType: mediaType, in: list) != nil
    }

    // MARK: - Watched state

    /// Flips a collection entry's own watched state. Collections track this independently — the
    /// Movies / TV Shows tabs are never created, read or modified from here.
    func toggleWatched(_ item: CustomListItem) {
        item.toggleWatched()
        if let media = item.media {
            persistence?.recordActivity(
                item.isWatched ? .watched : .unwatched,
                title: media.title,
                mediaKey: item.mediaKey,
                contextName: item.customList?.name
            )
        }
        persistence?.save()
        changeToken += 1
    }

    /// Clears the watched stamp on every entry in a collection — the "start the season over" reset.
    func markAllUnwatched(in list: CustomList) {
        for item in visibleItems(in: list) {
            item.watchedAt = nil
        }
        persistence?.save()
        changeToken += 1
    }

    // MARK: - Private

    private func loadLists() {
        guard let persistence else { return }
        // Joining state: the shared library hasn't arrived yet, so there's nothing to show.
        guard persistence.group != nil else {
            customLists = []
            return
        }
        let request = NSFetchRequest<CustomList>(entityName: "CustomList")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAtRaw", ascending: true)]
        customLists = persistence.fetch(request)
    }
}
