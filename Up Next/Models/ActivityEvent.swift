import Foundation
import CoreData

/// One "someone did something" moment on the shared watchlist — an add, a removal, a watched
/// mark, a collection edit — written by `PersistenceController.recordActivity` in the same save as
/// the mutation it describes and hung off the share root so it syncs like everything else.
///
/// Events exist because removals can't be announced any other way: a deleted row has no CloudKit
/// record left to attribute. They're also the one source for partner notifications
/// (`RemoteActivityNotifier`) and the Settings → Activity screen. Who did it is deliberately *not*
/// stored as truth: the CloudKit record's `creatorUserRecordID` says that, and `actorName` is only
/// a display fallback for when iOS withholds the other person's name.
@objc(ActivityEvent)
final class ActivityEvent: NSManagedObject, Identifiable {
    enum Kind: String {
        case added
        case removed
        case watched
        case unwatched
        case collectionAdded
        case collectionRemoved
        case collectionCreated
        case collectionDeleted
        case collectionRenamed
    }

    @NSManaged var idRaw: UUID?
    @NSManaged var createdAtRaw: Date?
    @NSManaged var kindRaw: String?
    /// The title's name, or the collection's name for `collectionCreated/Deleted/Renamed`. Copied
    /// rather than related: the whole point is to outlive the row it describes.
    @NSManaged var title: String?
    /// `MediaIDKey` of the title, when there is one.
    @NSManaged var mediaKey: String?
    /// "TV Shows" / "Movies" for library adds and removals, the collection's name for collection
    /// edits and collection watched marks, nil for library watched marks.
    @NSManaged var contextName: String?
    /// The writer's own display name when iOS gave it one — a fallback for the reader, whose view
    /// of the other participant's name may be withheld.
    @NSManaged var actorName: String?
    /// The writer's CloudKit user record name (`CKContainer.userRecordID`), so "who" is a
    /// fetchable attribute — per-person filters and badges are a predicate, not a record lookup
    /// per row. The record's `creatorUserRecordID` remains the truth for "mine vs theirs".
    @NSManaged var actorRecordName: String?

    // MARK: - Inverse relationships for CloudKit
    @NSManaged var group: WatchListGroup?

    var id: UUID {
        get { idRaw ?? UUID() }
        set { idRaw = newValue }
    }

    /// When the edit happened on the writer's device — not when it synced here.
    var createdAt: Date {
        get { createdAtRaw ?? .distantPast }
        set { createdAtRaw = newValue }
    }

    /// Optional so a kind added by a newer build (synced to a device still on this one) reads as
    /// unknown instead of being phrased as something it isn't. The notifier skips those.
    var kind: Kind? {
        get { kindRaw.flatMap(Kind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        if idRaw == nil { idRaw = UUID() }
        if createdAtRaw == nil { createdAtRaw = .now }
    }

    convenience init(
        kind: Kind,
        title: String,
        mediaKey: String? = nil,
        contextName: String? = nil,
        actorName: String? = nil,
        actorRecordName: String? = nil,
        createdAt: Date = .now,
        group: WatchListGroup?,
        context: NSManagedObjectContext? = nil
    ) {
        // Joins the root's context and store up front — relate before save, see `inferredContext`.
        self.init(entity: managedEntity(named: "ActivityEvent"), insertInto: inferredContext(context, relating: [group]))
        if idRaw == nil { idRaw = UUID() }
        self.kind = kind
        self.title = title
        self.mediaKey = mediaKey
        self.contextName = contextName
        self.actorName = actorName
        self.actorRecordName = actorRecordName
        self.createdAt = createdAt
        self.group = group
        if context == nil { assignToStore(of: [group], self) }
    }

    /// The one phrasing of an event, shared by notifications/toasts and the Activity screen.
    /// Sentence case, titles unquoted. `actor` is "You", a display name, or "Someone".
    func sentence(actor: String) -> String {
        let title = self.title ?? "a title"
        // Library watched marks carry no context; a collection's carry its name.
        let inContext = contextName.map { " in \($0)" } ?? ""
        switch kind {
        case .added, .collectionAdded:
            guard let contextName else { return "\(actor) added \(title)" }
            return "\(actor) added \(title) to \(contextName)"
        case .removed, .collectionRemoved:
            guard let contextName else { return "\(actor) removed \(title)" }
            return "\(actor) removed \(title) from \(contextName)"
        case .watched:
            return "\(actor) marked \(title) watched\(inContext)"
        case .unwatched:
            return "\(actor) marked \(title) unwatched\(inContext)"
        case .collectionCreated:
            return "\(actor) created the collection \(title)"
        case .collectionDeleted:
            return "\(actor) deleted the collection \(title)"
        case .collectionRenamed:
            return "\(actor) renamed a collection to \(title)"
        case nil:
            return "\(actor) changed \(title)"
        }
    }
}
