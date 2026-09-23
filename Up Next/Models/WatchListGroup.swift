// Core Data model representing the global collaborative watch-list space.
// This is the root object for iCloud sharing and contains all MediaLists and CustomLists.
import Foundation
import CoreData

@objc(WatchListGroup)
final class WatchListGroup: NSManagedObject {
    /// The date the group was created
    @NSManaged var createdAtRaw: Date?

    /// Stable identity used to pick a deterministic winner when two devices on one account each
    /// seeded a root before the other's synced down (`PersistenceController.reconciledRoot`).
    @NSManaged var idRaw: UUID?

    /// All media lists (e.g., TV and Movie lists) in this group
    @NSManaged var listSet: NSSet?

    /// All custom lists (collections) in this group
    @NSManaged var customListSet: NSSet?

    /// The shared activity log (`ActivityEvent`) — on the root so it syncs to both people.
    @NSManaged var activitySet: NSSet?

    /// Household streaming services (TMDB provider ids), shared with the partner like everything
    /// else on the root. `nil` = never set (pre-2.0-services owner, fresh root); `[]` = none.
    @NSManaged var selectedProviderIDsRaw: [Int]?

    /// Sorted on write so the stored value — and the CloudKit record it mirrors into — is
    /// deterministic regardless of `Set` iteration order.
    var selectedProviderIDs: Set<Int>? {
        get { selectedProviderIDsRaw.map(Set.init) }
        set { selectedProviderIDsRaw = newValue.map { $0.sorted() } }
    }

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

    var lists: [MediaList]? {
        get { (listSet as? Set<MediaList>).map(Array.init) }
        set { listSet = newValue.map { NSSet(array: $0) } }
    }

    var customLists: [CustomList]? {
        get { (customListSet as? Set<CustomList>).map(Array.init) }
        set { customListSet = newValue.map { NSSet(array: $0) } }
    }

    var activities: [ActivityEvent]? {
        get { (activitySet as? Set<ActivityEvent>).map(Array.init) }
        set { activitySet = newValue.map { NSSet(array: $0) } }
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
