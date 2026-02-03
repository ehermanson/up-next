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
    /// Note: This is consistent with the WatchListGroup root structure.
    var list: MediaList

    /// The user who added this item to the list (used for history only, not for list membership or sharing)
    var addedBy: UserIdentity

    /// The date when this item was added to the list
    var addedAt: Date

    /// Whether the item has been marked as watched
    var isWatched: Bool

    /// The date when the item was marked as watched (nil if not watched)
    var watchedAt: Date?

    /// The order of this item within the media list for sorting purposes
    var order: Int

    /// Which seasons the user has watched (1-based season numbers)
    var watchedSeasons: [Int] = []

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
        list: MediaList,
        addedBy: UserIdentity,
        addedAt: Date,
        isWatched: Bool,
        watchedAt: Date?,
        order: Int,
        watchedSeasons: [Int] = []
    ) {
        // Ensure exactly one media type is provided
        assert((movie != nil) != (tvShow != nil), "ListItem must have exactly one of movie or tvShow")

        self.movie = movie
        self.tvShow = tvShow
        self.list = list
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.isWatched = isWatched
        self.watchedAt = watchedAt
        self.order = order
        self.watchedSeasons = watchedSeasons
    }

    /// The next season number the user should watch, or nil if all watched / no season data
    var nextSeasonToWatch: Int? {
        guard let tvShow = tvShow, let total = tvShow.numberOfSeasons, total > 0 else { return nil }
        for season in 1...total {
            if !watchedSeasons.contains(season) {
                return season
            }
        }
        return nil
    }

    /// Syncs `isWatched` / `watchedAt` based on whether all seasons are in `watchedSeasons`.
    /// No-op for movies or shows without `numberOfSeasons`.
    func syncWatchedStateFromSeasons() {
        guard let tvShow = tvShow, let total = tvShow.numberOfSeasons, total > 0 else { return }
        let allWatched = (1...total).allSatisfy { watchedSeasons.contains($0) }
        if allWatched {
            if !isWatched {
                isWatched = true
                watchedAt = Date()
            }
        } else {
            isWatched = false
            watchedAt = nil
        }
    }

    /// Convenience initializer for creating a ListItem with a Movie
    convenience init(
        movie: Movie,
        list: MediaList,
        addedBy: UserIdentity,
        addedAt: Date,
        isWatched: Bool,
        watchedAt: Date?,
        order: Int,
        watchedSeasons: [Int] = []
    ) {
        self.init(
            movie: movie,
            tvShow: nil,
            list: list,
            addedBy: addedBy,
            addedAt: addedAt,
            isWatched: isWatched,
            watchedAt: watchedAt,
            order: order,
            watchedSeasons: watchedSeasons
        )
    }

    /// Convenience initializer for creating a ListItem with a TVShow
    convenience init(
        tvShow: TVShow,
        list: MediaList,
        addedBy: UserIdentity,
        addedAt: Date,
        isWatched: Bool,
        watchedAt: Date?,
        order: Int,
        watchedSeasons: [Int] = []
    ) {
        self.init(
            movie: nil,
            tvShow: tvShow,
            list: list,
            addedBy: addedBy,
            addedAt: addedAt,
            isWatched: isWatched,
            watchedAt: watchedAt,
            order: order,
            watchedSeasons: watchedSeasons
        )
    }
}
