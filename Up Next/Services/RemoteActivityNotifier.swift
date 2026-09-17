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
        // Only meaningful once there's someone on the other end.
        guard persistence.role == .participant || persistence.existingShare() != nil else { return }

        let actor = persistence.partnerDisplayName()
        var messages: [String] = []
        for transaction in transactions {
            for change in transaction.changes ?? [] {
                guard let message = message(for: change, actor: actor, persistence: persistence),
                      !messages.contains(message)
                else { continue }
                messages.append(message)
            }
        }
        guard !messages.isEmpty else { return }

        let lines: [String]
        if messages.count > detailLimit {
            lines = ["\(actor) made \(messages.count) changes to your shared library"]
        } else {
            lines = messages
        }

        if UIApplication.shared.applicationState == .active {
            persistence.recentRemoteActivity = lines
            return
        }

        let newest = transactions.map(\.timestamp).max() ?? .distantPast
        guard Date.now.timeIntervalSince(newest) < staleAfter else { return }
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

    private static func message(
        for change: NSPersistentHistoryChange,
        actor: String,
        persistence: PersistenceController
    ) -> String? {
        let objectID = change.changedObjectID
        guard change.changeType != .delete else { return nil }
        guard let object = try? persistence.viewContext.existingObject(with: objectID),
              !object.isDeleted,
              isModifiedBySomeoneElse(objectID, persistence: persistence)
        else { return nil }

        let updated = Set((change.updatedProperties ?? []).map(\.name))

        switch object {
        case let item as ListItem:
            guard let title = item.media?.title else { return nil }
            if change.changeType == .insert {
                if let list = item.list?.name, !list.isEmpty {
                    return "\(actor) added \(title) to \(list)"
                }
                return "\(actor) added \(title)"
            }
            if updated.contains("isWatched") || updated.contains("watchedAt") {
                return item.isWatched
                    ? "\(actor) marked \(title) watched"
                    : "\(actor) marked \(title) unwatched"
            }
            if updated.contains("droppedAt") {
                return item.isDropped
                    ? "\(actor) stopped watching \(title)"
                    : "\(actor) picked \(title) back up"
            }
            if updated.contains("watchedSeasonsRaw") {
                if let next = item.nextSeasonToWatch {
                    return "\(actor) is up to season \(next) of \(title)"
                }
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

    /// True when the CloudKit record behind `objectID` was last written by another Apple Account.
    /// The current account is always reported as `CKCurrentUserDefaultName`, whichever device it
    /// used. Unknown (no record yet) counts as "mine" — better to miss a ping than to misattribute.
    private static func isModifiedBySomeoneElse(_ objectID: NSManagedObjectID, persistence: PersistenceController) -> Bool {
        guard let record = persistence.container.record(for: objectID),
              let modifier = record.lastModifiedUserRecordID
        else { return false }
        return modifier.recordName != CKCurrentUserDefaultName
    }
}
