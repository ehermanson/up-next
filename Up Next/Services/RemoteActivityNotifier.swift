import CloudKit
import CoreData
import UIKit
import UserNotifications

/// Turns the partner's edits — which arrive as CloudKit imports and are recorded in persistent
/// history — into something the other person actually sees: a local notification while the app
/// is in the background, a toast (via `PersistenceController.recentRemoteActivity`) while it's on
/// screen. Nothing here talks to a server; the silent CloudKit push that triggers the import is
/// what wakes the app.
///
/// Attribution uses the CloudKit record's `lastModifiedUserRecordID`: the current account is
/// always `CKCurrentUserDefaultName`, so an edit from the user's *own* iPad is skipped and only
/// the partner's changes are announced. Deletions carry no record any more and can't be
/// attributed, so they're not announced.
@MainActor
enum RemoteActivityNotifier {
    /// Above this many distinct changes in one batch, one summary line replaces the list.
    private static let detailLimit = 3
    /// History older than this (app was closed for a while) is merged silently.
    private static let staleAfter: TimeInterval = 10 * 60
    /// A join's first import arrives as one bulk transaction, but the `isJoiningSharedLibrary`
    /// flag clears on the very first one — the rest of the same import would otherwise read as
    /// "Sarah made 200 changes". Stay quiet for a moment after the library lands.
    private static let quietAfterJoin: TimeInterval = 60
    /// Entities whose changes are never announced: a metadata refresh rewrites every media row,
    /// and the only thing that ever dirties the root is the household's streaming services, which
    /// has no phrased message. Checked before the (comparatively expensive) record lookup.
    private static let ignoredEntities: Set<String> = ["Movie", "TVShow", "Network", "WatchListGroup"]

    /// Asks for notification permission once sharing is actually in use. Safe to call repeatedly —
    /// the system only prompts the first time.
    static func requestPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Announces the partner's changes in `transactions` (already merged into the view context).
    static func announce(
        _ transactions: [NSPersistentHistoryTransaction],
        persistence: PersistenceController
    ) {
        // The first import after joining is the whole library landing — not "N changes".
        guard !persistence.isJoiningSharedLibrary else { return }
        if let joinedAt = persistence.joinCompletedAt,
           Date.now.timeIntervalSince(joinedAt) < quietAfterJoin {
            return
        }
        // Only meaningful once there's someone on the other end.
        guard persistence.role == .participant || persistence.existingShare() != nil else { return }

        let actor = persistence.otherPersonDisplayName()
        let isActive = UIApplication.shared.applicationState == .active
        var messages: [String] = []
        for transaction in transactions {
            for change in transaction.changes ?? [] {
                guard let activity = activity(for: change, actor: actor, persistence: persistence),
                      !messages.contains(activity.message)
                else { continue }
                // Only announce edits the partner actually made recently. History timestamps say
                // when the import ran, not when the edit happened, so the record's own
                // modification date is the one that matters — a day-old edit that only synced
                // now shouldn't buzz the phone, and on a reinstall the first history fetch
                // returns everything the account ever did.
                if Date.now.timeIntervalSince(activity.modifiedAt) > staleAfter { continue }
                messages.append(activity.message)
            }
        }
        guard !messages.isEmpty else { return }

        let lines: [String]
        if messages.count > detailLimit {
            lines = ["\(actor) made \(messages.count) changes to your shared watchlist"]
        } else {
            lines = messages
        }

        if isActive {
            persistence.recentRemoteActivity = lines
            return
        }

        for line in lines {
            let content = UNMutableNotificationContent()
            content.title = "Up Next"
            content.body = line
            content.sound = .default
            content.threadIdentifier = "shared-library"
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Messages

    private struct Activity {
        let message: String
        /// When the partner actually made the edit (the CloudKit record's modification date).
        let modifiedAt: Date
    }

    private static func activity(
        for change: NSPersistentHistoryChange,
        actor: String,
        persistence: PersistenceController
    ) -> Activity? {
        let objectID = change.changedObjectID
        guard change.changeType != .delete else { return nil }
        // Cheap rejections first: `container.record(for:)` is a store round-trip, and a metadata
        // refresh dirties every `Movie`/`TVShow`/`Network` row in the library.
        guard let entityName = objectID.entity.name, !ignoredEntities.contains(entityName) else { return nil }
        guard let object = try? persistence.viewContext.existingObject(with: objectID),
              !object.isDeleted,
              let message = message(for: change, object: object, actor: actor),
              let record = recordModifiedBySomeoneElse(objectID, persistence: persistence)
        else { return nil }
        return Activity(message: message, modifiedAt: record.modificationDate ?? .now)
    }

    private static func message(
        for change: NSPersistentHistoryChange,
        object: NSManagedObject,
        actor: String
    ) -> String? {
        let updated = Set((change.updatedProperties ?? []).map(\.name))

        switch object {
        case let item as ListItem:
            // `list == nil` is a detail-sheet wrapper (see `CustomListItemDetailSheet`), which a
            // background save can briefly sync — it's not a title anyone added.
            guard let list = item.list, let title = item.media?.title else { return nil }
            if change.changeType == .insert {
                return list.name.isEmpty
                    ? "\(actor) added \(title)"
                    : "\(actor) added \(title) to \(list.name)"
            }
            // `dropShow()` / `resumeShow()` also touch the watched fields, so the drop check
            // has to come first or a drop reads as "watched".
            if updated.contains("droppedAt") {
                return item.isDropped
                    ? "\(actor) stopped watching \(title)"
                    : "\(actor) picked \(title) back up"
            }
            if updated.contains("watchingStartedAt") {
                return item.isWatching
                    ? "\(actor) started watching \(title)"
                    : "\(actor) moved \(title) to \(item.isWatched ? "Watched" : "Up Next")"
            }
            if updated.contains("isWatched") || updated.contains("watchedAt") {
                return item.isWatched
                    ? "\(actor) marked \(title) watched"
                    : "\(actor) marked \(title) unwatched"
            }
            if updated.contains("watchedSeasonsRaw") {
                return "\(actor) updated seasons for \(title)"
            }
            if updated.contains("userRatingNumber") {
                return "\(actor) rated \(title)"
            }
            if updated.contains("userNotes") {
                return "\(actor) left a note on \(title)"
            }
            return nil   // reorders and the like aren't worth a ping

        case let list as CustomList:
            if change.changeType == .insert {
                return "\(actor) created the collection \(list.name)"
            }
            if updated.contains("name") {
                return "\(actor) renamed a collection to \(list.name)"
            }
            return nil

        case let entry as CustomListItem:
            guard let title = entry.media?.title, let collection = entry.customList?.name else { return nil }
            if change.changeType == .insert {
                return "\(actor) added \(title) to \(collection)"
            }
            if updated.contains("watchedAt") {
                return entry.isWatched
                    ? "\(actor) marked \(title) watched in \(collection)"
                    : "\(actor) marked \(title) unwatched in \(collection)"
            }
            return nil

        default:
            // Movie / TVShow / Network rows change on every metadata refresh — never announce.
            return nil
        }
    }

    /// The CloudKit record behind `objectID` when it was last written by another Apple Account,
    /// else nil. The current account is always reported as `CKCurrentUserDefaultName`, whichever
    /// device it used. Unknown (no record yet) counts as "mine" — better to miss a ping than to
    /// misattribute.
    private static func recordModifiedBySomeoneElse(_ objectID: NSManagedObjectID, persistence: PersistenceController) -> CKRecord? {
        guard let record = persistence.container.record(for: objectID),
              let modifier = record.lastModifiedUserRecordID,
              modifier.recordName != CKCurrentUserDefaultName
        else { return nil }
        return record
    }
}
