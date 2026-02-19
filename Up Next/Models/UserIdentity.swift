// SwiftData model representing a user's identity for attribution and sharing
import Foundation
import SwiftData

@Model
final class UserIdentity {
    /// The user's iCloud identifier (CKRecordID or similar, as String)
    var id: String = ""

    /// User display name
    var displayName: String = ""

    // MARK: - Inverse relationships for CloudKit
    @Relationship(inverse: \MediaList.createdBy) var createdLists: [MediaList]?
    @Relationship(inverse: \ListItem.addedBy) var addedItems: [ListItem]?
    @Relationship(inverse: \WatchListGroup.members) var memberOfGroups: [WatchListGroup]?

    init(id: String = "", displayName: String = "") {
        self.id = id
        self.displayName = displayName
    }
}
