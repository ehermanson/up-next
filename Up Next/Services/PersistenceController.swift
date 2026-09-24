import UIKit
import CloudKit
import CoreData
import Foundation
import OSLog

/// Owns the single `NSPersistentCloudKitContainer` for the shared-library store. Two stores live under one container: `private.sqlite`
/// (this device's private CloudKit database) and `shared.sqlite` (a window into a share zone
/// this device has accepted, if any). Exactly one `WatchListGroup` is the share root; the "a
/// shared group wins" role rule decides whether this device reads/writes the shared store (a
/// participant) or the private store (an owner) — see `bootstrap()`.
@MainActor
@Observable
final class PersistenceController {
    static let shared = PersistenceController()

    // `nonisolated` so `LibraryShareItem`'s `CKShareTransferRepresentation` exporter
    // (`Views/Settings/SharingSettingsView.swift`), which the system share sheet may invoke off
    // the main actor, can read it without hopping actors.
    nonisolated static let containerIdentifier = "iCloud.com.erichermanson.upnext.shared"
    static let transactionAuthor = "app"

    enum Role {
        case owner
        case participant
    }

    let container: NSPersistentCloudKitContainer
    /// False in screenshot mode or with `--no-cloudkit`; the stores are then local-only.
    let isCloudKitEnabled: Bool

    private static let initialImportSettledKey = "sync.initialImportSettled"
    /// True once the first CloudKit import has finished (either way) or timed out. Seeding a root
    /// waits for this: a fresh device on an account that already has a library would otherwise
    /// create a second root before the real one arrives. Persisted so later launches don't wait.
    private var initialImportSettled: Bool {
        get { !isCloudKitEnabled || UserDefaults.standard.bool(forKey: Self.initialImportSettledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.initialImportSettledKey) }
    }
    private var initialImportWaiter: Task<Void, Never>?
    private var importEventToken: NSObjectProtocol?

    // Implicitly unwrapped rather than plain optionals so `activeStore` (read from every insert
    // and from `MediaItem.swift`'s canonical-row lookups) stays non-optional. The guarantee that
    // makes that safe: `bootstrap()` throws `PersistenceError.storeUnavailable` before touching
    // either store when `storeLoadError` is set, and `Watch_ListApp` then renders a failure screen
    // instead of `ContentView`, so nothing that dereferences a store is ever constructed.
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!

    /// Non-nil when a persistent store could not be opened (a failed migration, a corrupt file, a
    /// full disk). The stack is unusable in that state, but nothing here deletes or recreates a
    /// store: the user's data is still in iCloud and a reinstall recovers it.
    private(set) var storeLoadError: Error?

    private(set) var role: Role = .owner
    private(set) var group: WatchListGroup!
    // `fileprivate(set)` rather than `private(set)` so `RemoteChangeObserver` (a separate type
    // declared lower in this file) can bump it directly after a debounced merge.
    fileprivate(set) var remoteChangeCount = 0

    private var remoteChangeObserver: RemoteChangeObserver?

    /// Set between accepting a share and the shared zone's first import landing. CloudKit imports
    /// asynchronously, so right after `acceptShare` neither store holds a group — without this
    /// flag the role rule would seed a fresh private group and the device would stay an owner.
    private static let pendingSharedJoinKey = "sharing.pendingJoin"

    /// True while this device has accepted a share but the shared library hasn't arrived yet.
    /// `group` is nil in that state; the UI shows a "joining" placeholder. Stored (not read from
    /// UserDefaults on demand) so SwiftUI observes the flip; mirrored to UserDefaults to survive
    /// a relaunch before the import lands.
    private(set) var isJoiningSharedLibrary: Bool = UserDefaults.standard.bool(forKey: PersistenceController.pendingSharedJoinKey) {
        didSet { UserDefaults.standard.set(isJoiningSharedLibrary, forKey: Self.pendingSharedJoinKey) }
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    var activeStore: NSPersistentStore {
        role == .participant ? sharedStore : privateStore
    }

    /// True when launched for App Store screenshot capture — mirrors `ScreenshotMode.isEnabled`
    /// (`Up Next/App/ScreenshotMode.swift`), which gates on `--screenshots`. Checked again here
    /// (rather than depending on that type directly) so this file has no ordering dependency on
    /// another target member during the migration; keep the flags in sync if either changes.
    private static var isScreenshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshots")
            || ProcessInfo.processInfo.arguments.contains("-screenshots")
            || ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1"
    }

    /// The compiled model, loaded once. `nonisolated` so model convenience initializers — which run
    /// off the main actor when `TMDBService` maps API responses into unattached objects — can look
    /// up entity descriptions without hopping actors. The model is immutable after loading.
    nonisolated(unsafe) static let model: NSManagedObjectModel = {
        guard let modelURL = Bundle.main.url(forResource: "Up Next", withExtension: "momd") else {
            fatalError("Could not locate Up Next.momd in the app bundle")
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Could not load managed object model at \(modelURL)")
        }
        return model
    }()

    /// `--no-cloudkit` runs the stack local-only. CloudKit traps (SIGTRAP in `CKContainer`) when the
    /// process lacks the `icloud-services` entitlement, which is the case for unsigned simulator
    /// builds (`CODE_SIGNING_ALLOWED=NO`, e.g. CI smoke tests) — there is no way to probe for the
    /// entitlement from inside the app, so it has to be an explicit opt-out.
    private static var isCloudKitDisabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--no-cloudkit")
    }

    private init() {
        let container = NSPersistentCloudKitContainer(name: "Up Next", managedObjectModel: Self.model)

        let supportDirectory = Self.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let screenshotMode = Self.isScreenshotMode
        let cloudKitEnabled = !screenshotMode && !Self.isCloudKitDisabled

        // Screenshot runs use in-memory stores. They need *distinct* URLs — the coordinator keys
        // stores by URL, so two `/dev/null` stores would collide.
        let privateDescription = NSPersistentStoreDescription(
            url: screenshotMode ? URL(string: "memory://private")! : supportDirectory.appendingPathComponent("private.sqlite")
        )
        if screenshotMode { privateDescription.type = NSInMemoryStoreType }
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloudKitEnabled {
            privateDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: PersistenceController.containerIdentifier
            )
            privateDescription.cloudKitContainerOptions?.databaseScope = .private
        }

        let sharedDescription = NSPersistentStoreDescription(
            url: screenshotMode ? URL(string: "memory://shared")! : supportDirectory.appendingPathComponent("shared.sqlite")
        )
        if screenshotMode { sharedDescription.type = NSInMemoryStoreType }
        sharedDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        sharedDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloudKitEnabled {
            let sharedOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: PersistenceController.containerIdentifier
            )
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
        }

        container.persistentStoreDescriptions = [privateDescription, sharedDescription]

        let loadError = Self.loadStores(container: container)

        self.container = container
        self.isCloudKitEnabled = cloudKitEnabled

        let coordinator = container.persistentStoreCoordinator
        self.privateStore = coordinator.persistentStore(for: privateDescription.url!)
        self.sharedStore = coordinator.persistentStore(for: sharedDescription.url!)
        if privateStore == nil || sharedStore == nil {
            self.storeLoadError = loadError ?? PersistenceError.storeUnavailable(nil)
        }

        let viewContext = container.viewContext
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        viewContext.transactionAuthor = PersistenceController.transactionAuthor
        viewContext.name = "viewContext"
    }

    /// Loads both persistent stores synchronously. If a CloudKit-backed load fails, retries once
    /// per description with CloudKit options removed (local-only fallback) — mirrors the spirit
    /// of the previous `Watch_ListApp` SwiftData fallback. Returns the last error still standing
    /// after the fallback, so `init` can record it instead of leaving a store silently missing.
    private static func loadStores(container: NSPersistentCloudKitContainer) -> Error? {
        // `loadPersistentStores` invokes its completion once per description in
        // `persistentStoreDescriptions` — potentially concurrently, on background queues — so
        // mutations to `pendingRetries` are serialized with a lock rather than called in a loop
        // (which would instead reload every description N times).
        let lock = NSLock()
        var pendingRetries: [NSPersistentStoreDescription] = []
        // Keyed by store URL so a description that loads on the local-only retry drops its entry
        // and only genuinely unusable stores are reported back.
        var failures: [URL: Error] = [:]
        let group = DispatchGroup()

        for _ in container.persistentStoreDescriptions {
            group.enter()
        }
        container.loadPersistentStores { loadedDescription, error in
            if let error, let url = loadedDescription.url {
                AppLog.persistence.error("failed to load store at \(url.lastPathComponent, privacy: .public): \(error)")
                lock.lock()
                failures[url] = error
                if loadedDescription.cloudKitContainerOptions != nil {
                    pendingRetries.append(loadedDescription)
                }
                lock.unlock()
            }
            group.leave()
        }
        group.wait()

        for description in pendingRetries {
            guard let url = description.url else { continue }
            AppLog.persistence.notice("retrying \(url.lastPathComponent, privacy: .public) as local-only (CloudKit disabled)")
            description.cloudKitContainerOptions = nil
            group.enter()
            container.persistentStoreCoordinator.addPersistentStore(with: description) { _, error in
                lock.lock()
                if let error {
                    AppLog.persistence.error("local-only fallback also failed for \(url.lastPathComponent, privacy: .public): \(error)")
                    failures[url] = error
                } else {
                    failures[url] = nil
                }
                lock.unlock()
                group.leave()
            }
            group.wait()
        }
        return failures.values.first
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("UpNext", isDirectory: true)
    }

    /// Looks up an entity description on the compiled model. Callable from any isolation domain
    /// and before `bootstrap()` runs — it never touches the container or the stores.
    nonisolated static func entity(named name: String) -> NSEntityDescription {
        guard let entity = model.entitiesByName[name] else {
            fatalError("No entity named \(name) in the managed object model")
        }
        return entity
    }

    // MARK: - Bootstrap

    /// Applies the role rule, seeds a fresh `WatchListGroup` + "TV Shows"/"Movies" `MediaList`s
    /// when neither store has one, and starts observing remote changes. Must run before any view
    /// model configures. The 1.x SwiftData store (`Watch_List*` in Application Support) is left
    /// untouched on purpose: it's a few MB, this stack never opens it, and leaving it means putting
    /// a 1.x build back on the device restores that data instantly and offline.
    func bootstrap() throws {
        // Nothing below this line may run with a missing store: `applyRoleRule` fetches with
        // `affectedStores` and `activeStore` force-unwraps. Throwing here is what makes the
        // implicitly-unwrapped `privateStore`/`sharedStore` safe everywhere else.
        if privateStore == nil || sharedStore == nil {
            throw PersistenceError.storeUnavailable(storeLoadError)
        }

        // A sync reset left the library on disk as a snapshot and destroyed the stores; put it
        // back before the role rule can seed an empty root over it.
        if FileManager.default.fileExists(atPath: Self.resetSnapshotURL.path) {
            try restoreResetSnapshot()
        }

        try applyRoleRule()
        sweepOrphanedDetailWrappers()
        sweepUnreferencedNetworks()
        sweepDanglingEntries(olderThan: 60 * 60)
        scheduleUnreferencedMediaSweep()
        pruneActivity()
        refreshLiveShare()
        observeSyncEvents()
        Task { await refreshAccountStatus() }

        if remoteChangeObserver == nil {
            remoteChangeObserver = RemoteChangeObserver(persistence: self)
            remoteChangeObserver?.start()
        }

        #if DEBUG
        // Simulator exercise for `repairSync()` against the demo seed (`--seed-demo --repair-sync`):
        // waits for the seed to land, then rebuilds. Verifies the deep copy keeps the library.
        if ProcessInfo.processInfo.arguments.contains("--reset-sync") {
            Task {
                try? await Task.sleep(for: .seconds(25))
                do {
                    try await resetSync()
                } catch {
                    AppLog.sync.error("--reset-sync failed: \(error)")
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--dedupe-sync") {
            Task {
                try? await Task.sleep(for: .seconds(15))
                _ = removeDuplicates()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--repair-sync") {
            Task {
                try? await Task.sleep(for: .seconds(25))
                do {
                    try await repairSync()
                } catch {
                    AppLog.sync.error("--repair-sync failed: \(error)")
                }
            }
        }
        #endif
    }

    /// Watchlist / collection entries whose movie or show row is gone. Nothing can render them and
    /// nothing can recover them (the TMDB id lived on the row). An import can legitimately land an
    /// entry a moment before its media row, hence the age gate at bootstrap; the explicit
    /// Remove Duplicates pass uses 0. Returns how many went.
    @discardableResult
    private func sweepDanglingEntries(olderThan age: TimeInterval) -> Int {
        var dropped = 0
        let cutoff = Date.now.addingTimeInterval(-age)
        for entity in ["ListItem", "CustomListItem"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.affectedStores = [activeStore]
            request.predicate = NSPredicate(format: "movie == nil AND tvShow == nil AND (addedAtRaw == nil OR addedAtRaw < %@)", cutoff as NSDate)
            for row in (try? viewContext.fetch(request)) ?? [] {
                viewContext.delete(row)
                dropped += 1
            }
        }
        if dropped > 0 {
            save()
            AppLog.persistence.notice("swept \(dropped) entries with no title row")
        }
        return dropped
    }

    /// Movie / show rows nothing points at. Unlike networks these can't be swept at bootstrap: a
    /// participant's import can land a media row a beat before the entry that references it. So
    /// this waits a few minutes after launch and only runs when nothing is syncing and any join is
    /// long settled — then every unreferenced row is a leftover (a removed title whose row the
    /// other device hadn't cleaned, surgery debt) and just a CloudKit record for nothing.
    private func scheduleUnreferencedMediaSweep() {
        guard isCloudKitEnabled else {
            sweepUnreferencedMedia()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard let self, !isSyncing, !isJoiningSharedLibrary else { return }
            if let joinedAt = joinCompletedAt, Date.now.timeIntervalSince(joinedAt) < 10 * 60 { return }
            sweepUnreferencedMedia()
        }
    }

    @discardableResult
    private func sweepUnreferencedMedia() -> Int {
        var swept = 0
        for entity in ["Movie", "TVShow"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.affectedStores = [activeStore]
            request.predicate = NSPredicate(format: "listItemSet.@count == 0 AND customListItemSet.@count == 0")
            for row in (try? viewContext.fetch(request)) ?? [] {
                viewContext.delete(row)
                swept += 1
            }
        }
        if swept > 0 {
            save()
            sweepUnreferencedNetworks()
            AppLog.persistence.notice("swept \(swept) unreferenced media rows")
        }
        return swept
    }

    /// A `Network` row nothing points at is garbage: the metadata refresh replaces a title's
    /// provider rows and `deleteUnreferencedNetworks` doesn't always catch the old ones (the demo
    /// seed shows dozens after one relaunch). They'd otherwise export as records forever. Safe at
    /// bootstrap — no refresh is in flight yet, and a live `Network` is always related in the
    /// same save that inserts it.
    private func sweepUnreferencedNetworks() {
        let request = NSFetchRequest<Network>(entityName: "Network")
        request.predicate = NSPredicate(format: "movieSet.@count == 0 AND tvShowSet.@count == 0")
        let orphans = (try? viewContext.fetch(request)) ?? []
        guard !orphans.isEmpty else { return }
        for network in orphans { viewContext.delete(network) }
        save()
        AppLog.persistence.notice("swept \(orphans.count) unreferenced Network rows")
    }

    /// Keeps the activity log bounded: nothing older than 90 days, and at most the newest 500.
    /// Every event is a CloudKit record on the root, so an unbounded log is an unbounded zone.
    /// Either role may prune — the deletes sync, and both devices pruning the same rows is harmless.
    private func pruneActivity() {
        let request = NSFetchRequest<ActivityEvent>(entityName: "ActivityEvent")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAtRaw", ascending: false)]
        request.affectedStores = [activeStore]
        guard let events = try? viewContext.fetch(request), !events.isEmpty else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        let expired = events.enumerated().filter { index, event in
            index >= Self.activityLimit || (event.createdAtRaw ?? .distantPast) < cutoff
        }
        guard !expired.isEmpty else { return }
        for (_, event) in expired { viewContext.delete(event) }
        save()
        AppLog.persistence.notice("pruned \(expired.count) activity events")
    }

    private static let activityLimit = 500

    /// Deletes `ListItem`s that were left behind by a detail sheet. Discover and collection detail
    /// sheets wrap a media row in a transient `ListItem` with `list == nil` and delete it on
    /// disappear; a background save followed by a kill persists (and syncs) that wrapper instead.
    /// Safe to run here because live wrappers are only created from a view's `.task`, which is
    /// always after bootstrap.
    private func sweepOrphanedDetailWrappers() {
        let request = NSFetchRequest<ListItem>(entityName: "ListItem")
        request.predicate = NSPredicate(format: "list == nil AND (movie != nil OR tvShow != nil)")
        request.affectedStores = [activeStore]
        guard let orphans = try? viewContext.fetch(request), !orphans.isEmpty else { return }
        for orphan in orphans {
            viewContext.delete(orphan)
        }
        AppLog.persistence.notice("swept \(orphans.count) orphaned detail-sheet list items")
        save()
    }

    private func applyRoleRule() throws {
        if let existing = try reconciledRoot(in: sharedStore) {
            if isJoiningSharedLibrary {
                // The shared zone's first import just landed. `RemoteActivityNotifier` stays quiet
                // for a moment afterwards: the rest of that bulk import is the library arriving,
                // not the partner making changes.
                joinCompletedAt = .now
            }
            role = .participant
            group = existing
            // Streaming services live on the root too, so joining adopts the household's set.
            ProviderSettings.shared.adoptSelection(from: existing)
            isJoiningSharedLibrary = false
            // A join that was interrupted between `acceptShareInvitations` and the private purge
            // leaves rows in the inactive store; a `ListItem` related to one of those would fail
            // the next save with a cross-store reference.
            purgeLeftoverPrivateData()
            settleInitialImport()
            // Sharing is live on this device (including participants who joined before the
            // app could notify, or whose library arrived via account sync) — worth a ping.
            RemoteActivityNotifier.requestPermissionIfNeeded()
            return
        }

        // Accepted a share, import not landed yet: stay a participant with no group rather than
        // seeding. `RemoteChangeObserver` re-runs this rule when the shared store changes.
        if isJoiningSharedLibrary {
            role = .participant
            group = nil
            return
        }

        role = .owner
        if let existing = try reconciledRoot(in: privateStore) {
            group = existing
            ProviderSettings.shared.adoptSelection(from: existing)
            settleInitialImport()
            return
        }

        // Nothing anywhere. On a CloudKit-backed first launch the account may already hold a
        // library that simply hasn't imported yet — wait for that before seeding.
        guard initialImportSettled else {
            group = nil
            awaitInitialImportThenRetry()
            return
        }
        try seedOwnerRoot()
    }

    /// Participant only: drops anything still sitting in the private store. A join purges it, but
    /// `acceptShareInvitations` and the purge aren't atomic — a crash or a kill in between leaves
    /// the old library behind, unreachable from any group yet still matched by the canonical-row
    /// lookups in `MediaItem.swift`.
    private func purgeLeftoverPrivateData() {
        let leftovers = ["WatchListGroup", "ListItem", "CustomList"].contains { name in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
            request.affectedStores = [privateStore]
            return ((try? viewContext.count(for: request)) ?? 0) > 0
        }
        guard leftovers else { return }
        AppLog.persistence.notice("purging leftover private-store data after an interrupted join")
        do {
            try purgeAllObjects(in: privateStore)
            save()
        } catch {
            AppLog.persistence.error("failed to purge leftover private-store data: \(error)")
        }
    }

    /// Seeds a fresh group + default lists into the private store.
    private func seedOwnerRoot() throws {
        let newGroup = WatchListGroup(context: viewContext)
        viewContext.assign(newGroup, to: privateStore)

        let tvList = MediaList(name: "TV Shows", createdAt: .now, context: viewContext)
        tvList.group = newGroup
        viewContext.assign(tvList, to: privateStore)

        let movieList = MediaList(name: "Movies", createdAt: .now, context: viewContext)
        movieList.group = newGroup
        viewContext.assign(movieList, to: privateStore)

        // The mirror still holds the last household set, so leaving a share (or the owner stopping
        // one) keeps this device's services instead of resetting them. It also carries the
        // onboarding picks — and the `--screenshots` preselect — onto a brand new root.
        newGroup.selectedProviderIDs = ProviderSettings.shared.selectedProviderIDs

        try viewContext.save()
        group = newGroup
        ProviderSettings.shared.adoptSelection(from: newGroup)
    }

    /// The single root in `store`, merging duplicates first. Two devices on one account can each
    /// seed a root before the other's synced down; when that happens every extra root's lists and
    /// collections are moved onto one winner and the extras deleted. Winner: a root that already
    /// carries a `CKShare` (moving anything *out* of a share zone would break the share), else the
    /// lowest id — deterministic, so every device converges on the same root.
    private func reconciledRoot(in store: NSPersistentStore) throws -> WatchListGroup? {
        let request = NSFetchRequest<WatchListGroup>(entityName: "WatchListGroup")
        request.affectedStores = [store]
        let roots = try viewContext.fetch(request)
        // Rows created before ids existed get one now, so `id` is stable from here on.
        for root in roots where root.idRaw == nil { root.idRaw = UUID() }
        for list in roots.flatMap({ $0.lists ?? [] }) where list.idRaw == nil { list.idRaw = UUID() }
        if viewContext.hasChanges { try viewContext.save() }
        guard roots.count > 1 else { return roots.first }

        let shares = (try? container.fetchShares(matching: roots.map(\.objectID))) ?? [:]
        let sorted = roots.sorted { $0.id.uuidString < $1.id.uuidString }
        let winner = sorted.first { shares[$0.objectID] != nil } ?? sorted[0]

        for loser in sorted where loser !== winner {
            // Whichever root actually got services keeps them: the winner is picked on id, not on
            // which device did the onboarding, so the picks can easily sit on a loser.
            if winner.selectedProviderIDs == nil, let losing = loser.selectedProviderIDs {
                winner.selectedProviderIDs = losing
            }
            for list in loser.lists ?? [] { list.group = winner }
            for list in loser.customLists ?? [] { list.group = winner }
            // Let the inverses update before the cascade delete, so nothing moved gets deleted.
            viewContext.processPendingChanges()
            viewContext.delete(loser)
        }
        mergeDuplicateLists(in: winner)
        try viewContext.save()
        return winner
    }

    /// Folds same-named `MediaList`s (two seeded "TV Shows" lists) into one — lowest id keeps the
    /// name, the others' items are appended after its own in their existing order, and the
    /// emptied lists are deleted.
    private func mergeDuplicateLists(in root: WatchListGroup) {
        let byName = Dictionary(grouping: root.lists ?? [], by: \.name)
        for lists in byName.values where lists.count > 1 {
            let sorted = lists.sorted { $0.id.uuidString < $1.id.uuidString }
            let keep = sorted[0]
            var nextOrder = ((keep.items ?? []).map(\.order).max() ?? -1) + 1
            for extra in sorted.dropFirst() {
                for item in (extra.items ?? []).sorted(by: { $0.order < $1.order }) {
                    item.list = keep
                    item.order = nextOrder
                    nextOrder += 1
                }
                viewContext.processPendingChanges()
                viewContext.delete(extra)
            }
        }
    }

    // MARK: Initial import wait

    /// Marks the first import as done (a root exists, so there's nothing to wait for) and stops
    /// any pending wait.
    private func settleInitialImport() {
        guard !initialImportSettled else { return }
        initialImportSettled = true
        cancelInitialImportWait()
    }

    private func cancelInitialImportWait() {
        initialImportWaiter?.cancel()
        initialImportWaiter = nil
        if let importEventToken {
            NotificationCenter.default.removeObserver(importEventToken)
            self.importEventToken = nil
        }
    }

    /// Re-runs the role rule once the container reports its first finished import event (success
    /// or failure — no account is a failure) or after a 10 s timeout, whichever comes first.
    private func awaitInitialImportThenRetry() {
        guard initialImportWaiter == nil else { return }

        importEventToken = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil
            else { return }
            // Strengthened here rather than inside the `Task`: a weakly captured `self` is a
            // mutable binding, and referencing one from a concurrently-executing closure is an
            // error under the Swift 6 language mode. This type is `@MainActor`, so `Sendable`.
            guard let self else { return }
            Task { @MainActor in self.finishInitialImportWait() }
        }

        initialImportWaiter = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.finishInitialImportWait()
        }
    }

    private func finishInitialImportWait() {
        guard !initialImportSettled else { return }
        initialImportSettled = true
        cancelInitialImportWait()
        try? applyRoleRule()
        refreshLiveShare()
        remoteChangeCount += 1
    }

    func list(named name: String) -> MediaList? {
        group?.lists?.first { $0.name == name }
    }

    // MARK: - CRUD helpers

    func insert(_ object: NSManagedObject) {
        viewContext.insert(object)
        viewContext.assign(object, to: activeStore)
    }

    /// The last failed `save()`, for `ContentView` to toast once. Cleared by
    /// `clearLastSaveError()` as soon as it has been shown.
    private(set) var lastSaveError: Error?

    func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            // Rolling back matters more than the message: a rejected change left in the context
            // fails every subsequent save too, so one bad edit would silently stop all persistence.
            AppLog.persistence.error("save failed: \(error)")
            viewContext.rollback()
            lastSaveError = error
        }
    }

    func clearLastSaveError() {
        lastSaveError = nil
    }

    // MARK: - Activity

    /// This account's CloudKit user record name, fetched once per launch (`refreshAccountStatus`)
    /// and stamped on every `ActivityEvent` as `actorRecordName`. Nil until fetched or offline —
    /// an event without it is still attributed correctly by its record's creator.
    private(set) var currentUserRecordName: String?

    /// True while a bulk path (1.x import, demo seed) is adding titles — none of those are "someone
    /// did something" moments, and 50 events for an import would drown the Activity screen.
    var isSuppressingActivity = false

    /// The one place activity is written. No-op without a live root (mid-join), or while suppressed.
    /// Not saved here — the caller's mutation and its event land in the same save.
    func recordActivity(
        _ kind: ActivityEvent.Kind,
        title: String,
        mediaKey: String? = nil,
        contextName: String? = nil
    ) {
        guard !isSuppressingActivity else { return }
        guard let group, group.managedObjectContext != nil, !group.isDeleted else { return }
        // Only what's already in memory: nil when unshared (or iOS withholds it), which is fine —
        // the reader prefers its own view of the other person's name anyway.
        let actorName = liveShare?.currentUserParticipant?.shortDisplayName
        _ = ActivityEvent(
            kind: kind,
            title: title,
            mediaKey: mediaKey,
            contextName: contextName,
            actorName: actorName,
            actorRecordName: currentUserRecordName,
            group: group
        )
        AppLog.sharing.debug("activity: \(kind.rawValue, privacy: .public) \(title, privacy: .private)")
    }

    /// A library title's watched mark, phrased from its state *after* the change — so a dropped
    /// show's "Pick Back Up" reads as unwatched. Library marks carry no context (see
    /// `ActivityEvent.contextName`). Wrapper items (`list == nil`) are never library edits.
    func recordWatchedActivity(for item: ListItem) {
        guard item.list != nil, let media = item.media else { return }
        recordActivity(
            item.isWatched ? .watched : .unwatched,
            title: media.title,
            mediaKey: MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        )
    }

    func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>) -> [T] {
        do {
            return try viewContext.fetch(request)
        } catch {
            AppLog.persistence.error("fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Sharing

    /// The CloudKit container backing this app's stack. `nonisolated` for the same reason as
    /// `containerIdentifier` above — the sharing exporter reads it off the main actor.
    nonisolated static var ckContainer: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    /// The single share on `group`, if one exists. A synchronous store round-trip — never call it
    /// from a view `body`; read `liveShare` instead.
    func existingShare() -> CKShare? {
        guard let group else { return nil }
        guard let shares = try? container.fetchShares(matching: [group.objectID]) else { return nil }
        return shares[group.objectID]
    }

    /// Observable mirror of `existingShare()`. Refreshed on bootstrap, after every remote-change
    /// batch, after join/leave, and on demand via `refreshLiveShare()` (call that when a system
    /// sharing sheet closes, since those are presented outside SwiftUI). Views and toolbar
    /// buttons read this instead of fetching shares in `body`.
    private(set) var liveShare: CKShare?

    func refreshLiveShare() {
        liveShare = existingShare()
    }

    /// The local mirror of the share only changes when *records* import, and a participant
    /// accepting the invitation changes the share record alone — no managed object, no history
    /// transaction, none of the usual refresh hooks. So "Invitation sent — waiting" sat on the
    /// owner's screen after the join was long done. Fetches the share from the server, adopts it
    /// for display and writes it back into the mirror. Cheap (one record); safe to call on appear.
    func refreshLiveShareFromServer() async {
        guard isCloudKitEnabled, let local = existingShare() else {
            refreshLiveShare()
            return
        }
        let database = role == .participant ? Self.ckContainer.sharedCloudDatabase : Self.ckContainer.privateCloudDatabase
        guard let fetched = try? await database.record(for: local.recordID) as? CKShare else {
            refreshLiveShare()
            return
        }
        liveShare = fetched
        let store: NSPersistentStore = role == .participant ? sharedStore : privateStore
        do {
            try await container.persistUpdatedShare(fetched, in: store)
        } catch {
            AppLog.sharing.error("persistUpdatedShare failed: \(error)")
        }
    }

    /// True once sharing is actually live on this device: a participant, or an owner whose share
    /// has at least one non-owner participant. A `CKShare` nobody has been invited to (the share
    /// sheet was cancelled after the share was created) counts as *not* shared.
    var isSharingLive: Bool {
        if role == .participant { return true }
        return liveShare?.participants.contains { $0.role != .owner } ?? false
    }

    /// Whether the iCloud account can back CloudKit (`CKAccountStatus.available`). `nil` until the
    /// first check completes; `false` when CloudKit is disabled for this run (`--no-cloudkit`,
    /// screenshot mode) or the user is signed out / restricted.
    private(set) var isCloudAccountAvailable: Bool?

    #if DEBUG
    /// Development only. Asks `NSPersistentCloudKitContainer` to create every record type and
    /// field in the CloudKit *Development* schema by round-tripping temporary records. The
    /// just-in-time schema only learns a field the first time a record carrying a non-nil value
    /// for it is exported — an optional attribute nobody has set yet (`watchingStartedAt` on a
    /// library with nothing in Watching) never shows up in the Console on its own, so there's
    /// nothing to deploy. Run from the Settings debug section on a signed-in device, then
    /// "Deploy Schema Changes" in the Console. Synchronous and slow-ish (a few seconds).
    func initializeCloudKitSchema() throws {
        guard isCloudKitEnabled else { throw PersistenceError.cloudKitDisabled }
        try container.initializeCloudKitSchema(options: [])
        AppLog.sync.notice("CloudKit Development schema initialized")
    }


    /// Development only: proves (or disproves) that this build can talk to the container at all,
    /// then runs `initializeCloudKitSchema()`. Everything is reported as text for the debug alert
    /// so a device that isn't attached to Xcode still gives a usable answer.
    func cloudKitDiagnostics() async -> String {
        var lines = ["Container: \(Self.containerIdentifier)"]
        guard isCloudKitEnabled else {
            lines.append("CloudKit: off for this launch")
            return lines.joined(separator: "\n")
        }
        let ck = Self.ckContainer
        do {
            let status = try await ck.accountStatus()
            lines.append("Account: \(Self.describe(status))")
        } catch {
            lines.append("Account: error — \(error.localizedDescription)")
        }
        do {
            let zones = try await ck.privateCloudDatabase.allRecordZones()
            lines.append("Private zones: \(zones.map(\.zoneID.zoneName).sorted().joined(separator: ", "))")
        } catch {
            lines.append("Private zones: error — \(error.localizedDescription)")
        }
        do {
            try initializeCloudKitSchema()
            lines.append("Schema init: OK")
        } catch {
            lines.append("Schema init: \(error.localizedDescription)")
        }
        do {
            try await ensureShareRecordTypeExists()
            lines.append("cloudkit.share type: OK")
        } catch {
            lines.append("cloudkit.share type: \(Self.describeSyncError(error))")
        }
        return lines.joined(separator: "\n")
    }

    #endif

    /// `initializeCloudKitSchema` covers the `CD_*` types but not `cloudkit.share`, the system
    /// record type CloudKit only creates the first time a share is actually saved. Deploy without
    /// it and every share attempt in Production fails with "Cannot create new type cloudkit.share
    /// in production schema" — and the mirroring delegate, whose setup saves the zone's share,
    /// never initializes, so nothing exports at all. This saves a throwaway root + `CKShare` in a
    /// temporary zone (Development) and deletes the zone again, purely so the type exists.
    func ensureShareRecordTypeExists() async throws {
        guard isCloudKitEnabled else { throw PersistenceError.cloudKitDisabled }
        let database = Self.ckContainer.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "schema-probe-\(UUID().uuidString)")
        _ = try await database.save(zone)
        do {
            let rootID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone.zoneID)
            let root = CKRecord(recordType: "CD_WatchListGroup", recordID: rootID)
            let share = CKShare(rootRecord: root)
            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [root, share], deleting: [], savePolicy: .allKeys)
            AppLog.sync.notice("cloudkit.share record type ensured in Development")
        } catch {
            try? await database.deleteRecordZone(withID: zone.zoneID)
            throw error
        }
        try await database.deleteRecordZone(withID: zone.zoneID)
    }

    /// Reads this process's own unified log — the mirroring delegate runs in-process, so its full
    /// `com.apple.coredata` lines (the ones a sanitized `Event.error` hides) are readable here
    /// without a Mac attached. Errors, faults and anything CloudKit-flavoured from the last
    /// `minutes`, newest last, capped.
    func recentCoreDataLog(minutes: Int = 30) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date.now.addingTimeInterval(-Double(minutes * 60)))
            let predicate = NSPredicate(format: "subsystem == %@ OR subsystem == %@", "com.apple.coredata", "com.erichermanson.upnext")
            let entries = try store.getEntries(at: position, matching: predicate)
            let formatter = ISO8601DateFormatter()
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                let message = entry.composedMessage
                let isInteresting = entry.level == .error || entry.level == .fault
                    || message.contains("CKError") || message.contains("CloudKit") || message.contains("ailed")
                guard isInteresting else { continue }
                lines.append("\(formatter.string(from: entry.date)) [\(entry.subsystem):\(entry.category)] \(message)")
            }
            let kept = lines.suffix(150)
            return kept.isEmpty ? "No matching log entries in the last \(minutes) minutes." : kept.joined(separator: "\n")
        } catch {
            return "Log unavailable: \(error.localizedDescription)"
        }
    }

    /// "share …90AF4147" / "coredata zone" / "_defaultZone" — enough to tell the share zone apart.
    private static func shortZoneName(_ zoneID: CKRecordZone.ID) -> String {
        let name = zoneID.zoneName
        if name.hasPrefix("com.apple.coredata.cloudkit.share.") { return "share …\(name.suffix(8))" }
        if name == "com.apple.coredata.cloudkit.zone" { return "coredata zone" }
        return name
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "no account"
        case .restricted: "restricted"
        case .couldNotDetermine: "could not determine"
        case .temporarilyUnavailable: "temporarily unavailable"
        @unknown default: "unknown"
        }
    }

    func refreshAccountStatus() async {
        guard isCloudKitEnabled else {
            isCloudAccountAvailable = false
            return
        }
        let status = try? await Self.ckContainer.accountStatus()
        isCloudAccountAvailable = status == .available
        if status == .available, currentUserRecordName == nil {
            currentUserRecordName = try? await Self.ckContainer.userRecordID().recordName
        }
    }

    /// Creates (and returns) the single `CKShare` rooted at `group`.
    func createShare() async throws -> CKShare {
        guard let group else {
            throw PersistenceError.noGroup
        }
        // `share(_:to:)` moves the whole graph into a new zone and queues behind any export in
        // flight — on a device's first launch against a fresh CloudKit environment that's the
        // entire library, and the system share sheet just spins with no way to tell. A bounded
        // wait turns "forever" into an error that names the cause. The underlying operation
        // isn't cancellable; if it lands later, `liveShare` picks the share up on the next refresh
        // and `LibraryShareItem` hands that existing share to the sheet instead of a second one.
        let started = Date.now
        // Detached on purpose: if `container.share` wedges the main thread, the in-group timeout
        // below can never be delivered, and this is the only line that will explain the silence.
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(Self.shareTimeout))
            guard !Task.isCancelled else { return }
            Self.writeSyncActivity(SyncActivityEntry(
                kind: "share",
                startDate: started,
                endDate: .now,
                errorText: "Still running after \(Int(Self.shareTimeout)) s — container.share has not returned; the app’s main thread may be blocked inside it."
            ))
        }
        defer { watchdog.cancel() }
        do {
            let share = try await withThrowingTaskGroup(of: CKShare.self) { tasks in
                tasks.addTask { @MainActor in
                    let (_, share, _) = try await self.container.share([group], to: nil)
                    return share
                }
                tasks.addTask {
                    try await Task.sleep(for: .seconds(Self.shareTimeout))
                    throw PersistenceError.shareTimedOut
                }
                guard let share = try await tasks.next() else { throw PersistenceError.shareTimedOut }
                tasks.cancelAll()
                return share
            }
            // What Messages shows in the bubble and what the system's "Open …?" prompt names.
            // Without these it reads "Shared from Up Next" and 'Open "cloudkit.zoneshare"?'.
            share[CKShare.SystemFieldKey.title] = "Up Next Watchlist" as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = "com.erichermanson.upnext.watchlist" as CKRecordValue
            if let icon = UIImage(named: "LaunchIcon"), let png = icon.pngData() {
                share[CKShare.SystemFieldKey.thumbnailImageData] = png as CKRecordValue
            }
            appendSyncActivity(kind: "share", startDate: started, errorText: nil)
            return share
        } catch {
            appendSyncActivity(kind: "share", startDate: started, errorText: Self.describeSyncError(error))
            AppLog.sharing.error("createShare failed: \(error)")
            throw error
        }
    }

    private static let shareTimeout: TimeInterval = 60

    /// Everything the Console would tell us, from the phone: which build/environment this is,
    /// account state, the zones in both databases, whether the root record has actually been
    /// acknowledged by the server, and how many titles have. Logged as a "check" entry.
    func runCloudKitCheck() async {
        let started = Date.now
        var lines: [String] = []
        let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
        let buildKind = receipt == "sandboxReceipt" ? "TestFlight" : receipt == "receipt" ? "App Store" : "Xcode"
        lines.append("Build: \(buildKind); container \(Self.containerIdentifier)")
        guard isCloudKitEnabled else {
            lines.append("CloudKit: off for this launch")
            appendSyncActivity(kind: "check", startDate: started, errorText: lines.joined(separator: "\n"))
            return
        }
        let ck = Self.ckContainer
        do {
            lines.append("Account: \(Self.describe(try await ck.accountStatus()))")
        } catch {
            lines.append("Account: \(Self.describeSyncError(error))")
        }
        do {
            let zones = try await ck.privateCloudDatabase.allRecordZones().map(\.zoneID.zoneName).sorted()
            lines.append("Private zones: \(zones.isEmpty ? "none" : zones.joined(separator: ", "))")
        } catch {
            lines.append("Private zones: \(Self.describeSyncError(error))")
        }
        do {
            let zones = try await ck.sharedCloudDatabase.allRecordZones().map(\.zoneID.zoneName).sorted()
            lines.append("Shared zones: \(zones.isEmpty ? "none" : zones.joined(separator: ", "))")
        } catch {
            lines.append("Shared zones: \(Self.describeSyncError(error))")
        }
        lines.append("Role: \(role == .participant ? "participant" : "owner"); share on root: \(existingShare() != nil ? "yes" : "no")")
        if let group {
            if let record = container.record(for: group.objectID) {
                lines.append("Root record: zone \(record.recordID.zoneID.zoneName), server-acknowledged: \(record.recordChangeTag != nil ? "yes" : "no")")
            } else {
                lines.append("Root record: not mirrored to CloudKit yet")
            }
        } else {
            lines.append("Root record: no group")
        }
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "ListItem")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(format: "list != nil")
        let ids = (try? viewContext.fetch(request)) ?? []
        let records = container.records(for: ids)
        let acknowledged = records.values.filter { $0.recordChangeTag != nil }.count
        lines.append("Titles: \(ids.count) local, \(records.count) mirrored, \(acknowledged) server-acknowledged")
        // Collections hang off the root directly rather than through a MediaList, so they get
        // their own line — including *which zone* each record went to. A collection mirrored to
        // `com.apple.coredata.cloudkit.zone` instead of the share zone is invisible to the
        // participant even though it's server-acknowledged.
        for (entity, label) in [("CustomList", "Collections"), ("CustomListItem", "Collection entries")] {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
            request.resultType = .managedObjectIDResultType
            let ids = (try? viewContext.fetch(request)) ?? []
            let records = container.records(for: ids)
            let acknowledged = records.values.filter { $0.recordChangeTag != nil }.count
            let zones = Dictionary(grouping: records.values, by: { Self.shortZoneName($0.recordID.zoneID) })
                .map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: ", ")
            lines.append("\(label): \(ids.count) local, \(records.count) mirrored, \(acknowledged) server-acknowledged\(zones.isEmpty ? "" : " (\(zones))")")
        }
        // The active store: a participant's whole graph lives in the shared store, and the first
        // participant check read "0 root(s), 0 lists" because this asked the private one.
        func count(_ entity: String) -> Int {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            request.affectedStores = [activeStore]
            return (try? viewContext.count(for: request)) ?? -1
        }
        lines.append("Structure: \(count("WatchListGroup")) root(s), \(count("MediaList")) lists, \(count("CustomList")) collections, \(count("Movie")) movie rows, \(count("TVShow")) show rows, \(count("Network")) network rows")
        func dangling(_ entity: String) -> Int {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            request.affectedStores = [activeStore]
            request.predicate = NSPredicate(format: "movie == nil AND tvShow == nil")
            return (try? viewContext.count(for: request)) ?? -1
        }
        lines.append("Entries without a title row: \(dangling("ListItem")) watchlist, \(dangling("CustomListItem")) collection (\(count("CustomListItem")) collection entries total)")
        // Media-row hygiene: rows nothing points at are garbage (each is a CloudKit record), and
        // several rows per TMDB id means the canonical lookup was bypassed somewhere.
        for (entity, label) in [("Movie", "movie"), ("TVShow", "show")] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.affectedStores = [activeStore]
            let rows = (try? viewContext.fetch(request)) ?? []
            let unreferenced = rows.filter {
                (($0.value(forKey: "listItemSet") as? NSSet)?.count ?? 0) == 0
                    && (($0.value(forKey: "customListItemSet") as? NSSet)?.count ?? 0) == 0
            }.count
            let ids = Set(rows.compactMap { $0.value(forKey: "id") as? String })
            lines.append("\(label.capitalized) rows: \(rows.count) total, \(unreferenced) unreferenced, \(ids.count) distinct TMDB ids")
        }
        // Direct probes with unsanitized errors. Saving a throwaway share is the definitive test
        // for the `cloudkit.share` system type in *this* environment (Production can't create
        // types, so it either exists or the save says exactly why not).
        do {
            try await ensureShareRecordTypeExists()
            lines.append("Share-type probe: OK (cloudkit.share exists here)")
        } catch {
            lines.append("Share-type probe: \(Self.describeSyncError(error))")
        }
        do {
            let zones = try await ck.privateCloudDatabase.allRecordZones()
            for zone in zones where zone.zoneID.zoneName.hasPrefix("com.apple.coredata.cloudkit.share.") {
                do {
                    // Paged: the first page alone came back as nothing but CDMR (many-to-many
                    // join) records and hid every entity that mattered.
                    var recordTypes: [String] = []
                    var token: CKServerChangeToken?
                    var moreComing = true
                    while moreComing {
                        let changes = try await ck.privateCloudDatabase.recordZoneChanges(inZoneWith: zone.zoneID, since: token, desiredKeys: [])
                        recordTypes += changes.modificationResultsByID.values.compactMap { try? $0.get().record.recordType }
                        token = changes.changeToken
                        moreComing = changes.moreComing
                    }
                    let types = Dictionary(grouping: recordTypes, by: { $0 })
                        .map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: ", ")
                    let isLive = existingShare()?.recordID.zoneID == zone.zoneID
                    lines.append("\(isLive ? "Live share zone" : "Stale share zone") \(zone.zoneID.zoneName.suffix(8)): \(recordTypes.count) records (\(types.isEmpty ? "none" : types))")
                } catch {
                    lines.append("Share zone \(zone.zoneID.zoneName.suffix(8)): \(Self.describeSyncError(error))")
                }
            }
        } catch {
            lines.append("Stale zone scan: \(Self.describeSyncError(error))")
        }
        // A "check" is informational; it goes in the error slot so the text is shown in full.
        appendSyncActivity(kind: "check", startDate: started, errorText: lines.joined(separator: "\n"))
    }

    // MARK: - Sync status

    /// One CloudKit mirroring event (setup / import / export), reduced to what a status line
    /// needs. Kept per type in `lastSyncEvents` — the latest of each, across both stores.
    struct SyncEventSummary {
        let type: NSPersistentCloudKitContainer.EventType
        let startDate: Date
        let endDate: Date?
        let errorText: String?

        var isInFlight: Bool { endDate == nil }
        var succeeded: Bool { endDate != nil && errorText == nil }
    }

    /// Latest setup / import / export event, so the app can say what iCloud is doing instead of
    /// leaving a spinner unexplained. Observable; read by Settings → About and the Sharing screen.
    private(set) var lastSyncEvents: [NSPersistentCloudKitContainer.EventType: SyncEventSummary] = [:]
    private var syncEventToken: NSObjectProtocol?

    /// One line of the persisted activity log (Settings → About → iCloud Sync). Finished events
    /// and share attempts only, newest first, capped — a transient partial failure is the whole
    /// diagnosis and it must survive being replaced by the next successful export, and a relaunch.
    struct SyncActivityEntry: Codable, Identifiable {
        var id = UUID()
        let kind: String
        let startDate: Date
        let endDate: Date
        let errorText: String?
    }

    private static let syncActivityKey = "sync.activityLog"
    private static let syncActivityLimit = 40

    private(set) var syncActivity: [SyncActivityEntry] = PersistenceController.loadSyncActivity()

    private func appendSyncActivity(kind: String, startDate: Date, endDate: Date = .now, errorText: String?) {
        Self.writeSyncActivity(SyncActivityEntry(kind: kind, startDate: startDate, endDate: endDate, errorText: errorText))
        syncActivity = Self.loadSyncActivity()
    }

    nonisolated private static func loadSyncActivity() -> [SyncActivityEntry] {
        guard let data = UserDefaults.standard.data(forKey: syncActivityKey),
              let entries = try? JSONDecoder().decode([SyncActivityEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Read-merge-write against the defaults, not the in-memory array, so the off-main watchdog
    /// in `createShare` can add a line while the main actor is wedged and nothing overwrites it.
    nonisolated private static func writeSyncActivity(_ entry: SyncActivityEntry) {
        var entries = loadSyncActivity()
        entries.insert(entry, at: 0)
        entries.sort { $0.endDate > $1.endDate }
        if entries.count > syncActivityLimit {
            entries.removeLast(entries.count - syncActivityLimit)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: syncActivityKey)
        }
    }

    func clearSyncActivity() {
        syncActivity = []
        UserDefaults.standard.removeObject(forKey: Self.syncActivityKey)
    }

    var isSyncing: Bool { lastSyncEvents.values.contains { $0.isInFlight } }

    /// The most recent event that ended in an error, if the latest of its type did — a failure
    /// followed by a successful retry of the same kind is not an error.
    var lastSyncError: String? {
        lastSyncEvents.values
            .filter { $0.errorText != nil }
            .max { $0.startDate < $1.startDate }?
            .errorText
    }

    var lastSuccessfulSync: Date? {
        lastSyncEvents.values.filter(\.succeeded).compactMap(\.endDate).max()
    }

    /// One line for a Settings row: "Off" / "Syncing…" / "Failed" / "Synced 2 min ago" / "Waiting…".
    var syncStatusSummary: String {
        guard isCloudKitEnabled else { return "Off" }
        if isSyncing { return "Syncing…" }
        if lastSyncError != nil { return "Failed" }
        if let date = lastSuccessfulSync {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Synced \(formatter.localizedString(for: date, relativeTo: .now))"
        }
        return "Waiting…"
    }

    /// Records every mirroring event the container reports. Separate from the one-shot import
    /// observer `awaitInitialImportThenRetry` installs; this one lives for the whole launch.
    private func observeSyncEvents() {
        guard isCloudKitEnabled, syncEventToken == nil else { return }
        syncEventToken = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event
            else { return }
            let summary = SyncEventSummary(
                type: event.type,
                startDate: event.startDate,
                endDate: event.endDate,
                errorText: event.error.map(Self.describeSyncError)
            )
            guard let self else { return }
            Task { @MainActor in
                self.lastSyncEvents[summary.type] = summary
                if let endDate = summary.endDate {
                    self.appendSyncActivity(
                        kind: Self.name(of: summary.type),
                        startDate: summary.startDate,
                        endDate: endDate,
                        errorText: summary.errorText
                    )
                }
                if let text = summary.errorText {
                    AppLog.sync.error("CloudKit \(Self.name(of: summary.type), privacy: .public) failed: \(text, privacy: .public)")
                }
            }
        }
    }

    private static func name(of type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "event"
        }
    }

    /// Human text plus the domain/code, and the first per-record failure when CloudKit hands back
    /// a partial error — "Failed to modify some records" on its own says nothing.
    nonisolated private static func describeSyncError(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError], !partial.isEmpty {
            // Distinct per-item failures with counts, plus one sample item so the record (and its
            // zone) can be found in the Console. "Failed to modify some records" alone says nothing.
            var counts: [String: (count: Int, sample: String)] = [:]
            for (item, itemError) in partial {
                let key = "\(itemError.localizedDescription) (\(itemError.code))"
                let existing = counts[key]
                counts[key] = (count: (existing?.count ?? 0) + 1, sample: existing?.sample ?? "\(item)")
            }
            let lines = counts.sorted { $0.value.count > $1.value.count }.prefix(4).map { key, value in
                "\(value.count)× \(key) e.g. \(value.sample)"
            }
            text += " — " + lines.joined(separator: "; ")
        }
        // Whatever else CloudKit / Core Data tucked into userInfo (underlying errors, server
        // descriptions, the record ids a mirroring export gave up on) — the keys vary by failure,
        // so dump the lot rather than expand a fixed list. Capped; these can run long.
        let dump = String(describing: nsError.userInfo)
        if dump.count > 2 {
            text += "\nuserInfo: " + String(dump.prefix(2500))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "\nunderlying: \(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    /// A share link that was opened but not yet accepted. Joining replaces this device's own
    /// library, so `ContentView` asks first and then calls `switchShare(to:)` with the metadata it
    /// captured synchronously — see the alert's comment for why it can't read this property later.
    private(set) var pendingShareInvitation: CKShare.Metadata?

    /// Non-nil when `pendingShareInvitation` belongs to a *different* share than the one this
    /// device is already in: the owner's name, for the "this replaces the library you're in"
    /// wording. Nil for the ordinary case (an owner joining their first shared library).
    private(set) var pendingInvitationCurrentOwnerName: String?

    /// A share link tapped by an owner who is already sharing their own library with someone.
    /// Accepting would purge the private store — which holds the share root — and CloudKit would
    /// delete the zone out from under the partner, so the invitation is refused rather than parked.
    private(set) var blockedShareInvitation: CKShare.Metadata?

    /// The name to put in the "Stop Sharing First" alert; nil when CloudKit withheld it.
    var blockedShareInvitationOwnerName: String? {
        blockedShareInvitation?.ownerIdentity.displayName
    }

    /// Set to "the owner stopped sharing and this device fell back to a fresh, empty library of its
    /// own" so `ContentView` can say so instead of the library silently emptying. Nil otherwise.
    var sharingEndedByOwnerName: String?

    /// True while `leaveShare()` is tearing the shared zone down. The purge arrives as a remote
    /// change, and the role rule flipping to owner in the middle of it is indistinguishable from
    /// the owner having revoked the share — without this the user gets told their partner stopped
    /// sharing immediately after they chose to leave.
    private var isLeavingShare = false

    /// When the shared library's first import landed. `RemoteActivityNotifier` suppresses
    /// announcements for a minute afterwards — the bulk import is the library arriving, and the
    /// `isJoiningSharedLibrary` flag clears on the very first transaction of it.
    private(set) var joinCompletedAt: Date?

    /// The partner's latest changes, phrased for people ("Sarah added Elf to Movies"), set by
    /// `RemoteActivityNotifier` when they land while the app is on screen so `ContentView` can
    /// toast them. In the background they become local notifications instead.
    var recentRemoteActivity: [String] = []

    /// The other person's name as a sentence subject for notifications and toasts ("Sarah added
    /// Elf"). iOS may withhold names from apps without the extended share-access entitlement;
    /// the fallback never guesses at the relationship (`CloudKitNames.swift` owns the formatting).
    /// For sentences — the given name. Every notification, toast, Activity line and "Shared with"
    /// caption goes through this; only the Sharing screen's participant rows show full names.
    func otherPersonDisplayName() -> String {
        otherPersonShortName ?? "Someone"
    }

    /// Short form of `otherPersonName`, same resolution order.
    var otherPersonShortName: String? {
        if let name = liveShare?.otherShortDisplayName { return name }
        if role == .participant {
            return UserDefaults.standard.string(forKey: Self.rememberedOwnerShortNameKey)
                ?? UserDefaults.standard.string(forKey: Self.rememberedOwnerNameKey)
        }
        return nil
    }

    /// The other person's name, or nil when nothing knows it. Order: the share (the owner's
    /// device learns the participant's name from the share sheet), then the name remembered from
    /// the invitation — on a participant's device iOS strips the *owner's* name components from
    /// the share, but the `CKShare.Metadata` that opened the app carried it ("Eric Hermanson wants
    /// to collaborate"), so it's kept from that moment. Views read this, not `liveShare` directly.
    var otherPersonName: String? {
        if let name = liveShare?.otherDisplayName { return name }
        if role == .participant { return UserDefaults.standard.string(forKey: Self.rememberedOwnerNameKey) }
        return nil
    }

    private static let rememberedOwnerNameKey = "sharing.rememberedOwnerName"
    private static let rememberedOwnerShortNameKey = "sharing.rememberedOwnerShortName"

    private func rememberOwnerName(from metadata: CKShare.Metadata) {
        let identity = metadata.ownerIdentity
        let name = identity.displayName ?? identity.lookupInfo?.emailAddress
        guard let name, !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: Self.rememberedOwnerNameKey)
        UserDefaults.standard.set(identity.shortDisplayName ?? name, forKey: Self.rememberedOwnerShortNameKey)
    }

    /// "Added by" attribution for the detail sheet, sourced entirely from the CloudKit record
    /// mirror (`creatorUserRecordID` / `creationDate`) — no Core Data attribute backs this, so a
    /// missing record just means nothing renders. Mirrors `RemoteActivityNotifier`'s
    /// `CKCurrentUserDefaultName` convention: that value means "you". Returns nil when no share
    /// is live (nothing to attribute) — matches an unshared owner, which is the "no change from
    /// today" case.
    func attribution(for object: NSManagedObject) -> (name: String, date: Date?)? {
        let share = existingShare()
        guard role == .participant || share != nil else { return nil }
        guard let record = container.record(for: object.objectID),
              let creator = record.creatorUserRecordID
        else { return nil }

        if creator.recordName == CKCurrentUserDefaultName {
            return ("you", record.creationDate)
        }

        let name = share?.participants
            .first { $0.userIdentity.userRecordID?.recordName == creator.recordName }?
            .shortDisplayName ?? (role == .participant ? otherPersonShortName : nil)
        return (name ?? "someone else", record.creationDate)
    }

    /// Entry point for share links (both the running-app and cold-launch paths). Three outcomes:
    /// an owner who is already sharing is told to stop sharing first (accepting would purge the
    /// private store, and with it the share root, emptying the partner's library); a participant
    /// re-tapping the link for the share they're already in accepts silently, having nothing to
    /// lose; everything else is parked for `ContentView` to confirm.
    func receiveShareInvitation(_ metadata: CKShare.Metadata) {
        rememberOwnerName(from: metadata)
        let owner = metadata.ownerIdentity.displayName ?? "unknown owner"
        func note(_ outcome: String) {
            appendSyncActivity(kind: "invite", startDate: .now, errorText: "From \(owner): \(outcome)")
            AppLog.sharing.notice("share invitation from \(owner, privacy: .private): \(outcome, privacy: .public)")
        }
        if role == .owner {
            guard !isSharingLive else {
                blockedShareInvitation = metadata
                note("blocked — this device is already sharing its own watchlist")
                return
            }
            pendingShareInvitation = metadata
            note("parked for the Join alert (owner, not sharing)")
            return
        }

        // Participant, or mid-join. The same link again (or a join whose share isn't readable
        // yet) is a no-op worth accepting straight away; a *different* owner's link replaces the
        // shared library this device is in, which needs the same confirmation an owner gets.
        let currentShare = liveShare ?? existingShare()
        guard let currentShareID = currentShare?.recordID, currentShareID != metadata.share.recordID else {
            note("accepting directly (same share, or join in progress)")
            Task { @MainActor in
                do {
                    try await acceptShare(metadata: metadata)
                } catch {
                    appendSyncActivity(kind: "invite", startDate: .now, errorText: "Accept failed: \(Self.describeSyncError(error))")
                    AppLog.sharing.error("failed to accept CloudKit share: \(error)")
                }
            }
            return
        }

        // Non-nil is the signal `ContentView` keys on; empty means the name was withheld.
        pendingInvitationCurrentOwnerName = currentShare?.ownerDisplayName ?? ""
        pendingShareInvitation = metadata
        note("parked for the Join alert (already in another share)")
    }

    func declinePendingShareInvitation() {
        pendingShareInvitation = nil
        pendingInvitationCurrentOwnerName = nil
    }

    func clearBlockedShareInvitation() {
        blockedShareInvitation = nil
    }

    /// The single "Join" path. Leaves the shared library this device is currently in first —
    /// accepting a second share would land two zones in `sharedStore`, and `reconciledRoot` would
    /// then try to merge across zones this device doesn't own.
    func switchShare(to metadata: CKShare.Metadata) async throws {
        declinePendingShareInvitation()
        if role == .participant {
            try await leaveShare()
        }
        try await acceptShare(metadata: metadata)
    }

    /// What this device's own library holds — shown in the join confirmation so the user knows
    /// exactly what accepting replaces.
    func ownedLibraryCounts() -> (titles: Int, collections: Int) {
        let items = NSFetchRequest<ListItem>(entityName: "ListItem")
        items.predicate = NSPredicate(format: "list != nil")
        items.affectedStores = [privateStore]
        let lists = NSFetchRequest<CustomList>(entityName: "CustomList")
        lists.affectedStores = [privateStore]
        return (
            (try? viewContext.count(for: items)) ?? 0,
            (try? viewContext.count(for: lists)) ?? 0
        )
    }

    /// Accepts an incoming share invitation, discards this device's private data and switches
    /// role to participant. The shared zone is imported asynchronously afterwards, so `group`
    /// stays nil (and `isJoiningSharedLibrary` true) until `RemoteChangeObserver` sees it land.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        guard privateStore != nil, sharedStore != nil else {
            throw PersistenceError.storeUnavailable(storeLoadError)
        }
        rememberOwnerName(from: metadata)
        try await container.acceptShareInvitations(from: [metadata], into: sharedStore)
        // Flipped (and `group` dropped by the role rule) *before* `remoteChangeCount` is bumped,
        // so the view models see "joining, no group" in the same pass and cancel their in-flight
        // work rather than reloading against a store that's being purged underneath them.
        joinCompletedAt = nil
        isJoiningSharedLibrary = true

        // The device is joining someone else's library — anything it had in its own private
        // store is no longer relevant (and shouldn't dangle around unreachable from any group).
        try purgeAllObjects(in: privateStore)
        save()

        try applyRoleRule()
        refreshLiveShare()
        remoteChangeCount += 1
        // Sharing is live from here on — the partner's edits are worth a ping.
        RemoteActivityNotifier.requestPermissionIfNeeded()
    }

    /// Re-applies the role rule after a remote change when the current root can no longer be
    /// trusted: a join is pending, the root is gone (the owner stopped sharing, which deletes the
    /// whole graph from a participant's store), or a second root arrived from another device.
    fileprivate func refreshRoleAfterRemoteChange() {
        var needsRerun = isJoiningSharedLibrary || group == nil
        if let group, group.isDeleted || group.managedObjectContext == nil {
            needsRerun = true
        }
        if !needsRerun, let store = role == .participant ? sharedStore : privateStore {
            let request = NSFetchRequest<WatchListGroup>(entityName: "WatchListGroup")
            request.affectedStores = [store]
            let count = (try? viewContext.count(for: request)) ?? 1
            needsRerun = count != 1
        }
        guard needsRerun else { return }

        // The owner stopping sharing deletes the whole graph out of a participant's shared store,
        // so the rule below quietly reseeds this device as a fresh owner. Capture who it was
        // first — once the share is gone there's nothing left to read the name from.
        let wasParticipant = role == .participant
        let ownerName = liveShare?.ownerDisplayName

        do {
            try applyRoleRule()
        } catch {
            AppLog.persistence.error("role rule failed after a remote change: \(error)")
            return
        }

        if wasParticipant, role == .owner, !isJoiningSharedLibrary, !isLeavingShare {
            // Non-nil presents the alert; empty means the name was withheld ("Sharing Stopped").
            sharingEndedByOwnerName = ownerName ?? ""
        }
    }

    /// Participant only: leaves the share by purging its zone from the shared store, then
    /// re-bootstraps so this device becomes the owner of a fresh, empty library. Owners stop
    /// sharing through `UICloudSharingController` ("Stop Sharing" deletes only the `CKShare`,
    /// keeping the owner's data); purging the zone as the owner would delete their library.
    /// If the owner already stopped sharing there's no zone left to purge — just drop whatever
    /// is still local and start over.
    func leaveShare() async throws {
        guard role == .participant else { throw PersistenceError.notParticipant }
        UserDefaults.standard.removeObject(forKey: Self.rememberedOwnerNameKey)
        UserDefaults.standard.removeObject(forKey: Self.rememberedOwnerShortNameKey)
        isLeavingShare = true
        defer { isLeavingShare = false }
        if let zoneID = existingShare()?.recordID.zoneID {
            try await container.purgeObjectsAndRecordsInZone(with: zoneID, in: sharedStore)
        } else {
            try purgeAllObjects(in: sharedStore)
            save()
        }
        isJoiningSharedLibrary = false
        group = nil
        try bootstrap()
        remoteChangeCount += 1
    }

    // MARK: - Sync repair

    /// The stuck state this repairs: an owner whose root carries a local `CKShare` while the root
    /// record has never been acknowledged by the server. `container.share` moved the graph into a
    /// share zone and created the share, the server never accepted the share record, and every
    /// export since retries it — the whole library sits behind that failure unexported, and the
    /// share sheet spins on `.existing(share)` forever. Seen on the first TestFlight (Production)
    /// launch after months of Development builds.
    func isStuckBehindUnacceptedShare() -> Bool {
        guard isCloudKitEnabled, role == .owner, let group, group.managedObjectContext != nil else { return false }
        guard existingShare() != nil else { return false }
        return container.record(for: group.objectID)?.recordChangeTag == nil
    }

    /// Rebuilds the private store's contents as fresh objects in the default zone and drops the
    /// old graph plus its stale share zone. Local data is the source of truth (nothing of it is on
    /// the server, by definition of the stuck state), so nothing is lost: every attribute and
    /// relationship reachable from the root is deep-copied — titles, watched seasons, ratings,
    /// notes, order, collections, household services. There is no API to move objects *out* of a
    /// share zone, which is why this is a copy and not a fix-up. Owner only.
    func repairSync() async throws {
        guard role == .owner, let oldGroup = group, oldGroup.managedObjectContext != nil else {
            throw PersistenceError.noGroup
        }
        let started = Date.now
        let staleZoneID = existingShare()?.recordID.zoneID
        var copies: [NSManagedObjectID: NSManagedObject] = [:]

        func clone(_ object: NSManagedObject) -> NSManagedObject {
            if let done = copies[object.objectID] { return done }
            let copy = NSEntityDescription.insertNewObject(forEntityName: object.entity.name!, into: viewContext)
            viewContext.assign(copy, to: privateStore)
            copies[object.objectID] = copy
            for name in object.entity.attributesByName.keys {
                copy.setValue(object.value(forKey: name), forKey: name)
            }
            for (name, relationship) in object.entity.relationshipsByName {
                if relationship.isToMany {
                    let targets = (object.value(forKey: name) as? Set<NSManagedObject>) ?? []
                    copy.setValue(NSSet(array: targets.map(clone)), forKey: name)
                } else if let target = object.value(forKey: name) as? NSManagedObject {
                    copy.setValue(clone(target), forKey: name)
                }
            }
            return copy
        }

        let newGroup = clone(oldGroup) as! WatchListGroup
        // A fresh identity: the old root's id may still be referenced by stale share metadata,
        // and `reconciledRoot` keys on it.
        newGroup.id = UUID()
        let copiedCount = copies.count

        // Everything the old graph reached is now duplicated; drop the originals *and* any
        // stragglers in the private store (detail-sheet wrappers, orphaned media rows) — all of
        // it is assigned to the dead zone.
        let keep = Set(copies.values.map(\.objectID))
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.affectedStores = [privateStore]
            request.includesPropertyValues = false
            for object in try viewContext.fetch(request) where !keep.contains(object.objectID) {
                viewContext.delete(object)
            }
        }
        try viewContext.save()
        group = newGroup

        // Server side: the zone the old graph lived in, with its unaccepted share. Failure here
        // is not fatal — the local rebuild already succeeded and the new graph exports to the
        // default zone regardless; a leftover empty zone is harmless.
        var zoneNote = "no stale zone"
        if let staleZoneID {
            do {
                try await container.purgeObjectsAndRecordsInZone(with: staleZoneID, in: privateStore)
                zoneNote = "purged zone \(staleZoneID.zoneName)"
            } catch {
                zoneNote = "zone \(staleZoneID.zoneName) not purged: \(Self.describeSyncError(error))"
                AppLog.sync.error("repair: stale zone purge failed: \(error)")
            }
        }

        try applyRoleRule()
        refreshLiveShare()
        remoteChangeCount += 1
        appendSyncActivity(
            kind: "repair",
            startDate: started,
            errorText: "Rebuilt \(copiedCount) objects into a fresh root; \(zoneNote)."
        )
        AppLog.sync.notice("repair: rebuilt \(copiedCount) objects; \(zoneNote, privacy: .public)")
    }

    // MARK: - Duplicate removal

    /// Collapses a library that got merged with a copy of itself — a second root importing
    /// (e.g. a reset whose zone deletion hadn't propagated) folds its lists into ours via
    /// `mergeDuplicateLists`, so every title appears twice and every collection is doubled. Keeps
    /// the lowest-ordered entry per title per list, merges same-named collections (unique
    /// members only), and drops media rows nothing references anymore. Returns a summary.
    func removeDuplicates() -> String {
        // A second root that arrived after bootstrap may not have been folded in yet — do that
        // first so everything below sees one root, or the duplicates would be invisible to it.
        var mergedRoots = 0
        if role == .owner {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "WatchListGroup")
            request.affectedStores = [privateStore]
            let rootCount = (try? viewContext.count(for: request)) ?? 1
            if rootCount > 1, let winner = try? reconciledRoot(in: privateStore) {
                mergedRoots = rootCount - 1
                group = winner
                ProviderSettings.shared.adoptSelection(from: winner)
            }
        }
        guard let group else { return "no group" }
        var removedItems = 0
        var mergedCollections = 0

        // First, before anything chooses a "keeper": entries whose movie/show row is gone. They
        // can't render and carry no TMDB id to recover — and if they're left in, a copy of a
        // collection made of them can win the merge below over the copy with real rows (that is
        // exactly what emptied a collection once). Age-gated: mid-import an entry can arrive a
        // moment before its media row.
        let droppedEmpty = sweepDanglingEntries(olderThan: 0)

        // Same-named lists ("TV Shows" twice): `reconciledRoot` folds these when it merges roots,
        // but lists that import *after* that pass arrive as extra lists under the one root and
        // never get folded — each holds one clean copy, so a per-list pass would find nothing.
        let listCount = (group.lists ?? []).count
        mergeDuplicateLists(in: group)
        viewContext.processPendingChanges()
        let mergedLists = listCount - (group.lists ?? []).filter { !$0.isDeleted }.count

        for list in (group.lists ?? []) where !list.isDeleted {
            var keptByMedia: [String: ListItem] = [:]
            for item in (list.items ?? []).sorted(by: { $0.order < $1.order }) {
                guard let key = item.movie.map({ "movie:\($0.id)" }) ?? item.tvShow.map({ "tv:\($0.id)" }) else { continue }
                if keptByMedia[key] == nil {
                    keptByMedia[key] = item
                    continue
                }
                let movie = item.movie, tvShow = item.tvShow, itemID = item.objectID
                viewContext.delete(item)
                deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: viewContext)
                removedItems += 1
            }
        }

        let byName = Dictionary(grouping: (group.customLists ?? []).filter { !$0.isDeleted }, by: \.name)
        for lists in byName.values where lists.count > 1 {
            // The keeper is the copy with the most real entries — never a UUID coin-flip that
            // can hand the merge to a hollow copy — then the lowest id for determinism.
            func renderable(_ list: CustomList) -> Int {
                (list.items ?? []).filter { !$0.isDeleted && ($0.movie != nil || $0.tvShow != nil) }.count
            }
            let sorted = lists.sorted {
                let a = renderable($0), b = renderable($1)
                return a != b ? a > b : $0.id.uuidString < $1.id.uuidString
            }
            let keep = sorted[0]
            var keys = Set((keep.items ?? []).compactMap(\.mediaKey))
            for extra in sorted.dropFirst() {
                for item in extra.items ?? [] {
                    if let key = item.mediaKey, keys.insert(key).inserted {
                        item.customList = keep
                    } else {
                        let movie = item.movie, tvShow = item.tvShow, itemID = item.objectID
                        viewContext.delete(item)
                        deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: viewContext)
                        removedItems += 1
                    }
                }
                viewContext.processPendingChanges()
                viewContext.delete(extra)
                mergedCollections += 1
            }
        }
        // Collections can also hold the same title twice after a merge.
        for list in group.customLists ?? [] where !list.isDeleted {
            var seen = Set<String>()
            for item in (list.items ?? []).sorted(by: { $0.addedAt < $1.addedAt }) {
                guard let key = item.mediaKey else { continue }
                if seen.insert(key).inserted { continue }
                let movie = item.movie, tvShow = item.tvShow, itemID = item.objectID
                viewContext.delete(item)
                deleteMediaIfUnreferenced(movie: movie, tvShow: tvShow, ignoring: itemID, in: viewContext)
                removedItems += 1
            }
        }

        save()
        // Media rows nothing points at anymore (imports can leave spares behind too).
        let sweptMedia = sweepUnreferencedMedia()
        remoteChangeCount += 1
        let summary = "Merged \(mergedRoots) extra root(s) and \(mergedLists) duplicate lists; removed \(removedItems) duplicate entries; merged \(mergedCollections) duplicate collections; swept \(sweptMedia) unreferenced media rows; dropped \(droppedEmpty) entries with no title."
        appendSyncActivity(kind: "dedupe", startDate: .now, errorText: summary)
        AppLog.persistence.notice("dedupe: \(summary, privacy: .public)")
        return summary
    }

    // MARK: - Sync reset

    /// Where `resetSync()` parks the library between the store being destroyed and the next
    /// launch restoring it.
    private static var resetSnapshotURL: URL {
        applicationSupportDirectory().appendingPathComponent("sync-reset-snapshot.archive")
    }

    /// The last resort, for a store whose CloudKit mirroring metadata is inconsistent (exports die
    /// with "Cannot create objectID … (entityID)" / "unhandled exception while analyzing
    /// history" and the delegate resets itself every cycle). There is no API to repair that
    /// metadata, so this hands Core Data a store it has never synced from: every object in the
    /// private store is snapshotted to disk, Up Next's zones are deleted on the server (so nothing
    /// stale imports back as duplicates), both store files are destroyed, and the process exits.
    /// `bootstrap()` restores the snapshot on the next launch before anything else runs. Nothing
    /// is lost — it's the same deep copy `repairSync()` makes, via a file. Owner only.
    func resetSync() async throws -> Never {
        guard role == .owner, group != nil else { throw PersistenceError.noGroup }
        let started = Date.now
        let snapshot = try snapshotPrivateStore()
        let privateURL = privateStore.url
        let sharedURL = sharedStore.url

        // Server first, and it must succeed: a fresh store that imports the old zones would
        // rebuild the library twice over.
        var zoneNote = "CloudKit off"
        if isCloudKitEnabled {
            let database = Self.ckContainer.privateCloudDatabase
            let zones = try await database.allRecordZones()
                .filter { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
            for zone in zones {
                try await database.deleteRecordZone(withID: zone.zoneID)
            }
            // Zone deletion is eventually consistent: the first run of this exited immediately
            // and the fresh store's first import fetched the old graph back, duplicating every
            // title. Wait until a fresh zone list no longer shows them.
            let deleted = Set(zones.map(\.zoneID))
            var remaining = deleted
            for _ in 0..<10 where !remaining.isEmpty {
                try await Task.sleep(for: .seconds(2))
                let current = Set(try await database.allRecordZones().map(\.zoneID))
                remaining = deleted.intersection(current)
            }
            zoneNote = remaining.isEmpty
                ? "deleted \(zones.count) zone(s), confirmed gone"
                : "deleted \(zones.count) zone(s) but \(remaining.count) still listed after 20 s"
        }

        try snapshot.write(to: Self.resetSnapshotURL, options: .atomic)
        appendSyncActivity(
            kind: "reset",
            startDate: started,
            errorText: "Snapshotted \(snapshot.count / 1024) KB; \(zoneNote); stores destroyed — restored on next launch."
        )
        AppLog.sync.notice("reset: snapshot written, \(zoneNote, privacy: .public); destroying stores")

        // Forget everything keyed to the old stores.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("historyToken.") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.initialImportSettledKey)
        defaults.removeObject(forKey: Self.pendingSharedJoinKey)

        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        for url in [privateURL, sharedURL].compactMap({ $0 }) {
            try coordinator.destroyPersistentStore(at: url, type: .sqlite, options: nil)
        }
        exit(0)
    }

    /// Every object in the private store — entity, all attributes, relationships as object-URI
    /// lists — archived with secure coding. Attribute values are all plist/Foundation types.
    private func snapshotPrivateStore() throws -> Data {
        var rows: [[String: Any]] = []
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.affectedStores = [privateStore]
            for object in try viewContext.fetch(request) {
                var attributes: [String: Any] = [:]
                for key in entity.attributesByName.keys {
                    if let value = object.value(forKey: key) { attributes[key] = value }
                }
                var relationships: [String: [String]] = [:]
                for (key, relationship) in entity.relationshipsByName {
                    if relationship.isToMany {
                        let targets = (object.value(forKey: key) as? Set<NSManagedObject>) ?? []
                        relationships[key] = targets.map { $0.objectID.uriRepresentation().absoluteString }
                    } else if let target = object.value(forKey: key) as? NSManagedObject {
                        relationships[key] = [target.objectID.uriRepresentation().absoluteString]
                    }
                }
                rows.append([
                    "entity": name,
                    "uri": object.objectID.uriRepresentation().absoluteString,
                    "attributes": attributes,
                    "relationships": relationships,
                ])
            }
        }
        return try NSKeyedArchiver.archivedData(withRootObject: rows as NSArray, requiringSecureCoding: true)
    }

    private func restoreResetSnapshot() throws {
        let started = Date.now
        let url = Self.resetSnapshotURL
        let data = try Data(contentsOf: url)
        let classes: [AnyClass] = [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self,
                                   NSDate.self, NSUUID.self, NSURL.self, NSData.self]
        guard let rows = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [[String: Any]] else {
            throw PersistenceError.storeUnavailable(nil)
        }
        var objects: [String: NSManagedObject] = [:]
        for row in rows {
            guard let entityName = row["entity"] as? String, let uri = row["uri"] as? String else { continue }
            let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: viewContext)
            viewContext.assign(object, to: privateStore)
            for (key, value) in (row["attributes"] as? [String: Any]) ?? [:] {
                object.setValue(value, forKey: key)
            }
            objects[uri] = object
        }
        for row in rows {
            guard let uri = row["uri"] as? String, let object = objects[uri] else { continue }
            for (key, uris) in (row["relationships"] as? [String: [String]]) ?? [:] {
                guard let relationship = object.entity.relationshipsByName[key] else { continue }
                let targets = uris.compactMap { objects[$0] }
                if relationship.isToMany {
                    object.setValue(NSSet(array: targets), forKey: key)
                } else {
                    object.setValue(targets.first, forKey: key)
                }
            }
        }
        try viewContext.save()
        try FileManager.default.removeItem(at: url)
        appendSyncActivity(kind: "restore", startDate: started, errorText: "Restored \(objects.count) objects into a fresh store.")
        AppLog.sync.notice("reset: restored \(objects.count) objects into a fresh store")
    }

    private func purgeAllObjects(in store: NSPersistentStore) throws {
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.affectedStores = [store]
            request.includesPropertyValues = false
            let objects = try viewContext.fetch(request)
            for object in objects {
                viewContext.delete(object)
            }
        }
    }

    enum PersistenceError: LocalizedError {
        case noGroup
        case noShare
        case notParticipant
        case storeUnavailable(Error?)
        case cloudKitDisabled
        case shareTimedOut

        var errorDescription: String? {
            switch self {
            case .cloudKitDisabled:
                "CloudKit is off for this launch (--no-cloudkit)."
            case .shareTimedOut:
                "iCloud hasn’t finished syncing your watchlist, so a share link couldn’t be created yet. Check Settings → About for sync status and try again in a few minutes."
            case .noGroup:
                "Your watchlist hasn’t finished loading yet. Try again in a moment."
            case .noShare:
                "This watchlist isn’t shared."
            case .notParticipant:
                "Only someone who joined a shared watchlist can leave it."
            case .storeUnavailable:
                "Up Next couldn’t open your watchlist on this device."
            }
        }
    }
}

// MARK: - Remote change observation

/// Watches `.NSPersistentStoreRemoteChange` and merges in history authored by other peers
/// (participants, or the same account on another device), ignoring transactions this app itself
/// authored (`transactionAuthor = "app"`). Debounces bursts of notifications into a single
/// `remoteChangeCount` bump.
@MainActor
private final class RemoteChangeObserver {
    private unowned let persistence: PersistenceController
    private var notificationTokens: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    /// Stores whose history has already been pruned this launch — once is plenty, and the delete
    /// is a full table scan of the transaction log.
    private var prunedStores: Set<String> = []

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func start() {
        // The notification carries no payload we act on (it only ever means "go re-check
        // persistent history"), so drop it rather than capture a non-Sendable `Notification`
        // across the actor hop.
        let token = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            // See the matching note in `awaitInitialImportThenRetry`: the weak binding can't be
            // referenced from inside the `Task` under the Swift 6 language mode.
            guard let self else { return }
            Task { @MainActor in
                self.handleRemoteChange()
            }
        }
        notificationTokens.append(token)
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func handleRemoteChange() {
        var foreignTransactions: [NSPersistentHistoryTransaction] = []

        for store in [persistence.privateStore, persistence.sharedStore] {
            guard let store else { continue }
            do {
                foreignTransactions += try processHistory(for: store)
            } catch {
                AppLog.sync.error("failed to process history for \(store.identifier, privacy: .public): \(error)")
            }
        }

        guard !foreignTransactions.isEmpty else { return }
        // Order matters: announce against the role that was current when the changes landed
        // (a join in progress suppresses the bulk import), then let the role rule catch up.
        RemoteActivityNotifier.announce(foreignTransactions, persistence: persistence)
        persistence.refreshRoleAfterRemoteChange()
        persistence.refreshLiveShare()
        // After the role rule, so a reseeded root is the one read: this is how a partner's
        // streaming-service change reaches this device.
        if let group = persistence.group, group.managedObjectContext != nil, !group.isDeleted {
            ProviderSettings.shared.adoptSelection(from: group)
        }
        scheduleRemoteChangeBump()
    }

    private func scheduleRemoteChangeBump() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.persistence.remoteChangeCount += 1
        }
    }

    private func tokenKey(for store: NSPersistentStore) -> String {
        "historyToken.\(store.identifier as String)"
    }

    private func loadToken(for store: NSPersistentStore) -> NSPersistentHistoryToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey(for: store)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private func storeToken(_ token: NSPersistentHistoryToken, for store: NSPersistentStore) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: tokenKey(for: store))
    }

    /// Fetches persistent history for `store` since the last stored token, merges any foreign
    /// (non-"app") transactions into the view context, and advances the stored token to the most
    /// recent transaction regardless of author. Returns the foreign transactions, with their
    /// changes, so they can be announced.
    private func processHistory(for store: NSPersistentStore) throws -> [NSPersistentHistoryTransaction] {
        let context = persistence.viewContext
        let lastToken = loadToken(for: store)

        let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken)
        historyRequest.affectedStores = [store]
        historyRequest.resultType = .transactionsAndChanges

        guard
            let result = try context.execute(historyRequest) as? NSPersistentHistoryResult,
            let allTransactions = result.result as? [NSPersistentHistoryTransaction],
            !allTransactions.isEmpty
        else {
            return []
        }

        let foreignTransactions = allTransactions.filter { $0.author != PersistenceController.transactionAuthor }
        for transaction in foreignTransactions {
            context.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
        }

        // Advance the token to the most recent transaction regardless of author, so the next
        // fetch doesn't re-scan transactions we've already accounted for.
        if let latestToken = allTransactions.last?.token {
            storeToken(latestToken, for: store)
            pruneHistory(for: store)
        }

        return foreignTransactions
    }

    /// Drops transaction history this device has long since merged. Core Data never prunes it on
    /// its own, so without this the log grows for the life of the install. The window is generous
    /// because `NSPersistentCloudKitContainer` finds *its* exports through the same history and
    /// exposes no token to check against: a device that sat offline for a couple of weeks must
    /// still be able to push what it changed. Never fatal — a failed prune just means the log
    /// stays large.
    private func pruneHistory(for store: NSPersistentStore) {
        guard prunedStores.insert(store.identifier).inserted else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
        request.affectedStores = [store]
        do {
            try persistence.viewContext.execute(request)
        } catch {
            AppLog.sync.error("failed to prune history for \(store.identifier, privacy: .public): \(error)")
        }
    }
}
