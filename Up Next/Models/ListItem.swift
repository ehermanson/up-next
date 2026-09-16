// Create a SwiftData model for a basic list item in a watchlist app
// This model references a media item and its parent list, tracks attribution for history only (not for list membership or sharing),
// watch state, and order

import Foundation
import SwiftData

@Model
final class ListItem {
    /// The movie referenced by this list item (if applicable)
    var movie: Movie?

    /// The TV show referenced by this list item (if applicable)
    var tvShow: TVShow?

    /// The parent media list that contains this list item
    var list: MediaList?

    /// The user who added this item to the list (used for history only, not for list membership or sharing)
    var addedBy: UserIdentity?

    /// The date when this item was added to the list
    var addedAt: Date = Date.now

    /// Whether the item has been marked as watched
    var isWatched: Bool = false

    /// The date when the item was marked as watched (nil if not watched)
    var watchedAt: Date?

    /// The date when a TV show was marked as "done watching" before all seasons were complete (nil if not dropped)
    var droppedAt: Date?

    /// The order of this item within the media list for sorting purposes
    var order: Int = 0

    /// Which seasons the user has watched (1-based season numbers)
    var watchedSeasons: [Int] = []

    /// Personal rating: 1 = thumbs up, 0 = meh, -1 = thumbs down, nil = not rated
    var userRating: Int?

    /// Free-text personal notes
    var userNotes: String?

    /// Whether the show has been dropped (done watching before all seasons complete)
    var isDropped: Bool { droppedAt != nil }

    /// Computed property to access the media item as a protocol type
    var media: (any MediaItemProtocol)? {
        if let movie = movie {
            return movie
        } else if let tvShow = tvShow {
            return tvShow
        }
        return nil
    }

    init(
        movie: Movie? = nil,
        tvShow: TVShow? = nil,
        list: MediaList? = nil,
        addedBy: UserIdentity? = nil,
        addedAt: Date = Date.now,
        isWatched: Bool = false,
        watchedAt: Date? = nil,
        droppedAt: Date? = nil,
        order: Int = 0,
        watchedSeasons: [Int] = [],
        userRating: Int? = nil,
        userNotes: String? = nil
    ) {
        self.movie = movie
        self.tvShow = tvShow
        self.list = list
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.isWatched = isWatched
        self.watchedAt = watchedAt
        self.droppedAt = droppedAt
        self.order = order
        self.watchedSeasons = watchedSeasons
        self.userRating = userRating
        self.userNotes = userNotes
    }

    /// The next season number the user should watch, or nil if all watched / no season data.
    /// Only counts seasons that have actually started airing — an announced season is nothing to
    /// watch next (see `TVShow.availableSeasonCount`).
    var nextSeasonToWatch: Int? {
        guard let tvShow = tvShow else { return nil }
        let available = tvShow.availableSeasonCount
        guard available > 0 else { return nil }
        for season in 1...available {
            if !watchedSeasons.contains(season) {
                return season
            }
        }
        return nil
    }

    /// Syncs `isWatched` / `watchedAt` based on whether every *available* season is in
    /// `watchedSeasons` — a caught-up show whose next season is only announced stays watched, and
    /// drops back into Up Next by itself once that season starts airing (a refresh re-runs this).
    /// No-op for movies or shows without `numberOfSeasons`.
    func syncWatchedStateFromSeasons() {
        guard droppedAt == nil else { return }
        guard let tvShow = tvShow, let total = tvShow.numberOfSeasons, total > 0 else { return }
        // Watched with no season marks means the whole show was marked before TMDB's season data
        // arrived (or by an older version). That's a statement about every season, so record it
        // rather than letting the derivation below un-watch the show on the next refresh.
        if isWatched, watchedSeasons.isEmpty {
            watchedSeasons = Array(1...total)
            return
        }
        // With nothing aired yet there's nothing to be caught up on, so only an explicit season
        // mark keeps such an item watched.
        let available = tvShow.availableSeasonCount
        let allWatched = !watchedSeasons.isEmpty
            && (available == 0 || (1...available).allSatisfy { watchedSeasons.contains($0) })
        if allWatched {
            if !isWatched {
                isWatched = true
                watchedAt = Date.now
            }
        } else {
            isWatched = false
            watchedAt = nil
        }
    }

    /// Toggles a season, cascading to the seasons around it: people watch shows in order, so
    /// marking season N watched also marks 1...N (any later seasons already watched stay watched),
    /// and un-marking season N un-marks N...last. Without the cascade, tapping S5 on a fresh show
    /// would leave `nextSeasonToWatch` pointing at S1.
    /// No-op for movies or shows without `numberOfSeasons`.
    func toggleSeason(_ season: Int) {
        guard season >= 1, let tvShow = tvShow, let total = tvShow.numberOfSeasons, total > 0 else { return }

        var watched = Set(watchedSeasons)
        if watched.contains(season) {
            watched = watched.filter { $0 < season }
        } else {
            watched.formUnion(1...season)
        }
        watchedSeasons = watched.sorted()

        // If all seasons are now watched while dropped, clear the drop (legitimately complete)
        if isDropped, (1...total).allSatisfy({ watched.contains($0) }) {
            droppedAt = nil
        }
        syncWatchedStateFromSeasons()
    }

    /// Flips watched state the way the list's swipe action does: a dropped show resumes instead of
    /// un-watching, and TV shows mark/unmark every season so `nextSeasonToWatch` stays coherent.
    func toggleWatched() {
        if isDropped && isWatched {
            resumeShow()
            return
        }
        isWatched.toggle()
        watchedAt = isWatched ? Date.now : nil
        if let tvShow, let total = tvShow.numberOfSeasons, total > 0 {
            watchedSeasons = isWatched ? Array(1...total) : []
        }
    }

    /// Marks the show as "done watching" — appears in Watched regardless of season completion.
    func dropShow() {
        let now = Date.now
        droppedAt = now
        isWatched = true
        watchedAt = now
    }

    /// Resumes a dropped show — clears the drop override and re-derives watched state from seasons.
    func resumeShow() {
        droppedAt = nil
        syncWatchedStateFromSeasons()
    }

    /// Convenience initializer for creating a ListItem with a Movie
    convenience init(
        movie: Movie,
        list: MediaList? = nil,
        addedBy: UserIdentity? = nil,
        addedAt: Date = Date.now,
        isWatched: Bool = false,
        watchedAt: Date? = nil,
        droppedAt: Date? = nil,
        order: Int = 0,
        watchedSeasons: [Int] = [],
        userRating: Int? = nil,
        userNotes: String? = nil
    ) {
        self.init(
            movie: movie,
            tvShow: nil,
            list: list,
            addedBy: addedBy,
            addedAt: addedAt,
            isWatched: isWatched,
            watchedAt: watchedAt,
            droppedAt: droppedAt,
            order: order,
            watchedSeasons: watchedSeasons,
            userRating: userRating,
            userNotes: userNotes
        )
    }

    /// Convenience initializer for creating a ListItem with a TVShow
    convenience init(
        tvShow: TVShow,
        list: MediaList? = nil,
        addedBy: UserIdentity? = nil,
        addedAt: Date = Date.now,
        isWatched: Bool = false,
        watchedAt: Date? = nil,
        droppedAt: Date? = nil,
        order: Int = 0,
        watchedSeasons: [Int] = [],
        userRating: Int? = nil,
        userNotes: String? = nil
    ) {
        self.init(
            movie: nil,
            tvShow: tvShow,
            list: list,
            addedBy: addedBy,
            addedAt: addedAt,
            isWatched: isWatched,
            watchedAt: watchedAt,
            droppedAt: droppedAt,
            order: order,
            watchedSeasons: watchedSeasons,
            userRating: userRating,
            userNotes: userNotes
        )
    }
}
