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
    var addedAt: Date = Date()

    /// Whether the item has been marked as watched
    var isWatched: Bool = false

    /// The date when the item was marked as watched (nil if not watched)
    var watchedAt: Date?

    /// The order of this item within the media list for sorting purposes
    var order: Int = 0

    /// Which seasons the user has watched (1-based season numbers)
    var watchedSeasons: [Int] = []

    /// Personal rating: 1 = thumbs up, 0 = meh, -1 = thumbs down, nil = not rated
    var userRating: Int?

    /// Free-text personal notes
    var userNotes: String?

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
        addedAt: Date = Date(),
        isWatched: Bool = false,
        watchedAt: Date? = nil,
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
        self.order = order
        self.watchedSeasons = watchedSeasons
        self.userRating = userRating
        self.userNotes = userNotes
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
        list: MediaList? = nil,
        addedBy: UserIdentity? = nil,
        addedAt: Date = Date(),
        isWatched: Bool = false,
        watchedAt: Date? = nil,
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
        addedAt: Date = Date(),
        isWatched: Bool = false,
        watchedAt: Date? = nil,
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
            order: order,
            watchedSeasons: watchedSeasons,
            userRating: userRating,
            userNotes: userNotes
        )
    }
}
