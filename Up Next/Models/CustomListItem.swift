import Foundation
import SwiftData

@Model
final class CustomListItem {
    var movie: Movie?
    var tvShow: TVShow?
    var customList: CustomList?
    var addedAt: Date = Date.now

    /// When this title was marked watched *inside this collection*. Collections are seasonal /
    /// thematic pools, so their watched state is their own — it never reads or writes the
    /// library's `ListItem`s (the Movies / TV Shows tabs). Optional + defaulted for CloudKit.
    var watchedAt: Date?

    var isWatched: Bool { watchedAt != nil }

    var media: (any MediaItemProtocol)? {
        movie ?? tvShow
    }

    init(
        movie: Movie? = nil,
        tvShow: TVShow? = nil,
        customList: CustomList? = nil,
        addedAt: Date = Date.now,
        watchedAt: Date? = nil
    ) {
        self.movie = movie
        self.tvShow = tvShow
        self.customList = customList
        self.addedAt = addedAt
        self.watchedAt = watchedAt
    }

    /// Flips this collection entry's watched state. Nothing outside the collection changes.
    func toggleWatched() {
        watchedAt = isWatched ? nil : Date.now
    }
}
