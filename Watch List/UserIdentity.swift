// SwiftData model representing a user's identity for attribution and sharing
import Foundation
import SwiftData

@Model
final class UserIdentity {
    /// The user's iCloud identifier (CKRecordID or similar, as String)
    @Attribute(.unique) var id: String

    /// User display name
    var displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
