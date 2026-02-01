import Foundation
import SwiftData

@Model
final class CustomListItem {
    var movie: Movie?
    var tvShow: TVShow?
    var customList: CustomList?
    var addedAt: Date

    var media: (any MediaItemProtocol)? {
        movie ?? tvShow
    }

    init(
        movie: Movie? = nil,
        tvShow: TVShow? = nil,
        customList: CustomList? = nil,
        addedAt: Date = Date()
    ) {
        self.movie = movie
        self.tvShow = tvShow
        self.customList = customList
        self.addedAt = addedAt
    }
}
