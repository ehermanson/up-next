import Foundation
import SwiftData

@Model
final class CustomList {
    var id: UUID = UUID()
    var name: String = ""
    var iconName: String = "list.bullet"
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \CustomListItem.customList) var items: [CustomListItem]?

    init(
        id: UUID = UUID(),
        name: String = "",
        iconName: String = "list.bullet",
        createdAt: Date = Date(),
        items: [CustomListItem]? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.createdAt = createdAt
        self.items = items
    }
}
