// SwiftData model for a plain media list (e.g., a watchlist), grouped under WatchListGroup for app-wide sharing.
import Foundation
import SwiftData

@Model
final class MediaList {
    /// Name of the list (e.g., "Movies to Watch")
    var name: String = ""

    /// The user who created the list
    var createdBy: UserIdentity?

    /// The date the list was created
    var createdAt: Date = Date()

    /// The list items (TV shows/movies) in this list
    @Relationship(deleteRule: .cascade, inverse: \ListItem.list) var items: [ListItem]?

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \WatchListGroup.lists) var group: WatchListGroup?

    init(name: String = "", createdBy: UserIdentity? = nil, createdAt: Date = Date(), items: [ListItem]? = nil) {
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.items = items
    }
}
