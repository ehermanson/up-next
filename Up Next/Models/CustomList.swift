import Foundation
import CoreData

@objc(CustomList)
final class CustomList: NSManagedObject, Identifiable {
    @NSManaged var idRaw: UUID?
    @NSManaged var name: String
    // The model still carries `iconName` (defaulted, unread): collections are identified by their
    // poster mosaic now, and dropping a shipped attribute would need a model version for nothing.
    @NSManaged var createdAtRaw: Date?
    @NSManaged var itemSet: NSSet?

    // MARK: - Inverse relationships for CloudKit
    @NSManaged var group: WatchListGroup?

    var id: UUID {
        get { idRaw ?? UUID() }
        set { idRaw = newValue }
    }

    var createdAt: Date {
        get { createdAtRaw ?? .distantPast }
        set { createdAtRaw = newValue }
    }

    var items: [CustomListItem]? {
        get { (itemSet as? Set<CustomListItem>).map(Array.init) }
        set { itemSet = newValue.map { NSSet(array: $0) } }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        if idRaw == nil {
            idRaw = UUID()
        }
    }

    convenience init(
        id: UUID = UUID(),
        name: String = "",
        createdAt: Date = Date.now,
        items: [CustomListItem]? = nil,
        group: WatchListGroup? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        // Pass `group:` here rather than setting it after a context-less init — relating a
        // context-less object to a stored one is a Core Data exception. See `inferredContext`.
        self.init(entity: managedEntity(named: "CustomList"), insertInto: inferredContext(context, relating: [group]))
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.items = items
        self.group = group
        if context == nil { assignToStore(of: [group], self) }
    }
}
