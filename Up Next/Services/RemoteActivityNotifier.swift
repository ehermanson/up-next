import CloudKit
import CoreData
import UIKit
import UserNotifications

/// Turns the other person's edits — which arrive as CloudKit imports and are recorded in
/// persistent history — into something the user actually sees: a local notification while the app
/// is in the background, a toast (via `PersistenceController.recentRemoteActivity`) while it's on
/// screen. Nothing here talks to a server; the silent CloudKit push that triggers the import is
/// what wakes the app.
///
/// The only input is imported `ActivityEvent`s, which every mutation writes explicitly (see
/// `PersistenceController.recordActivity`). Diffing the changed rows themselves used to drive
/// this, but a deleted row has no CloudKit record left to attribute, so removals were never
/// announced — and season toggles, drops and watched flips all touch the same fields.
///
/// Attribution uses the event record's `creatorUserRecordID`: the current account is always
/// `CKCurrentUserDefaultName`, whichever device it used, so an event from the user's *own* iPad is
/// skipped and only the other person's are announced.
@MainActor
enum RemoteActivityNotifier {
    /// Above this many distinct changes in one batch, one summary line replaces the list.
    private static let detailLimit = 3
    /// Events older than this (app was closed for a while) are merged silently.
    private static let staleAfter: TimeInterval = 10 * 60
    /// A join's first import arrives as one bulk transaction, but the `isJoiningSharedLibrary`
    /// flag clears on the very first one — the rest of the same import would otherwise read as
    /// "Sarah made 200 changes". Stay quiet for a moment after the library lands.
    private static let quietAfterJoin: TimeInterval = 60
    /// `PersistenceController.otherPersonDisplayName()`'s answer when iOS gave no name.
    private static let unnamedActor = "Someone"

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

    /// Announces the other person's events in `transactions` (already merged into the view context).
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

        // Cheap rejection before anything touches the share: a metadata refresh on the other
        // device imports hundreds of media-row changes and no events.
        var insertedEvents: [NSPersistentHistoryChange] = []
        for transaction in transactions {
            for change in transaction.changes ?? [] where change.changeType == .insert {
                if change.changedObjectID.entity.name == "ActivityEvent" { insertedEvents.append(change) }
            }
        }
        guard !insertedEvents.isEmpty else { return }

        // Only meaningful once there's someone on the other end.
        guard persistence.role == .participant || persistence.existingShare() != nil else { return }

        let otherName = persistence.otherPersonDisplayName()
        let isActive = UIApplication.shared.applicationState == .active
        var messages: [String] = []
        var actors: [String] = []
        for change in insertedEvents {
            guard let event = try? persistence.viewContext.existingObject(with: change.changedObjectID) as? ActivityEvent,
                  !event.isDeleted,
                  event.kind != nil,
                  // The event's own timestamp is when the edit happened; history timestamps say
                  // when the import ran. A day-old edit that only synced now shouldn't buzz the
                  // phone, and on a reinstall the first history fetch returns everything ever done.
                  Date.now.timeIntervalSince(event.createdAt) <= staleAfter,
                  isCreatedBySomeoneElse(event, persistence: persistence)
            else { continue }
            // iOS may withhold the other participant's name from this device while the writer
            // knew its own; prefer ours, fall back to theirs.
            let actor = otherName == unnamedActor ? (event.actorName ?? otherName) : otherName
            let message = event.sentence(actor: actor)
            guard !messages.contains(message) else { continue }
            messages.append(message)
            actors.append(actor)
        }
        guard !messages.isEmpty else { return }

        let lines: [String]
        if messages.count > detailLimit {
            lines = ["\(actors.first ?? otherName) made \(messages.count) changes to your shared watchlist"]
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

    /// True when the event's CloudKit record was created by another Apple Account. The current
    /// account is always reported as `CKCurrentUserDefaultName`, whichever device it used. Unknown
    /// (no record yet) counts as "mine" — better to miss a ping than to misattribute.
    private static func isCreatedBySomeoneElse(_ event: ActivityEvent, persistence: PersistenceController) -> Bool {
        guard let record = persistence.container.record(for: event.objectID),
              let creator = record.creatorUserRecordID
        else { return false }
        return creator.recordName != CKCurrentUserDefaultName
    }
}
