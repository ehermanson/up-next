// SwiftData model representing the global collaborative watch-list space.
// This is the root object for iCloud sharing and contains all MediaLists and app-wide members.
import Foundation
import SwiftData

@Model
final class WatchListGroup {
    /// The users who have access to this watch-list space (app-wide sharing)
    @Relationship(deleteRule: .nullify) var members: [UserIdentity]?

    /// All media lists (e.g., TV and Movie lists) in this group
    @Relationship(deleteRule: .cascade) var lists: [MediaList]?

    init(members: [UserIdentity]? = nil, lists: [MediaList]? = nil) {
        self.members = members
        self.lists = lists
    }
}
