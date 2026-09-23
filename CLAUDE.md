# CLAUDE.md

Rules and map for working in this repo. Rationale for *why* code is shaped the way it is lives in doc comments next to the code — keep it there, not here. Update this file when the file map, a rule, a build/setup step, or a config option changes; also update README when user-visible behavior changes.

## Project

**Up Next** — native iOS app (Swift/SwiftUI, iOS 26.1+) for movie/TV watchlists, shareable with one other Apple Account. TMDB for metadata. No accounts, analytics, ads, or third-party dependencies.

- Xcode project `Up Next.xcodeproj`, scheme `Up Next`, bundle id `com.erichermanson.upnext`, `MARKETING_VERSION` managed by hand in `project.pbxproj`.
- **Concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES` — everything unannotated is `@MainActor`. That's why `TMDBService`'s caches need no locking and why `nonisolated` markers in models/services are deliberate. `nonisolated async` still runs on the caller's actor; use `@concurrent` for real background work.
- **Logging**: `AppLog.<category>` (`Services/AppLog.swift`). No `print`.
- **Persistence**: Core Data via `NSPersistentCloudKitContainer`, two stores (private + shared scope), container `iCloud.com.erichermanson.upnext.shared`.
- **Tests**: no Xcode test target. Python unittest for the collection-recommendation harness; `swiftc` runtime checks in `experiments/*/RuntimeChecks.swift` (see their READMEs).

## Setup

1. Xcode → target → Signing & Capabilities → iCloud → add container `iCloud.com.erichermanson.upnext.shared`.
2. `cp "Up Next/Info.plist.template" "Up Next/Info.plist"` and fill in `TMDB_API_KEY` (and optionally `TYPESAFE_API_KEY`). `Info.plist` is gitignored.
3. Unsigned Simulator builds (`CODE_SIGNING_ALLOWED=NO`) must launch with `--no-cloudkit` — CloudKit traps without the entitlement.

## Architecture

MVVM. Three `@Observable` view models own logic; views are thin. `TMDBService` and `PersistenceController` (`@MainActor @Observable`) are singletons; the latter owns the container, both stores, bootstrap (role detection, share acceptance, seeding) and remote-change tracking. No DI: `MediaLibraryViewModel` / `CustomListViewModel` are `@State` in `ContentView` and passed down; `DiscoverViewModel` is owned by `DiscoverView`; the context is `.environment(\.managedObjectContext, …)`. View models call `reloadFromStore()` when `PersistenceController.remoteChangeCount` changes.

| Tab | View | ViewModel |
|-----|------|-----------|
| TV Shows / Movies | `MediaListView` (via `WatchlistTabView`) | `MediaLibraryViewModel` |
| Collections | `MyListsView` | `CustomListViewModel` |
| Discover | `DiscoverView` | `DiscoverViewModel` |

## File Map

```
Up Next/
├── App/
│   ├── Watch_ListApp.swift        @main; bootstraps PersistenceController; applies appearance
│   ├── AppDelegate.swift          App/Scene delegates (CloudKit share links); LightModeControlAppearance
│   ├── ContentView.swift          Tabs; owns Settings sheet, onboarding sheet, legacy-import offer, all sharing alerts
│   └── ScreenshotMode.swift       DEBUG --screenshots demo seed
├── Models/                        Core Data subclasses (@objc)
│   ├── MediaItem.swift            Movie, TVShow, Network; canonical row lookup; context inference; season availability
│   ├── ListItem.swift             Watchlist entry: watched/seasons/watching/dropped state, WatchState undo snapshot
│   ├── MediaList.swift            "TV Shows" / "Movies" containers
│   ├── CustomList.swift / CustomListItem.swift   Collections; item has its own watchedAt
│   ├── WatchListGroup.swift       Share root; household selectedProviderIDsRaw; activitySet
│   └── ActivityEvent.swift        Shared activity log entry (kind/title/mediaKey/contextName/actorName/actorRecordName) on the root; sentence(actor:)
├── ViewModels/
│   ├── MediaLibraryViewModel.swift  Library state, add/remove (queued mid-join), refresh, reorder, reloadFromStore
│   ├── DiscoverViewModel.swift      Carousels, browse, provider filter, in-tab search
│   └── CustomListViewModel.swift    Collection CRUD, per-collection watched, undo-able removal, changeToken
├── Views/
│   ├── Watchlist/   MediaListView (list/grid, filters, toolbar), WatchlistTabView (shell), TVShowsTabView, MoviesTabView, MediaListHelpers (ordering, filterItems, upcomingEntries), SharePitchCard
│   ├── Detail/      MediaDetailView (shell), PrimaryAddPill (status pill + ellipsis menu), HeaderImageView, MediaDetailSections, MediaDetailCards (SeasonChecklistCard, UserRatingCard, …), MediaDetailMetadata (DetailProviderRow, AddedByCaption), MediaDetailSimilar (More Like This, MediaIDKey), SeasonRatingsSnapshot, SeasonEpisodesView, MediaDetailView+Previews
│   ├── Search/      WatchlistSearchView (add sheet), RecommendationEngine, CollectionRecommendationEngine, SearchComponents (rows, shimmer, MediaType)
│   ├── Discover/    DiscoverView
│   ├── Lists/       MyListsView, CustomListDetailView, CollectionSuggestionsView, CreateListView
│   └── Settings/    SettingsView (root), ActivityView (shared activity log), ProviderSettingsView (+ RegionPickerView), SharingSettingsView, LegacyImportView, SyncActivityView (About → iCloud Sync: log, Check, Repair, Reset, Copy Core Data Log)
├── Services/
│   ├── PersistenceController.swift  Container, role rule, remote-change history, sharing API, store-load failure, history pruning
│   ├── RemoteActivityNotifier.swift Imported ActivityEvents from the other account → toast / local notification
│   ├── CloudKitNames.swift          Participant display names / initials — the one place names are formatted
│   ├── ProviderSettings.swift       Selected services (mirror of the group), region override, device-local flags, StorageKey
│   ├── TMDBService.swift            TMDB client: search, details, providers, discover, aliases, retries, response cache
│   ├── TMDBModels.swift             Codable TMDB types
│   ├── SearchRanking.swift          Client-side re-rank of /search
│   ├── JevRecommendationService.swift  TypeSafe/Jev scoring client with disk cache + TMDB fallback
│   ├── LegacyStoreReader.swift / LegacyImporter.swift   1.x SQLite reader + one-time importer
│   ├── AppAppearance.swift          Dark (default) / Light / System
│   └── AppLog.swift
├── UI/              DesignTokens (radii, spacing, surfaces, Chip), AppBackground (mesh), Motion (springs, checkmarkPop), SectionHeader, MediaCardView, NetworkLogosView, CachedAsyncImage, ImageColor (dominantTint), SharedViews (toast, EmptyStateView, StarRatingLabel, AirDateFormat), PosterMosaicView, SettingsToolbarButton, SFSymbolPickerGrid, CloudSharingView, SafariView, TMDBAttributionView
├── Up Next.xcdatamodeld/   Versions: `Up Next 2.1-activity` (current), `2.0-services`, `2.0-release`, `2.0-dev` + older, kept for migration
├── AppIcon.icon/           Icon Composer icon (wins on iOS 26); Assets.xcassets has the flat fallback + AccentColor + BackgroundBase
├── Info.plist.template, Up Next.entitlements, PrivacyInfo.xcprivacy
└── docs/v2-shared-library-plan.md

ci_scripts/ci_post_clone.sh        Xcode Cloud: writes Info.plist from env, sets build number
experiments/collection_recommendations/   Python eval harness for Jev (README, findings.md)
experiments/legacy_import/         swiftc runtime check for LegacyStoreReader
AppStore/                          Store copy + screenshots
```

## Rules and traps

Things you can't derive from reading one file. Each points at the code that explains itself.

### Core Data / CloudKit
- **Every model change is a new version.** Never edit a shipped `.xcdatamodel`. `.xccurrentversion` must point at the current version and a new version's name must sort alphabetically after it (Xcode rewrites the pointer to the alphabetically-last name). All attributes optional/defaulted, all relationships optional with inverses. Collection/optional-number attributes carry a `Raw`/`Number` suffix in the model; Swift exposes clean names as computed properties.
- Nothing ever deletes or recreates a store. A store that won't open sets `storeLoadError` and the app shows a failure screen.
- **Relate before save**: a new object must be related into the graph in the same save it's created (Core Data picks the CloudKit zone from relationships). Pass relationship targets into inits (`ListItem`, `CustomListItem`, `CustomList`, `MediaList` join the context *and store* of what they're given — `inferredContext` / `assignToStore` in `MediaItem.swift`). Never set a relationship to a stored object on a context-less object.
- `TMDBService.mapToMovie/mapToTVShow` return context-less value objects; they become persistent only via `canonicalMovieRow/canonicalTVShowRow` or `update(from:)`. **One media row per TMDB id** — always go through the canonical lookup.
- Identity is `===`. Never compare temporary `objectID`s. Views reading model objects use `@ObservedObject`.
- No autosave: view models save on every mutation; `ContentView` saves on background. A failed save rolls back and toasts once.
- `networks` is unordered — render through `displayOrderedNetworks` / `orderedNetworks`, never raw.
- Deleting a `ListItem`/`CustomListItem`/collection deletes media rows nothing else references (`deleteMediaIfUnreferenced`). Undo/commit of a deferred delete re-checks the object is still live.
- **Detail-sheet wrapper `ListItem`s** have `list == nil`. Discover/search/suggestions wrap context-less rows (never inserted); the collection sheet wraps a persisted row (inserted, deleted on disappear). Library fetches filter `list != nil`.
- Media ids are two namespaces; any mixed set uses `MediaIDKey.make(mediaType, id)`.
- **CloudKit schema**: before any TestFlight build after a model change, run a DEBUG build on a signed-in device, Settings → Debug Options → **Initialize CloudKit Schema**, verify in CloudKit Console (Development), then **Deploy Schema Changes** to Production. Fields only appear in Development once a non-nil value has been exported, so an unset optional never shows up on its own. The button also runs `ensureShareRecordTypeExists()` — saves and deletes a throwaway `CKShare` in a temp zone — because **`cloudkit.share` is a system type that only exists once a share has been saved in that environment**; deploying without it makes every Production share fail ("Cannot create new type cloudkit.share in production schema") *and* wedges the mirroring delegate's setup so nothing exports at all. Confirm `cloudkit.share` is in Development → Record Types before deploying. Since `2.1-activity` that also means `CD_ActivityEvent` (and `CD_WatchListGroup.activitySet`) — the Initialize button exports it.

### Sharing (see `PersistenceController.swift` for the full story)
- One share rooted at `WatchListGroup`; everything must be reachable from it.
- **Role rule — "a shared group wins"**: participant if `sharedStore` has a group, else owner if `privateStore` has one, else seed a fresh owner. `activeStore` follows; every insert goes there. Seeding waits for the first CloudKit import (or 10 s) so a second device doesn't create a duplicate root; if duplicates happen anyway, `reconciledRoot` merges deterministically.
- Streaming services are household-wide: `WatchListGroup.selectedProviderIDsRaw` is the truth, `ProviderSettings.selectedProviderIDs` is a mirror (echo-guarded both ways; UserDefaults is only a startup cache). Region, Discover toggle, onboarding and pitch flags stay device-local.
- Share links: `receiveShareInvitation` has three outcomes (owner-already-sharing → "Stop Sharing First"; participant re-tapping own share → silent accept; else park in `pendingShareInvitation` for the Join alert). **The Join alert's `isPresented` setter must stay a no-op** — SwiftUI writes `false` before the button action runs.
- Accepting purges the whole private store (and that purge syncs to the account). Owner stopping deletes only the `CKShare`; participant leaving purges the shared zone and re-bootstraps as owner.
- Remote changes: persistent history diffing per store, transactions authored `"app"` are skipped, `remoteChangeCount` bumps. Mid-join the flag flips and `group` drops *before* the count bumps so view models see "joining, no group" in one pass; adds made then are queued (`pendingAdds`).
- **Never call `existingShare()` from a `body`** — read `liveShare` / `isSharingLive` / `isCloudAccountAvailable`; `refreshLiveShare()` only on `scenePhase == .active`. **An accepted invitation never reaches the local mirror on its own** — the share record changes but no managed object does, so no history transaction fires; `refreshLiveShareFromServer()` (one record fetch + `persistUpdatedShare`) runs from the Sharing screen's `refresh()` and the toolbar button's scene-active hook. The Sharing screen lists every participant (name or role fallback, You, Owner / Joined / Invited) and adds a What's Shared card and an Activity link under the live-share cards.
- **Sync status is observable**: `PersistenceController.lastSyncEvents` (latest setup/import/export event, from `eventChangedNotification`), `isSyncing`, `lastSyncError` (human text + domain/code + first partial-error item), `lastSuccessfulSync`, `syncStatusSummary`. Settings → About shows it and pushes `SyncActivityView`, a persisted (`UserDefaults` `sync.activityLog`, 40 entries) log of finished events and share attempts — `syncActivity` / `appendSyncActivity` / `clearSyncActivity` — because a transient partial failure is replaced by the next successful export and would otherwise vanish; `describeSyncError` expands `CKPartialErrorsByItemIDKey` into distinct per-item errors with counts and a sample record id; the screen's "Check iCloud Now" (`runCloudKitCheck()`) logs a "check" entry with build kind (receipt name → TestFlight / App Store / Xcode), account status, private + shared zone names, whether the root record is server-acknowledged (`container.record(for:)` change tag) and how many titles are; **Sync repair** (`isStuckBehindUnacceptedShare()` / `repairSync()`, button on the same screen, owner only): the stuck state is a local `CKShare` on the root whose record the server never acknowledged — `container.share` moved the graph into a share zone, the share record was rejected, every export retries it and the whole library sits unexported behind it while the share sheet spins on `.existing(share)`. There is no API to move objects out of a share zone, so the repair deep-copies everything reachable from the root (all attributes + relationships, generic over `entity.attributesByName`/`relationshipsByName`) into fresh objects assigned to the private store (→ default zone), gives the new root a new `id`, deletes *every* old object in the private store, saves, then `purgeObjectsAndRecordsInZone` on the stale zone (failure non-fatal) and re-runs the role rule. Verified on the demo seed: 192 objects in, 192 out, counts identical. DEBUG `--repair-sync` runs it 25 s after bootstrap for that check. **Sync reset** (`resetSync()`, red button on the same screen, owner only) is the last resort for a store whose mirroring *metadata* is inconsistent (exports die at bookkeeping with `Cannot create objectID … (entityID)` / "unhandled exception while analyzing history" and the delegate resets every cycle — seen after the Development→Production flip plus a half-finished share): snapshot every private-store object to `sync-reset-snapshot.archive` (entity, attributes, relationships as object URIs; `NSKeyedArchiver`, secure coding), delete every non-default zone in the private database (must succeed — a fresh store importing old zones would duplicate the library), clear the history-token / initial-import defaults, remove + `destroyPersistentStore` both stores, `exit(0)`; `bootstrap()` calls `restoreResetSnapshot()` before the role rule on the next launch. Verified on the demo seed: 192 out, 192 in, counts identical. DEBUG `--reset-sync` runs it 25 s after bootstrap. After the zones are deleted the reset polls `allRecordZones` (up to 20 s) until they're really gone — deletion is eventually consistent and the first run's fresh store imported the old graph straight back. **Remove Duplicates** (`removeDuplicates()`, same screen) is the cleanup for that shape — a second root folded in by `mergeDuplicateLists` doubles every title and collection: keeps the lowest-`order` entry per title per list, merges same-named collections (unique members), drops now-unreferenced media, bumps `remoteChangeCount`. Verified: a double snapshot restore (42/24/26/2/8) → 21/12/13/1/4. DEBUG `--dedupe-sync`. Bootstrap also `sweepUnreferencedNetworks()` — the refresh's provider reconciliation leaks orphan `Network` rows — `scheduleUnreferencedMediaSweep()` (3 min after launch, only when `!isSyncing`, not joining, join ≥10 min old — a participant's import can land a media row before its entry; `sweepUnreferencedMedia()` is also what Remove Duplicates calls), and `sweepDanglingEntries(olderThan: 1 h)`: a `ListItem`/`CustomListItem` with neither `movie` nor `tvShow` can't render or be recovered (the TMDB id lived on the row); the age gate protects an import that lands the entry a moment before its row. `removeDuplicates` runs the same sweep with no age gate *first*, and picks a collection merge's keeper by most renderable entries (then lowest id) — a hollow imported copy once won that merge by UUID and emptied a collection. `createShare` also arms a *detached* 60 s watchdog that writes to the log through the defaults (`writeSyncActivity`, read-merge-write) so a main thread wedged inside `container.share` still leaves a trace; the Sharing screen's unshared card warns while an export is in flight or after a failed one. `createShare()` races `container.share` against a 60 s timeout (`PersistenceError.shareTimedOut`) — the share sheet otherwise spins forever behind a first-launch export to a fresh CloudKit environment.
- Naming the other person: `CloudKitNames.swift` only. `otherParticipant` resolves by role; `partnerParticipant` is owner-side only.
- Partner-change notifications (`RemoteActivityNotifier`) are driven only by imported `ActivityEvent` inserts — no per-entity diffing, no ignore list. Attribution: the event record's `creatorUserRecordID ≠ CKCurrentUserDefaultName` (no record = mine, skipped), so the user's own other device never pings. Events whose own `createdAt` is >10 min old and the join window are skipped. Phrasing is `ActivityEvent.sentence(actor:)`; actor = `otherPersonDisplayName()`, falling back to the event's `actorName` when that's "Someone".
- **Activity**: every user mutation writes an `ActivityEvent` onto the root via `PersistenceController.recordActivity` in the *same save* as the mutation (no-op without a live root or while `isSuppressingActivity`). Call sites: `addTVShow`/`addMovie` (incl. the `pendingAdds` flush), `commitPendingDeletion` (never `removeItem` — an undone swipe leaves no event), the row's Mark Watched/Unwatched/Pick Back Up (`MediaListView.toggleWatched`), the pill's Mark as Watched/Unwatched (`applyStateChange(logsWatchedActivity:)`; not Start Watching/Move/Drop/Pick Back Up), the season checklist completing the set via a circle tap (`lastSeasonToggle`, one event, never per season); collections: create/delete/rename (name change only)/add/`commitPendingRemoval`/`toggleWatched` (not `markAllUnwatched`). `recordWatchedActivity(for:)` phrases from the item's state *after* the change. Library watched events carry `contextName` nil; collection ones carry the collection name. `actorRecordName` (this account's `CKContainer.userRecordID`, fetched once in `refreshAccountStatus`) is stamped on every event so per-person filters/badges can be a fetch predicate; `kindRaw`, `mediaKey`, `contextName`, `createdAtRaw` are the other filter axes. An unread badge needs no schema (device-local last-seen date). The 1.x import, `--screenshots` seed and `--seed-demo` seed set `isSuppressingActivity`. `bootstrap()` prunes events >90 days and beyond the newest 500 (`pruneActivity`). Settings → Activity (`ActivityView`) lists them by day with a toolbar Filter menu (Who: Everyone / You / <other name> via `actorRecordName` vs `currentUserRecordName`; What: Everything / Added / Removed / Watched / Collections), same shape as the watchlist's `SectionHeader` filter menu, "No Matches" + Clear Filters when nothing passes; "You" vs the other person comes from the record's `creatorUserRecordID`, resolved once per row in `.task(id:)`. Known gaps: Undo after Mark Watched leaves the `watched` event; after a repair/reset the other person's past events re-export as the owner's and read as "You".
- Not real-time; there is no API to force an import.

### Watched state
- TV: `watchedSeasons` (1-based). A season is *available* only once it has episodes and has started airing (`TVShow.availableSeasonCount`) — announced seasons don't count against the user. `syncWatchedStateFromSeasons` is the one place watched ⇔ seasons is decided; the 6-hour refresh re-runs it.
- `toggleSeason` changes one season only. Only the 44pt circle marks a season; the row header opens episode details. Keep those targets separate.
- Watching (`watchingStartedAt`) and Dropped (`droppedAt`) are independent of watched. State transitions live in `ListItem` and are surfaced *only* via the detail pill's ellipsis menu (`PrimaryAddPill.libraryStateActions`) and row swipe/context menus — never as on-page cards (those were tried and read as contradictions; see `PrimaryAddPill.swift`).
- `ListItem.WatchState` powers the Watched-move Undo; it restores viewing fields only.
- Collections have their **own** watched state (`CustomListItem.watchedAt`) and never touch a library `ListItem`. `CustomListViewModel.changeToken` must be read by anything deriving membership/sections from collection items.
- Episode data is read-only and never persisted.

### Networking / TMDB (see `TMDBService.swift`)
- Provider variants fold onto a canonical name **and id** (`alias(for:)`, `canonicalIDsByName`); aggregators are dropped everywhere; storefronts only from the grid. Originating channels that aren't providers are stored with category `"network"` and ignored by every "on my services" check.
- Region = `ProviderSettings.effectiveRegion` (override → device → US), `nonisolated` so the service can read it off-main.
- `RequestDeduplicator` caches responses; invalidate by path prefix, never wholesale.
- Discover/search loads must run on a view-model-owned task (`runOwnedReload`), never directly on a SwiftUI `.task`/`.refreshable` — SwiftUI cancels those with no replacement and the shimmer never ends.
- Search: `/search/tv` and `/search/movie` run concurrently; ranking is `SearchRanking` (title-match tier + capped popularity + votes). Recommendation scoring is in `RecommendationEngine`; collection suggestions in `CollectionRecommendationEngine` + `JevRecommendationService` (prompt changes must bump `promptVersion`).

### UI
- **Exactly one scroll container stays mounted under `.searchable`** (Discover's `ScrollView`, the add sheet's `List`). Every loading/empty/error state is content *inside* it. Swapping the container makes the field jump and drop focus.
- Glass (`.glassEffect`, `.glass`/`.glassProminent`) is for the floating control layer only (toolbars, toast, detail action row, empty-state CTAs). Content uses `cardSurface` / `cellSurface` / `chipSurface` / `Chip`. No glass on glass.
- Light mode is a first-class design, not a fallback: surfaces are scheme-aware in `DesignTokens.swift`; `.fill.secondary`-style black-alpha shapes vanish on the light mesh — use `lightControlBorder`. The search field and segmented picker are styled via `LightModeControlAppearance` (light trait only). Hero tint is conditioned per scheme at render time (`DominantTint.color(for:)`).
- Metadata joiner is `" · "` (U+00B7 with spaces). `.fontDesign(.rounded)` only on chips, badges, counts and small captions.
- **Every mover is Reduce-Motion gated.** Shared vocabulary in `UI/Motion.swift`; every add/done glyph uses `.checkmarkPop(isOn:)` with a ternary `systemName` (one `Image`, not two).
- A `ForEach` removal inside a horizontal `ScrollView` does not animate — animate the card's own geometry instead (see `MediaDetailView.collapsingSimilarID`).
- Every presenter of `MediaDetailView` owns a `@Namespace` and uses the zoom transition; source ids are `MediaIDKey` strings, prefixed per surface where a title can appear twice on one screen.
- The watchlist toolbar's "+ / Edit" is one `ToolbarItem` with a `.plain` `HStack`, not two items (two items put an icon and a text label at opposite ends of one pill).
- `MediaListView` uses `DesignTokens.Spacing.screenInset` for list insets; don't add outer horizontal padding to its `List`.
- **iPad**: compact width must stay identical to the phone. Regular width = sidebar-adaptable tabs, `LazyVGrid` of the same row cards, detail as a `.page` sheet, editing as the centered phone list. A `NavigationSplitView` master-detail was tried and rejected (crams the list into a sidebar and reports `.compact` to its contents) — don't reintroduce it.
- Provider onboarding (`ProviderSettingsView(isRoot: true)`) is presented once by `ContentView`; the same view is pushed (`isRoot: false`) from Settings. `RegionPickerView` is a searchable list, never a menu `Picker`.

### Vocabulary (user-facing copy)
- **watchlist** = everything the user tracks; **Up Next** = the unwatched queue and the act of adding ("Add to Up Next", "On Up Next", "Remove from Up Next"); **collection** = a user-created group (code says `CustomList`); **title** = a movie or show.
- Never surface `library`, `list` alone, `watch list`, `item(s)`, or **`partner`** — the app doesn't know what the two people are to each other. Use the CloudKit display name when iOS provides it; otherwise rewrite around the gap ("Someone added Elf", "Sharing Stopped").
- Buttons/menu items/chips/alert titles Title Case; messages sentence case; `…` and curly quotes. Toasts: `Added X` / `Added X to Y` / `Removed X` / `Moved X to Watched`, no quotation marks. Taking a title off is "Remove"; deleting a collection is "Delete".

## App Store screenshots

DEBUG builds accept `--screenshots` (`ScreenshotMode.swift`): in-memory non-CloudKit store, throwaway `UserDefaults` suite, six providers preselected, onboarding skipped, curated TMDB seed (~100 s). `--tab tvShows|movies|collections|discover`, `--open <tmdbID>`, `--collection <name>`. Capture: build for Simulator, `simctl install`, `simctl status_bar … override --time 9:41`, `simctl launch <udid> com.erichermanson.upnext --screenshots --tab …`, wait for seeding, `simctl io <udid> screenshot`. Sizes: iPhone 17 Pro Max (1320×2868), iPad Pro 13" (2064×2752). The demo seed never runs merely because a library is empty.

## CI (Xcode Cloud)

`ci_scripts/ci_post_clone.sh` writes `Info.plist` from `$TMDB_API_KEY` (required) / `$TYPESAFE_API_KEY` (optional) and sets the build number from `$CI_BUILD_NUMBER`. Distribution Preparation must be "App Store Connect". CloudKit schema deploy rule is under Core Data above.

## Experiments

`experiments/collection_recommendations/` — standalone Python harness for Jev ranking (`evaluate.py prepare|run|report --batch-size 6`; tests via `python3 -m unittest discover -s experiments/collection_recommendations -p "test_*.py"`). Credentials from `.env.jev.local` (gitignored). Results and limitations in its `findings.md`. Never touches real library data.
