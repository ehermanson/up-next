// Core Data model representing the global collaborative watch-list space.
// This is the root object for iCloud sharing and contains all MediaLists and CustomLists.
import Foundation
import CoreData

@objc(WatchListGroup)
final class WatchListGroup: NSManagedObject {
    /// The date the group was created
    @NSManaged var createdAtRaw: Date?

    /// All media lists (e.g., TV and Movie lists) in this group
    @NSManaged var listSet: NSSet?

    /// All custom lists (collections) in this group
    @NSManaged var customListSet: NSSet?

    var createdAt: Date {
        get { createdAtRaw ?? .distantPast }
        set { createdAtRaw = newValue }
    }

    var lists: [MediaList]? {
        get { (listSet as? Set<MediaList>).map(Array.init) }
        set { listSet = newValue.map { NSSet(array: $0) } }
    }

    var customLists: [CustomList]? {
        get { (customListSet as? Set<CustomList>).map(Array.init) }
        set { customListSet = newValue.map { NSSet(array: $0) } }
    }

    convenience init(
        createdAt: Date = Date.now,
        lists: [MediaList]? = nil,
        customLists: [CustomList]? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        self.init(entity: managedEntity(named: "WatchListGroup"), insertInto: context)
        self.createdAt = createdAt
        self.lists = lists
        self.customLists = customLists
    }
}
