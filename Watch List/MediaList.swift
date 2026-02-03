// SwiftData model for a plain media list (e.g., a watchlist), grouped under WatchListGroup for app-wide sharing.
import Foundation
import SwiftData

@Model
final class MediaList {
    /// Name of the list (e.g., "Movies to Watch")
    var name: String

    /// The user who created the list
    var createdBy: UserIdentity

    /// The date the list was created
    var createdAt: Date

    /// The list items (TV shows/movies) in this list
    @Relationship(deleteRule: .cascade) var items: [ListItem]

    init(name: String, createdBy: UserIdentity, createdAt: Date, items: [ListItem] = []) {
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.items = items
    }
}
