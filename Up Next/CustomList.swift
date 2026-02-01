import Foundation
import SwiftData

@Model
final class CustomList {
    @Attribute(.unique) var id: UUID
    var name: String
    var iconName: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var items: [CustomListItem]

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "list.bullet",
        createdAt: Date = Date(),
        items: [CustomListItem] = []
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.createdAt = createdAt
        self.items = items
    }
}
