import CloudKit
import CoreData
import Foundation
import OSLog

/// Owns the single `NSPersistentCloudKitContainer` for the shared-library store (see
/// `docs/v2-shared-library-plan.md`). Two stores live under one container: `private.sqlite`
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

        try applyRoleRule()
        sweepOrphanedDetailWrappers()
        refreshLiveShare()
        Task { await refreshAccountStatus() }

        if remoteChangeObserver == nil {
            remoteChangeObserver = RemoteChangeObserver(persistence: self)
            remoteChangeObserver?.start()
        }
    }

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

    func refreshAccountStatus() async {
        guard isCloudKitEnabled else {
            isCloudAccountAvailable = false
            return
        }
        let status = try? await Self.ckContainer.accountStatus()
        isCloudAccountAvailable = status == .available
    }

    /// Creates (and returns) the single `CKShare` rooted at `group`.
    func createShare() async throws -> CKShare {
        guard let group else {
            throw PersistenceError.noGroup
        }
        let (_, share, _) = try await container.share([group], to: nil)
        return share
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

    /// The other person's name for notifications and toasts: the owner's name for a participant,
    /// the first non-owner participant's for an owner. iOS may withhold names from apps without
    /// the extended share-access entitlement, hence the fallback (`CloudKitNames.swift` owns the
    /// formatting).
    func partnerDisplayName() -> String {
        let fallback = "Your partner"
        guard let share = existingShare() else { return fallback }
        return share.otherDisplayName ?? fallback
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
            .displayName
        return (name ?? "your partner", record.creationDate)
    }

    /// Entry point for share links (both the running-app and cold-launch paths). Three outcomes:
    /// an owner who is already sharing is told to stop sharing first (accepting would purge the
    /// private store, and with it the share root, emptying the partner's library); a participant
    /// re-tapping the link for the share they're already in accepts silently, having nothing to
    /// lose; everything else is parked for `ContentView` to confirm.
    func receiveShareInvitation(_ metadata: CKShare.Metadata) {
        if role == .owner {
            guard !isSharingLive else {
                blockedShareInvitation = metadata
                return
            }
            pendingShareInvitation = metadata
            return
        }

        // Participant, or mid-join. The same link again (or a join whose share isn't readable
        // yet) is a no-op worth accepting straight away; a *different* owner's link replaces the
        // shared library this device is in, which needs the same confirmation an owner gets.
        let currentShare = liveShare ?? existingShare()
        guard let currentShareID = currentShare?.recordID, currentShareID != metadata.share.recordID else {
            Task { @MainActor in
                do {
                    try await acceptShare(metadata: metadata)
                } catch {
                    AppLog.sharing.error("failed to accept CloudKit share: \(error)")
                }
            }
            return
        }

        pendingInvitationCurrentOwnerName = currentShare?.ownerDisplayName ?? "your partner"
        pendingShareInvitation = metadata
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
            sharingEndedByOwnerName = ownerName ?? "Your partner"
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

        var errorDescription: String? {
            switch self {
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
