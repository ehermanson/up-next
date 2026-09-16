import CloudKit
import CoreData
import Foundation

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

    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!
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

        Self.loadStores(container: container, screenshotMode: screenshotMode)

        self.container = container

        let coordinator = container.persistentStoreCoordinator
        self.privateStore = coordinator.persistentStore(for: privateDescription.url!)
        self.sharedStore = coordinator.persistentStore(for: sharedDescription.url!)

        let viewContext = container.viewContext
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        viewContext.transactionAuthor = PersistenceController.transactionAuthor
        viewContext.name = "viewContext"
    }

    /// Loads both persistent stores synchronously. If a CloudKit-backed load fails, retries once
    /// per description with CloudKit options removed (local-only fallback) — mirrors the spirit
    /// of the previous `Watch_ListApp` SwiftData fallback.
    private static func loadStores(container: NSPersistentCloudKitContainer, screenshotMode: Bool) {
        // `loadPersistentStores` invokes its completion once per description in
        // `persistentStoreDescriptions` — potentially concurrently, on background queues — so
        // mutations to `pendingRetries` are serialized with a lock rather than called in a loop
        // (which would instead reload every description N times).
        let lock = NSLock()
        var pendingRetries: [NSPersistentStoreDescription] = []
        let group = DispatchGroup()

        for _ in container.persistentStoreDescriptions {
            group.enter()
        }
        container.loadPersistentStores { loadedDescription, error in
            if let error {
                print("⚠️ PersistenceController: failed to load store at \(loadedDescription.url?.path ?? "?"): \(error)")
                if loadedDescription.cloudKitContainerOptions != nil {
                    lock.lock()
                    pendingRetries.append(loadedDescription)
                    lock.unlock()
                }
            }
            group.leave()
        }
        group.wait()

        guard !pendingRetries.isEmpty else { return }

        for description in pendingRetries {
            print("⚠️ PersistenceController: retrying \(description.url?.path ?? "?") as local-only (CloudKit disabled)")
            description.cloudKitContainerOptions = nil
            group.enter()
            container.persistentStoreCoordinator.addPersistentStore(with: description) { _, error in
                if let error {
                    print("⚠️ PersistenceController: local-only fallback also failed for \(description.url?.path ?? "?"): \(error)")
                }
                group.leave()
            }
            group.wait()
        }
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
        try applyRoleRule()

        if remoteChangeObserver == nil {
            remoteChangeObserver = RemoteChangeObserver(persistence: self)
            remoteChangeObserver?.start()
        }
    }

    private func applyRoleRule() throws {
        let sharedRequest = NSFetchRequest<WatchListGroup>(entityName: "WatchListGroup")
        sharedRequest.affectedStores = [sharedStore]
        if let existing = try viewContext.fetch(sharedRequest).first {
            role = .participant
            group = existing
            isJoiningSharedLibrary = false
            return
        }

        // Accepted a share, import not landed yet: stay a participant with no group rather than
        // seeding. `RemoteChangeObserver` re-runs this rule when the shared store changes.
        if isJoiningSharedLibrary {
            role = .participant
            group = nil
            return
        }

        let privateRequest = NSFetchRequest<WatchListGroup>(entityName: "WatchListGroup")
        privateRequest.affectedStores = [privateStore]
        if let existing = try viewContext.fetch(privateRequest).first {
            role = .owner
            group = existing
            return
        }

        // Nothing found in either store: seed a fresh group + default lists into the private
        // store and become the owner.
        role = .owner
        let newGroup = WatchListGroup(context: viewContext)
        viewContext.assign(newGroup, to: privateStore)

        let tvList = MediaList(name: "TV Shows", createdAt: .now, context: viewContext)
        tvList.group = newGroup
        viewContext.assign(tvList, to: privateStore)

        let movieList = MediaList(name: "Movies", createdAt: .now, context: viewContext)
        movieList.group = newGroup
        viewContext.assign(movieList, to: privateStore)

        try viewContext.save()
        group = newGroup
    }

    func list(named name: String) -> MediaList? {
        group?.lists?.first { $0.name == name }
    }

    // MARK: - CRUD helpers

    func insert(_ object: NSManagedObject) {
        viewContext.insert(object)
        viewContext.assign(object, to: activeStore)
    }

    func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            print("⚠️ PersistenceController: save failed: \(error)")
        }
    }

    func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>) -> [T] {
        do {
            return try viewContext.fetch(request)
        } catch {
            print("⚠️ PersistenceController: fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Sharing

    /// The CloudKit container backing this app's stack. `nonisolated` for the same reason as
    /// `containerIdentifier` above — the sharing exporter reads it off the main actor.
    nonisolated static var ckContainer: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    /// The single share on `group`, if one exists.
    func existingShare() -> CKShare? {
        guard let group else { return nil }
        guard let shares = try? container.fetchShares(matching: [group.objectID]) else { return nil }
        return shares[group.objectID]
    }

    /// Creates (and returns) the single `CKShare` rooted at `group`.
    func createShare() async throws -> CKShare {
        guard let group else {
            throw PersistenceError.noGroup
        }
        let (_, share, _) = try await container.share([group], to: nil)
        return share
    }

    /// Accepts an incoming share invitation, discards this device's private data and switches
    /// role to participant. The shared zone is imported asynchronously afterwards, so `group`
    /// stays nil (and `isJoiningSharedLibrary` true) until `RemoteChangeObserver` sees it land.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        try await container.acceptShareInvitations(from: [metadata], into: sharedStore)
        isJoiningSharedLibrary = true

        // The device is joining someone else's library — anything it had in its own private
        // store is no longer relevant (and shouldn't dangle around unreachable from any group).
        try purgeAllObjects(in: privateStore)
        save()

        try applyRoleRule()
        remoteChangeCount += 1
    }

    /// Re-applies the role rule after the shared store changed — used to finish a pending join.
    fileprivate func refreshRoleAfterRemoteChange() {
        guard isJoiningSharedLibrary else { return }
        try? applyRoleRule()
    }

    /// Participant only: leaves the share by purging its zone from the shared store, then
    /// re-bootstraps so this device becomes the owner of a fresh, empty library. Owners stop
    /// sharing through `UICloudSharingController` ("Stop Sharing" deletes only the `CKShare`,
    /// keeping the owner's data); purging the zone as the owner would delete their library.
    func leaveShare() async throws {
        guard role == .participant else { throw PersistenceError.notParticipant }
        guard let zoneID = existingShare()?.recordID.zoneID else {
            throw PersistenceError.noShare
        }
        try await container.purgeObjectsAndRecordsInZone(with: zoneID, in: sharedStore)
        isJoiningSharedLibrary = false
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

    enum PersistenceError: Error {
        case noGroup
        case noShare
        case notParticipant
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
            Task { @MainActor in
                self?.handleRemoteChange()
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
        var didFindForeignTransaction = false

        for store in [persistence.privateStore, persistence.sharedStore] {
            guard let store else { continue }
            do {
                if try processHistory(for: store) {
                    didFindForeignTransaction = true
                }
            } catch {
                print("⚠️ PersistenceController: failed to process history for \(store): \(error)")
            }
        }

        guard didFindForeignTransaction else { return }
        persistence.refreshRoleAfterRemoteChange()
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
    /// recent transaction regardless of author. Returns whether any foreign transaction was found.
    private func processHistory(for store: NSPersistentStore) throws -> Bool {
        let context = persistence.viewContext
        let lastToken = loadToken(for: store)

        let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken)
        historyRequest.affectedStores = [store]

        guard
            let result = try context.execute(historyRequest) as? NSPersistentHistoryResult,
            let allTransactions = result.result as? [NSPersistentHistoryTransaction],
            !allTransactions.isEmpty
        else {
            return false
        }

        let foreignTransactions = allTransactions.filter { $0.author != PersistenceController.transactionAuthor }
        for transaction in foreignTransactions {
            context.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
        }

        // Advance the token to the most recent transaction regardless of author, so the next
        // fetch doesn't re-scan transactions we've already accounted for.
        if let latestToken = allTransactions.last?.token {
            storeToken(latestToken, for: store)
        }

        return !foreignTransactions.isEmpty
    }
}
