// Core Data model for a plain media list (e.g., a watchlist), grouped under WatchListGroup for app-wide sharing.
import Foundation
import CoreData

@objc(MediaList)
final class MediaList: NSManagedObject {
    /// Name of the list (e.g., "Movies to Watch")
    @NSManaged var name: String

    /// The date the list was created
    @NSManaged var createdAtRaw: Date?

    /// Stable identity — when two devices each seeded a "TV Shows" list before syncing, the lowest
    /// id keeps the name and the other's items are folded into it (`mergeDuplicateLists`).
    @NSManaged var idRaw: UUID?

    /// The list items (TV shows/movies) in this list
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

    override func awakeFromInsert() {
        super.awakeFromInsert()
        if idRaw == nil {
            idRaw = UUID()
        }
    }

    var items: [ListItem]? {
        get { (itemSet as? Set<ListItem>).map(Array.init) }
        set { itemSet = newValue.map { NSSet(array: $0) } }
    }

    convenience init(
        name: String = "",
        createdAt: Date = Date.now,
        items: [ListItem]? = nil,
        group: WatchListGroup? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        // Join the group's context (and store) when one is given — see `inferredContext`.
        self.init(entity: managedEntity(named: "MediaList"), insertInto: inferredContext(context, relating: [group]))
        self.name = name
        self.createdAt = createdAt
        self.items = items
        self.group = group
        if context == nil { assignToStore(of: [group], self) }
    }
}
