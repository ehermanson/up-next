# Up Next 2.0 — one shared library (Core Data + CloudKit zone sharing)

Status: in progress on branch `v2-shared-library`. Orchestrated plan; each task lists its owner and the
exact files it may touch. **Do not edit files outside your task's list.**

## Goal

Two people (owner + one participant, different Apple accounts) share the *entire* app: Up Next queues,
watched state, ratings, notes, collections. No personal/private data. Data loss on upgrade is acceptable
(fresh store, no migration). iOS 27 minimum.

## Why Core Data

SwiftData has no CloudKit sharing (confirmed through iOS 27 / WWDC26). `NSPersistentCloudKitContainer`
is Apple's only supported sharing path: `share(_:to:)` moves the whole object graph reachable from a root
object into a share zone, participants mirror it through a second store with `databaseScope = .shared`.

## Architecture

```
Eric (owner)                          iCloud container: iCloud.com.erichermanson.upnext.shared
private.sqlite (.private scope) ◀──▶  private DB ── share zone ── CKShare (exactly one, on WatchListGroup)
                                                        │
Partner (participant)                                   ▼
shared.sqlite (.shared scope)   ◀──▶  shared DB (window into the owner's share zone)
```

- One `NSPersistentCloudKitContainer` with **two stores** (`private.sqlite`, `shared.sqlite`), both with
  `NSPersistentHistoryTrackingKey` + `NSPersistentStoreRemoteChangeNotificationPostOptionKey`.
- **Share root**: `WatchListGroup`. Everything must be reachable from it:
  `group.lists → MediaList.items → ListItem.movie/tvShow → Movie/TVShow.networks → Network`,
  `group.customLists → CustomList.items → CustomListItem.movie/tvShow`.
- **Role rule ("a shared group wins")**: if `shared.sqlite` contains a `WatchListGroup` the device is a
  *participant* (`activeStore = sharedStore`); else if `private.sqlite` contains one it's the *owner*;
  else bootstrap seeds a group + "TV Shows"/"Movies" `MediaList`s into the private store (owner).
  Fetches span both stores; every insert is `assign(_:to: activeStore)`.
- **Relate before save**: Core Data picks a new object's CloudKit zone from its relationships. Every
  new object must be related to the graph (list / group / media row) in the same save it's created.
- **Remote changes → UI**: observe `.NSPersistentStoreRemoteChange`, consume persistent history since
  the last stored token (per store), ignore transactions authored by this app's own context
  (`transactionAuthor = "app"`), and bump `PersistenceController.remoteChangeCount` (observable).
  View models reload from the store when it changes, preserving any pending undo-able deletion.
- **Merge policy**: `NSMergeByPropertyObjectTrumpMergePolicy` (last writer wins). No dedup pass.
- **Detail-sheet transient `ListItem`** (Discover / collections / similar titles): inserted into
  `viewContext` + `activeStore` with `list == nil`, deleted on disappear (same design as today). Library
  fetches filter `list != nil`.
- **Unattached value objects**: `TMDBService.mapToMovie/mapToTVShow` and search/discover results create
  `Movie`/`TVShow`/`Network` with `insertInto: nil`. They become persistent only via
  `canonicalMovieRow/canonicalTVShowRow` (which insert the row *and its networks*) or `update(from:)`
  (which inserts incoming networks into the persisted row's context before assigning).

## Entity spec (`Up Next/Up Next.xcdatamodeld`, manual codegen, `@objc(<Name>)` classes)

All attributes optional or defaulted; all relationships optional with inverses; no ordered relationships,
no uniqueness constraints (CloudKit rules). Model names for collection-typed / optional-number storage
carry a suffix; the Swift class exposes the **current** API names as computed properties so call sites
don't change.

| Entity | Attributes (model name → type) | Swift API (unchanged names) |
|---|---|---|
| `Movie` | `id` String "", `title` String "", `thumbnailURL` URI?, `backdropPath` String?, `descriptionText` String?, `castRaw` Transformable [String]?, `castImagePathsRaw` Transformable, `castCharactersRaw` Transformable, `genresRaw` Transformable, `providerCategoriesRaw` Transformable [Int:String]?, `contentRating` String?, `releaseDate` String?, `runtimeNumber` Int64?, `voteAverageNumber` Double? | `cast: [String]`, `castImagePaths`, `castCharacters`, `genres`, `providerCategories: [Int:String]`, `runtime: Int?`, `voteAverage: Double?` |
| `TVShow` | as Movie minus runtime, plus `numberOfSeasonsNumber`, `numberOfEpisodesNumber`, `seasonEpisodeCountsRaw` [Int], `seasonDescriptionsRaw` [String], `episodeRunTimeNumber`, `nextEpisodeAirDate` String?, `nextEpisodeSeasonNumber`, `nextEpisodeNumberNumber`, `nextEpisodeName` String?, `status` String? | `numberOfSeasons: Int?`, `numberOfEpisodes`, `seasonEpisodeCounts: [Int]`, `seasonDescriptions`, `episodeRunTime`, `nextEpisodeSeason`, `nextEpisodeNumber` |
| `Network` | `id` Int64 0, `name` String "", `logoPath` String?, `originCountry` String? | — |
| `MediaList` | `name` String "", `createdAt` Date | — |
| `ListItem` | `addedAt` Date, `isWatched` Bool false, `watchedAt` Date?, `droppedAt` Date?, `order` Int64 0, `watchedSeasonsRaw` [Int], `userRatingNumber` Int64?, `userNotes` String? | `watchedSeasons: [Int]`, `userRating: Int?` |
| `CustomList` | `id` UUID, `name` String "", `iconName` String "list.bullet", `createdAt` Date | — |
| `CustomListItem` | `addedAt` Date, `watchedAt` Date? | `isWatched`, `toggleWatched()` |
| `WatchListGroup` | `createdAt` Date | — |

Relationships (model name → Swift computed name):

| From | Model | To | Inverse (model) | Delete rule | Swift API |
|---|---|---|---|---|---|
| Movie | `networkSet` | Network (many) | `Network.movieSet` | Nullify | `networks: [Network]?` |
| TVShow | `networkSet` | Network (many) | `Network.tvShowSet` | Nullify | `networks: [Network]?` |
| Movie | `listItemSet` | ListItem (many) | `ListItem.movie` | Nullify | `listItems: [ListItem]?` |
| Movie | `customListItemSet` | CustomListItem (many) | `CustomListItem.movie` | Nullify | `customListItems` |
| TVShow | `listItemSet` / `customListItemSet` | … | `ListItem.tvShow` / `CustomListItem.tvShow` | Nullify | same |
| ListItem | `movie`, `tvShow` (to-one) | — | above | Nullify | `movie`, `tvShow` |
| ListItem | `list` (to-one) | MediaList | `MediaList.itemSet` | Nullify | `list` |
| MediaList | `itemSet` | ListItem (many) | `ListItem.list` | **Cascade** | `items: [ListItem]?` |
| MediaList | `group` (to-one) | WatchListGroup | `WatchListGroup.listSet` | Nullify | `group` |
| CustomList | `itemSet` | CustomListItem (many) | `CustomListItem.customList` | **Cascade** | `items` |
| CustomList | `group` (to-one) | WatchListGroup | `WatchListGroup.customListSet` | Nullify | `group` |
| CustomListItem | `movie`, `tvShow`, `customList` (to-one) | … | above | Nullify | same |
| WatchListGroup | `listSet`, `customListSet` | many | above | **Cascade** | `lists`, `customLists` |

Deleted entities: `UserIdentity` (and `MediaList.createdBy`, `ListItem.addedBy`, `WatchListGroup.members`).
Deleted file: `Up Next/Watch_List.xcdatamodeld` (legacy stub).

Transformables use `NSSecureUnarchiveFromDataTransformer` (arrays/dicts of String/Int are plist types).

## API contracts

### Models (`Up Next/Models/*.swift`)

- Each class: `@objc(Movie) final class Movie: NSManagedObject, MediaItemProtocol`.
- Convenience inits keep today's labels and add a trailing `context: NSManagedObjectContext? = nil`,
  e.g. `Movie(id:title:thumbnailURL:backdropPath:networks:…, context:)`, `ListItem(tvShow:list:…)`,
  `CustomList(name:iconName:)`, `CustomListItem(movie:tvShow:customList:addedAt:watchedAt:)`,
  `MediaList(name:createdAt:)`, `WatchListGroup()`. `nil` context → `NSManagedObject(entity:insertInto: nil)`
  using `PersistenceController.entity(named:)`.
- `MediaItemProtocol` unchanged (`id`, `title`, `thumbnailURL`, `networks: [Network]?`,
  `providerCategories`, `descriptionText`, `cast`, `castImagePaths`, `castCharacters`, `genres`, `voteAverage`).
- Free functions in `MediaItem.swift` keep their signatures but take `NSManagedObjectContext` and
  `NSManagedObjectID`: `existingMovie(id:in:)`, `existingTVShow`, `canonicalMovieRow(for:in:)`,
  `canonicalTVShowRow`, `deleteUnreferencedNetworks(_:excludingOwner:in:)`, `deleteMediaIfUnreferenced(movie:tvShow:ignoring:in:)`,
  `displayOrderedNetworks(_:categories:)`. `canonical*Row` inserts a not-yet-stored row and its networks into
  the context (assigned to `PersistenceController.shared.activeStore`).
- Identity comparisons use `===` (same context ⇒ uniqued) — never compare temporary `objectID`s.
- **Context inference**: Core Data raises "relationship between objects in different contexts" when a
  context-less object is related to a stored one. So `ListItem`, `CustomListItem`, `CustomList` and
  `MediaList` inits join the context *and store* of any persisted object passed to them
  (`inferredContext` / `assignToStore` in `MediaItem.swift`), and `CustomList`/`MediaList` take `group:`
  in the init. Rule: pass relationship targets to the init; never set a relationship to a stored object
  on an object whose `managedObjectContext` is nil.

### PersistenceController (`Up Next/Services/PersistenceController.swift`)

```swift
@MainActor @Observable final class PersistenceController {
    static let shared: PersistenceController
    static let containerIdentifier = "iCloud.com.erichermanson.upnext.shared"
    let container: NSPersistentCloudKitContainer
    var viewContext: NSManagedObjectContext { get }
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!
    enum Role { case owner, participant }
    private(set) var role: Role
    var activeStore: NSPersistentStore { get }            // per the role rule
    private(set) var remoteChangeCount: Int              // bumped on foreign-authored history
    private(set) var group: WatchListGroup!              // the share root (fetched or seeded); NIL while isJoiningSharedLibrary
    var isJoiningSharedLibrary: Bool                     // accepted a share, shared zone not imported yet → show a "Joining…" placeholder, don't seed
    func bootstrap() throws                              // detect role, seed if needed (the 1.x SwiftData store is left in place, untouched)
    func list(named: String) -> MediaList?               // "TV Shows" / "Movies" from group.lists
    func insert(_ object: NSManagedObject)               // viewContext.insert + assign(to: activeStore)
    func save()                                          // save if hasChanges; log on failure
    func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>) -> [T]
    static func entity(named: String) -> NSEntityDescription
    // Sharing
    func existingShare() -> CKShare?
    func createShare() async throws -> CKShare           // owner: container.share([group], to: nil)
    func acceptShare(metadata: CKShare.Metadata) async throws   // participant; sets isJoiningSharedLibrary, purges private store
    func leaveShare() async throws                       // participant only: purge zone from shared store, re-bootstrap as fresh owner
    // Owner "Stop Sharing" goes through UICloudSharingController (deletes only the CKShare, keeps the owner's data).
}
```

View models must tolerate `group == nil` (joining state): load empty arrays, and `ContentView` shows a
"Joining shared library…" placeholder until `remoteChangeCount` changes and `group` is set.

`bootstrap()` runs before any view model configures. In DEBUG it may point at an in-memory/`-testing` path
if launched with `-screenshots` (keep the existing DEBUG screenshot mode working).

### View models

- `MediaLibraryViewModel.configure(persistence:)` replaces `configure(modelContext:)`; `CustomListViewModel`
  likewise. Both keep their public API otherwise (`addTVShow`, `addMovie`, `toggleWatched`, `deleteItem`,
  `undoLastDeletion`, `reorder`, `refreshNow`, `createList`, `addItem(movie:tvShow:to:)`, `removeItem`, …).
- New: `reloadFromStore()` on both — re-fetches arrays; keeps `pendingDeletion` / `pendingRemoval` out of the
  visible arrays. Called by `ContentView` on `persistence.remoteChangeCount` change.
- Drop `UserIdentity` handling entirely. Lists are `persistence.group.lists` by name (seeded in bootstrap).
- `CustomListViewModel.createList` sets `list.group = persistence.group`.
- `migrateDuplicateMediaRows` is deleted (fresh store).

### Views

- Views that take a model object and read its properties use `@ObservedObject` (`NSManagedObject` is an
  `ObservableObject`): `MediaListRow`/`UpcomingEntry` consumers, `MediaDetailView.listItem`
  (`@ObservedObject var listItem: ListItem` instead of `@Binding`), collection rows, `CustomListDetailView`.
- `.modelContainer` / `@Environment(\.modelContext)` → `.environment(\.managedObjectContext, …)` +
  `PersistenceController.shared`.
- Previews build objects with `context: nil`.

### Sharing (Task F)

- `Info.plist.template`: `CKSharingSupported = true`, `UIBackgroundModes = [remote-notification]`.
- `App/AppDelegate.swift`: `UIApplicationDelegate` (`configurationForConnecting` → `SceneDelegate`) and
  `SceneDelegate: UIWindowSceneDelegate` implementing `windowScene(_:userDidAcceptCloudKitShareWith:)` →
  `persistence.acceptShare(metadata:)`. `Watch_ListApp` adds `@UIApplicationDelegateAdaptor`.
- `Services/SharingManager.swift` (or inside PersistenceController): fetch-or-create the single `CKShare` on
  `group` (`container.share([group], to: nil)` then `persistUpdatedShare`), `stopSharingOrLeave` →
  `purgeObjectsAndRecordsInZone`. On accept: `acceptShareInvitations(from:into: sharedStore)`, purge every
  object in the private store, set `role = .participant`, bump `remoteChangeCount`.
- `UI/CloudSharingView.swift`: `UIViewControllerRepresentable` over `UICloudSharingController(share:container:)`.
- `Views/Settings/SharingSettingsView.swift` + a "Sharing" section at the top of `ProviderSettingsView`:
  owner-unshared → "Share with a partner" (`ShareLink` with `CKShareTransferRepresentation(exporter:)`);
  owner-shared → participants summary + "Manage" (CloudSharingView) ; participant → "Shared by <owner>" +
  "Leave". Partner display name (for attribution) is a `@AppStorage("sharing.partnerName")` string.

## Tasks

| ID | Owner | Depends on | Files | Done when |
|---|---|---|---|---|
| A | agent (sonnet) | — | `Up Next/Up Next.xcdatamodeld/**`, `Up Next/Models/*.swift`, delete `Watch_List.xcdatamodeld` | Entities match the spec; classes expose the current API; `MediaItem.swift` helpers ported |
| B | agent (sonnet) | — | `Services/PersistenceController.swift` (new), `App/AppDelegate.swift` (new), `Up Next.entitlements`, `Info.plist.template` | Stack loads two stores, role rule, history-based remote change, bootstrap seeding |
| C | agent (sonnet) | A, B | `ViewModels/MediaLibraryViewModel.swift` | Ported per contract, `reloadFromStore`, no SwiftData imports |
| D | agent (sonnet) | A, B | `ViewModels/CustomListViewModel.swift`, `Views/Lists/*.swift` | Ported; collection rows `@ObservedObject`; transient detail item via `persistence.insert` |
| E | agent (sonnet) | A, B | `App/Watch_ListApp.swift`, `App/ContentView.swift`, `Views/Watchlist/*.swift`, `Views/Detail/*.swift`, `Views/Search/*.swift`, `Views/Discover/*.swift`, `UI/*.swift`, `Services/TMDBService.swift` | No `SwiftData` imports remain; `@ObservedObject` conversions; previews compile |
| G | orchestrator | C, D, E | anything | `xcodebuild` green; app runs in Simulator single-user |
| F | agent (sonnet) | G | sharing files listed above, `Views/Settings/ProviderSettingsView.swift` | Share create / accept / manage / leave wired; role switches |
| H | agent (haiku) | F | `CLAUDE.md`, `README.md` | Docs describe the Core Data stack, sharing, new container, setup steps |
| I | user + orchestrator | F | CloudKit Console, two devices | Schema deployed to Production; two-device test matrix passes |

### Verification command (from repo root)

```bash
xcodebuild build -project "Up Next.xcodeproj" -scheme "Watch List" \
  -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

The build is expected to be red until tasks A–E are all merged; agents on C/D/E should still run it and
make sure **no errors originate in their own files**.

## User action items

1. Xcode → target → Signing & Capabilities → iCloud → add container `iCloud.com.erichermanson.upnext.shared`
   (registers it with the App ID for local and Xcode Cloud signing).
2. After task G: run the app once in DEBUG on a device to let `initializeCloudKitSchema` build the
   Development schema, then deploy it to Production in CloudKit Console **before** any TestFlight build.
3. Two-device test matrix (task I).

## Two-device test matrix (task I)

Owner → partner and partner → owner, each: add title (search, Discover, similar), delete + undo, mark
watched / season toggles / drop / pick back up, rating + notes, reorder, create/rename/delete collection,
add/remove collection item, collection watched toggle, mark-all-unwatched. Then: offline edits on both →
reconnect; owner stops sharing → partner sees an empty library and becomes an owner of a fresh one;
re-share → re-accept.

Also: accept the share link with the partner's app **terminated** (cold launch path) and with it already
running; edit rating/notes in a detail sheet, background the app without closing the sheet, force-quit,
relaunch → edits present; install on a second device of the owner's account *before* it has synced and
confirm one root + one "TV Shows"/"Movies" list afterwards (Settings → Share still shares everything).
