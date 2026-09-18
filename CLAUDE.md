# CLAUDE.md

## Self-Maintenance Rule

After any change to the codebase, check whether CLAUDE.md and/or README.md need updating. This includes:

- New files, renamed files, or deleted files → update file maps below
- New features or changed behavior → update README
- New environment variables or config options → update both
- Changed build steps or test commands → update both
- Architectural changes → update both

This is not optional. Stale docs are worse than no docs.

## Task Tracking Rule

For any effort that involves multiple steps — whether due to dependencies/blockers between steps or multiple unrelated tasks in a single prompt — always create a task list up front using `TaskCreate`. Mark tasks `in_progress` when starting and `completed` when done. This keeps work organized and visible.

---

## Project Overview

**Up Next** — Native iOS app (Swift/SwiftUI, iOS 26+) for managing movie and TV show watchlists. Supports sharing the entire library with one other person (Apple Account). Uses the TMDB API for media metadata. No accounts, no analytics, no ads.

- **Xcode project**: `Up Next.xcodeproj` (no CLI build, no SPM packages)
- **Bundle ID**: `com.erichermanson.upnext`
- **Deployment target**: iOS 26.1
- **Swift version**: 5.0
- **Persistence**: Core Data (`NSPersistentCloudKitContainer`, two stores: private + shared scope) in iCloud container `iCloud.com.erichermanson.upnext.shared`
- **No tests**
- **No third-party dependencies** — all networking and persistence handled natively

## Setup

1. **CloudKit container**: Xcode → target → Signing & Capabilities → iCloud → add container `iCloud.com.erichermanson.upnext.shared` (registers it with the App ID).
2. **Info.plist**: `Up Next/Info.plist` is gitignored (contains TMDB API key):
   ```bash
   cp "Up Next/Info.plist.template" "Up Next/Info.plist"
   ```
   Then replace `YOUR_API_KEY_HERE` with a real TMDB API key.
3. **Simulator builds**: unsigned Simulator builds (e.g., CI smoke tests, `CODE_SIGNING_ALLOWED=NO`) must be launched with `--no-cloudkit` — CloudKit traps without the `icloud-services` entitlement.

## Architecture

MVVM with Core Data persistence. Three `@Observable` ViewModels own business logic; Views are thin SwiftUI layers. `TMDBService` is a singleton API client. `PersistenceController` is a singleton (`@MainActor @Observable`) that owns the `NSPersistentCloudKitContainer`, manages two stores (private and shared), and orchestrates bootstrap (role detection, CloudKit share acceptance, seeding). ViewModels call `reloadFromStore()` when `PersistenceController.remoteChangeCount` changes to reflect remote edits. No dependency injection — ViewModels are created in the app entry point and passed via `.environment()`, and the managed object context is set via `.environment(\.managedObjectContext, ...)`.

See `PersistenceController.swift` for the role rule ("a shared group wins"), "relate before save" pattern, and how remote changes are tracked via persistent history diffing with `transactionAuthor = "app"`.

### Tab Structure

| Tab | View | ViewModel |
|-----|------|-----------|
| TV Shows | `MediaListView` | `MediaLibraryViewModel` |
| Movies | `MediaListView` | `MediaLibraryViewModel` |
| Collections | `MyListsView` | `CustomListViewModel` |
| Discover | `DiscoverView` | `DiscoverViewModel` |

## File Map

```
Up Next/
├── App/
│   ├── Watch_ListApp.swift              # @main entry; bootstraps PersistenceController, sets up environment
│   ├── AppDelegate.swift                # UIApplicationDelegate + SceneDelegate for CloudKit share acceptance
│   ├── ContentView.swift                # Tab navigation (TV Shows, Movies, Collections, Discover); owns the single SettingsView sheet + the onboarding ProviderSettingsView sheet
│   └── ScreenshotMode.swift             # DEBUG-only: --screenshots seeds a curated demo library for App Store captures
│
├── Models/                              # Core Data NSManagedObject subclasses (@objc(Name))
│   ├── MediaItem.swift                  # Movie, TVShow, Network models + convenience inits + helper functions
│   ├── ListItem.swift                   # Watchlist item (refs Movie or TVShow, tracks watched state)
│   ├── MediaList.swift                  # Watchlist container (TV Shows / Movies)
│   ├── CustomList.swift                 # User-created collection (name, icon)
│   ├── CustomListItem.swift             # Item in a custom list (own `watchedAt`, independent of the library)
│   └── WatchListGroup.swift             # Share root (one per device); everything flows from here
│
├── ViewModels/
│   ├── MediaLibraryViewModel.swift      # Main watchlist state, add/remove, refresh, reorder, reloadFromStore
│   ├── DiscoverViewModel.swift          # Carousels (trending, airing this week / in theaters, top rated, new), browse, provider filter, error state, in-tab search (query, results, isSearching, error)
│   └── CustomListViewModel.swift        # Custom list CRUD, per-collection watched state, undo-able removal
│
├── Views/
│   ├── Watchlist/
│   │   ├── MediaListView.swift          # Main list with genre/provider filtering, watched toggle
│   │   ├── TVShowsTabView.swift         # TV Shows tab (list + detail sheet + filter state)
│   │   ├── MoviesTabView.swift          # Movies tab (list + detail sheet + filter state)
│   │   ├── MediaListHelpers.swift       # Unwatched ordering, filterItems (genre / watch option / on my services)
│   │   └── SharePitchCard.swift         # Dismissable "share with a partner" pitch card, TV Shows tab only
│   ├── Detail/
│   │   ├── MediaDetailView.swift        # Detail sheet: edit watched state, rating, notes, seasons
│   │   ├── MediaDetailCards.swift       # Interactive cards: watched toggle, rating, season checklist, episodes link
│   │   ├── MediaDetailMetadata.swift    # Metadata row, provider row, pills, flow layout
│   │   ├── MediaDetailSimilar.swift     # "More Like This" row (recs + similar merged), TMDB collection section, MediaIDKey
│   │   ├── SeasonRatingsSnapshot.swift  # Adaptive TMDB episode ratings bars, episode mean, tap-to-scroll
│   │   └── SeasonEpisodesView.swift     # Read-only episode list for one season (number, title, description, rating, air date, runtime, still)
│   ├── Search/
│   │   ├── WatchlistSearchView.swift    # Context-aware search (all, TV, movies, specific lists); one stable List under .searchable
│   │   ├── RecommendationEngine.swift   # Weighted seeds, genre affinity, discover pool + unified scoring; collection-mode thematic scoring; GenreCatalog
│   │   └── SearchComponents.swift       # MediaType, ShimmerRow/ShimmerRows (List-row placeholders), ShimmerLoadingView, result row
│   ├── Discover/
│   │   └── DiscoverView.swift           # Browse/discover tab with carousels, filters, and in-tab search
│   ├── Lists/
│   │   ├── MyListsView.swift            # Custom lists overview; rows show a poster mosaic (PosterMosaicView) of the first 4 items
│   │   ├── CustomListDetailView.swift   # Icon/name/count header, Unwatched/Watched sections, per-collection watched toggle + detail sheet wrapper
│   │   ├── CreateListView.swift         # Create/edit list dialog with icon picker
│   │   └── AddToListSheet.swift         # Add item to a custom list
│   └── Settings/
│       ├── SettingsView.swift           # Settings root (sheet from every tab): Sharing / Streaming Services / Region rows + About; hosts the Sharing push screen
│       ├── ProviderSettingsView.swift   # Streaming service grid; isRoot owns its own NavigationStack+Done (first-launch onboarding), else pushed from SettingsView. Also hosts RegionPickerView (internal)
│       └── SharingSettingsView.swift    # SharingSection: owner unshared → share link; owner shared → participants + manage; participant → leave. Pushed from SettingsView's Sharing row
│
├── Services/
│   ├── PersistenceController.swift      # Core Data + CloudKit container, role rule, remote change tracking, sharing API
│   ├── RemoteActivityNotifier.swift     # Partner edits → local notifications (background) or toast (foreground), attributed via CKRecord.lastModifiedUserRecordID
│   ├── TMDBService.swift                # TMDB API client (singleton): search, details, providers, discover
│   ├── TMDBModels.swift                 # Codable structs for TMDB API responses
│   └── ProviderSettings.swift           # UserDefaults-backed provider preferences + region override (effectiveRegion)
│
├── UI/                                  # Shared/reusable UI components
│   ├── DesignTokens.swift               # Radius/spacing/color tokens, cardSurface/cellSurface/chipSurface, Chip
│   ├── SectionHeader.swift              # Shared section header (title, optional icon, optional count chip, optional filter Menu) — watchlist sections, upcoming strip, collection "Watched" header
│   ├── MediaCardView.swift              # Media item card (72×108 poster, title, subtitle folded with first genre, networks)
│   ├── NetworkLogosView.swift           # Inline streaming provider logos with overflow badge
│   ├── CachedAsyncImage.swift           # AsyncImage wrapper with NSCache (200 items, 100 MB); optional onLoad hands back the decoded UIImage
│   ├── ImageColor.swift                 # UIImage.dominantColor() (CIAreaAverage, HSB-clamped for dark UI) + Color.mixed(with:amount:)
│   ├── SharedViews.swift                # AirDateFormat, StarRatingLabel, EmptyStateView, toast overlay
│   ├── AppBackground.swift              # MeshGradient background
│   ├── SafariView.swift                 # In-app Safari (UIViewControllerRepresentable)
│   ├── TMDBAttributionView.swift        # TMDB attribution footer
│   ├── SFSymbolPickerGrid.swift         # SF Symbol picker for custom list icons
│   ├── CloudSharingView.swift           # UIViewControllerRepresentable over UICloudSharingController
│   ├── PosterMosaicView.swift           # 2×2 poster mosaic (Apple Music playlist style) for a collection row's icon
│   └── SettingsToolbarButton.swift      # Trailing toolbar entry into SettingsView on all four tabs; overlapping initials avatars once a share is live, else a gearshape
│
├── Up Next.xcdatamodeld/                # Core Data model: 8 entities, CloudKit-safe (all optional/defaulted, relationships optional with inverses)
├── AppIcon.icon/                        # Icon Composer (Liquid Glass) app icon: icon.json + Assets/{Ring,Core}.png layers; wins over the appiconset on iOS 26
├── Assets.xcassets                      # AccentColor, images, legacy flat AppIcon.appiconset (fallback / App Store)
├── Info.plist.template                  # Template with TMDB_API_KEY + CloudKit entitlements (`CKSharingSupported`, `UIBackgroundModes`)
├── Up Next.entitlements                 # CloudKit (`iCloud.com.erichermanson.upnext.shared` container) + APS entitlements
├── PrivacyInfo.xcprivacy                # Privacy manifest (no tracking)
└── docs/v2-shared-library-plan.md       # Implementation plan (one shared library via zone sharing)

ci_scripts/
└── ci_post_clone.sh                     # Xcode Cloud: generates Info.plist, sets build number

AppStore/
├── 1.7-metadata.md                      # Paste-ready App Store Connect copy (What's New, description, keywords)
└── screenshots/{iphone-6.9,iphone-6.5,ipad-13}/  # Store screenshots via screenshot mode; 6.5" is resized from 6.9"
```

## Key Patterns

### Core Data Model

Eight entities in `Up Next/Up Next.xcdatamodeld/Up Next.xcdatamodel/contents`:
`Movie`, `TVShow`, `Network`, `MediaList`, `ListItem`, `WatchListGroup`, `CustomList`, `CustomListItem`

All attributes optional or defaulted; all relationships optional with inverses (CloudKit requirements). Collection-typed and optional-number attributes carry a `Raw`/`Number` suffix in the model, and the Swift classes expose the current API names as computed properties (e.g., model `watchedSeasonsRaw` → Swift API `watchedSeasons`, model `runtimeNumber` → Swift API `runtime`). Transformable attributes use `NSSecureUnarchiveFromDataTransformer` (arrays/dicts of String/Int are plist types). The `Up Next.xcdatamodeld` defines relationships with proper inverses; many-to-one deletes cascade only on `MediaList.itemSet` and `CustomList.itemSet` and `WatchListGroup.listSet/customListSet`, else Nullify.

### Sharing

- **One share rooted at `WatchListGroup`** — everything must be reachable: `group.lists → MediaList.items → ListItem.movie/tvShow → Movie.networks → Network`, and `group.customLists → CustomList.items → CustomListItem.movie/tvShow`.
- **Role rule ("a shared group wins")**: the device is a *participant* if `sharedStore` contains a `WatchListGroup`; else an *owner* if `privateStore` contains one; else bootstrap seeds a group + "TV Shows"/"Movies" lists into `privateStore` (fresh owner). `PersistenceController.activeStore` reflects this; every insert goes to the active store. The rule re-runs after a remote change whenever the current root can't be trusted (pending join, root deleted because the owner stopped sharing, or a second root appeared).
- **Seeding waits for the first import**: on a CloudKit-backed first launch, seeding is deferred until the container's first import event finishes or 10 s pass (`initialImportSettled`, persisted), so a second device on the same account doesn't create a duplicate root before the real one arrives. If duplicates still happen, `reconciledRoot(in:)` merges them deterministically — a root that carries a `CKShare` wins, else the lowest `WatchListGroup.id`; the losers' lists/collections move to the winner and same-named `MediaList`s fold together (`mergeDuplicateLists`, lowest `MediaList.id` keeps the name). That's why both entities carry a UUID.
- **Share links** arrive through `userDidAcceptCloudKitShareWith` (app running) or `UIScene.ConnectionOptions.cloudKitShareMetadata` in `SceneDelegate.scene(_:willConnectTo:options:)` (cold launch). Both call `PersistenceController.receiveShareInvitation`, which parks the metadata in `pendingShareInvitation`; `ContentView` shows a "Join <owner>'s library?" alert that spells out how many of the device's own titles/collections will be removed, and only "Join" runs `acceptShare`. A device that's already a participant accepts silently (nothing to lose).
- **No autosave**: `ContentView` calls `persistence.save()` when the scene goes to the background so detail-sheet edits (rating, notes, seasons) survive termination; view models save explicitly on every mutation.
- **Collections UI re-render**: `CustomListViewModel.changeToken` is bumped on every mutation and read inside `visibleItems(in:)` / `containsItem` — a child `CustomListItem` changing doesn't republish its `CustomList`, so section membership would otherwise go stale.
- **Partner-change notifications** (`RemoteActivityNotifier`): no server component. The foreign history transactions `RemoteChangeObserver` already merges are turned into phrased messages ("Sarah added Elf to Movies", "…marked Breaking Bad watched", collection adds/renames); more than 3 in a batch collapse to "made N changes". Attribution: the object's `CKRecord.lastModifiedUserRecordID` must differ from `CKCurrentUserDefaultName`, so the same account's other devices never trigger a ping; deletions have no record and are not announced; `Movie`/`TVShow`/`Network` changes (metadata refresh) are ignored. `ListItem`s with `list == nil` (detail-sheet wrappers) are never announced, and `droppedAt` is checked before the watched fields because `dropShow()`/`resumeShow()` touch both. App active → `PersistenceController.recentRemoteActivity` → toast in `ContentView`; otherwise a `UNUserNotificationCenter` local notification, skipping any change whose *record* `modificationDate` (the partner's actual edit time — history timestamps only say when the import ran) is >10 min old, and everything while a join import is in progress. Permission is requested whenever a shared library is live on the device (role rule's participant branch, `acceptShare`, and `SharingSection` seeing a share), so pre-existing participants are covered too. Background delivery relies on the `remote-notification` background mode waking the app for CloudKit's silent push — a force-quit app catches up (as a toast) on next launch.
- **Relate before save**: Core Data picks a new object's CloudKit zone from its relationships. Every new object must be related to the graph (to a list / group / media row) in the same save it's created. The "context inference" rule: `ListItem`, `CustomListItem`, `CustomList` and `MediaList` inits must join the context *and store* of any persisted object passed to them (`inferredContext` / `assignToStore` in `MediaItem.swift`), and `CustomList`/`MediaList` take `group:` in the init. Rule: pass relationship targets to the init; never set a relationship to a stored object on a context-less object.
- **Remote changes → UI**: `PersistenceController` observes `.NSPersistentStoreRemoteChange`, consumes persistent history since the last stored token (per store), ignores transactions authored by this app (`transactionAuthor = "app"`), and bumps `remoteChangeCount` (observable). View models observe this count and call `reloadFromStore()` to refresh their arrays, preserving any pending undo-able deletion or pending removal.
- **Merge policy**: `NSMergeByPropertyObjectTrumpMergePolicy` (last writer wins). No dedup pass.
- **Identity**: Use `===` (same context ⇒ uniqued); never compare temporary `objectID`s.
- **Detail-sheet transient `ListItem`** (Discover / collections / similar titles): inserted into `viewContext` + `activeStore` with `list == nil`, deleted on disappear. Library fetches filter `list != nil`.
- **Unattached value objects**: `TMDBService.mapToMovie/mapToTVShow` create `Movie`/`TVShow`/`Network` with `context: nil`. They become persistent only via `canonicalMovieRow/canonicalTVShowRow` (insert + add networks) or `update(from:)` (insert networks first).
- **Accepting a share** (`SceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:)` → `PersistenceController.acceptShare(metadata:)`): sets `isJoiningSharedLibrary` flag, purges the entire private store, and sets `role = .participant` until the shared zone's first import lands (bumps `remoteChangeCount`, sets `group`).
- **Stopping sharing** (owner via `UICloudSharingController`): deletes only the `CKShare`; the owner's data stays. Participant via `PersistenceController.leaveShare()`: purges the shared zone and re-bootstraps as a fresh owner.
- Not real-time: shared zone imports happen on a seconds–minutes delay; there is no API to force an import.
- **Share pitch card** (`SharePitchCard`, TV Shows tab only — see `TVShowsTabView.showsSharePitch`): a dismissable "Watching with someone?" card above the upcoming strip, pitching the headline sharing feature where nothing else in the main UI states it. Shown only when all of: not yet dismissed (`ProviderSettings.hasDismissedSharePitch`, key `sharing.pitchDismissed`); role isn't `.participant`; not mid-join; the tab has finished loading; the library has ≥3 titles total (TV + movies); and no share is already live (no `CKShare` with a non-owner participant — same "not live" test `SettingsToolbarButton` uses). The close button sets the flag permanently (the `ShareLink` tap deliberately does not — the share sheet is presented from the card, so removing it mid-tap would cancel the presentation); the DEBUG "Reset Providers & Onboarding" button also clears it.
- **"Added by" attribution** (detail sheet, library rows only — `listItem.list != nil`): read-only, no schema change. `PersistenceController.attribution(for:)` reads the mirrored `CKRecord`'s `creatorUserRecordID`/`creationDate` (`container.record(for:)`); `CKCurrentUserDefaultName` renders as "you", another id is matched against `existingShare()?.participants` for a display name (falls back to "your partner"). Nil when no share is live or the record hasn't mirrored down yet. `AddedByCaption` (`MediaDetailMetadata.swift`) fetches it in a `.task` and caches it in `@State` since `record(for:)` is slow-ish.
- **Settings entry point**: `SettingsView` (`Views/Settings/SettingsView.swift`) is the sheet every tab's trailing toolbar button opens (`ContentView.showingSettings`) — Sharing is the first, most prominent row (pushes a screen hosting `SharingSection`), then Streaming Services (pushes `ProviderSettingsView(isRoot: false)`), Region (pushes `RegionPickerView`), and About. `SettingsToolbarButton` (`UI/SettingsToolbarButton.swift`) is a plain gear normally; once a share is live on the device (owner with ≥1 non-owner participant, or `role == .participant`) it swaps to two overlapping initials avatars (from `CKShare.currentUserParticipant` / the first non-owner participant's `nameComponents`) so sharing status is visible without opening Settings. It refreshes on appear, on `scenePhase == .active`, and on `remoteChangeCount` changes, matching `SharingSection`'s own refresh triggers.

### Provider Logic (TMDBService)

- Full regional provider list from `/watch/providers/{movie,tv}`, minus rent/buy storefronts and resold "channel" variants
- Provider aliases collapse variants onto a canonical name **and canonical TMDB provider id** (e.g., "Netflix Standard with Ads" (1796) → Netflix (8)), so stored `Network.id`s always match `ProviderSettings` selections. Aliases resolve before the channel-variant filter, so e.g. "Paramount+ Amazon Channel" counts as Paramount+.
- Network → Provider ID mapping (e.g., "AMC" network → AMC+ provider)
- Region-aware lookups via `TMDBService.currentRegion` = `ProviderSettings.effectiveRegion`: the user's override (`providers.regionOverride`) if set, else `Locale.current.region`, else US. `effectiveRegion` is `nonisolated` and reads UserDefaults directly so the service can call it off the main actor.

### "On My Services" (ProviderSettings)

`ProviderSettings` (UserDefaults-backed, `@Observable` singleton) drives three things:
- **Discover**: `onlyMyServicesInDiscover` (key `discover.onlyMyServices`, default on) sends `with_watch_providers` + `watch_region` on every carousel/browse request via `DiscoverViewModel.providerFilter`. A compact `Chip` directly under the media-type picker ("On my services", `checkmark.seal`/`checkmark.seal.fill`, emphasized when on) toggles it; it becomes a "Choose your services" chip (`play.tv`) that opens `ProviderSettingsView` when nothing is selected.
- **Watchlist filter**: per-tab `@AppStorage` flags `tvShows.onlyMyServices` / `movies.onlyMyServices`, applied by `filterItems(...)` in `MediaListHelpers.swift` (`isOnSelectedServices` = any network with category `stream`/`ads` whose id is selected). Auto-cleared if the user deselects all providers.
- **First launch**: `ContentView` presents `ProviderSettingsView` (as its own root sheet, `isRoot` default `true`) once when no providers are selected and `hasCompletedProviderOnboarding` is false; the flag is set on presentation so it never re-prompts. The same view is pushed (`isRoot: false`) from `SettingsView`'s "Streaming Services" row the rest of the time. The DEBUG "Reset Providers & Onboarding" button (now on `SettingsView`) clears it (and the region override).
- **Region override**: the "Region" row lives on `SettingsView` (not `ProviderSettingsView`) and pushes `RegionPickerView` (internal, defined in `ProviderSettingsView.swift`), a searchable list of `/watch/providers/regions` (Automatic stays selectable if the fetch fails). Never a menu-style `Picker` — ~100 entries, and its label wrapped over the subtitle. "Automatic" = `nil`; picking the device's own region still stores it. Changing it re-issues Discover (`DiscoverView` observes `regionOverride`; the carousel guard and `BrowseRequest` carry the region so a superseded region can't land) and `ContentView` kicks `MediaLibraryViewModel.refreshNow()` so stored networks re-resolve; the provider grid itself reloads next time `ProviderSettingsView` is opened. Selections are never pruned — an off-region provider id just matches nothing.

### Discover Data Sources

- **Trending**: `/trending/{tv,movie}/week` when the provider filter is off; `/discover` `popularity.desc` + providers when it's on (`/trending` can't take `with_watch_providers`).
- **Airing This Week** (TV): `/discover/tv` with `air_date.gte/lte` = today…+7d, respects the provider filter. **In Theaters** (movies): `/movie/now_playing` with `region`, always shown.
- **New Releases**: `first_air_date.lte` / `primary_release_date.lte` = today so unreleased titles don't leak in. Dates are built with `TMDBService.apiDateString` (UTC).
- Errors surface as `carouselError` / `browseError` with a retry `EmptyStateView` that calls `reload()` (cached). Pull-to-refresh calls `refresh()`, which first drops `RequestDeduplicator` entries for `/discover/`, `/trending/`, `/movie/now_playing` and `/genre/` via `TMDBService.invalidateResponseCache(pathPrefixes:)` — scoped, so detail/search responses stay cached.
- `initialLoad()` / `refresh()` run the reload on a view-model-owned task (`runOwnedReload`) and await its value. The loaders bail on cancellation and leave `isCarouselLoading` / `isBrowseLoading` for the replacement load to clear, so a load must never run directly on a SwiftUI-owned task (`.task`, `.refreshable`) — SwiftUI cancels those with no replacement and the shimmer never ends.
- Search runs `/search/tv` and `/search/movie` concurrently; when the selected segment has no results but the other does, the empty state offers "Show N movies instead". Rows show the release/premiere year.
- The search sheet keeps exactly one `List` mounted under `.searchable` — shimmer (`ShimmerRows`), error, empty-prompt, no-results and no-collection states are all rows in it (`emptyStateRow`). Swapping the scroll container under the search bar made it jump and drop focus.
- **Discover's own search** (`.searchable` on the Discover `NavigationStack`, ~300ms debounced): reuses `SearchResultRowWithImage`/`ShimmerRows` from `SearchComponents.swift` and the same `openDetail`/`addItem`/`isAlreadyAdded` plumbing the carousels already use — no separate recommendation engine. While `DiscoverViewModel.searchQuery` is non-empty, the provider chip, carousels and Browse All are replaced by a plain `LazyVStack` of results for the selected media-type segment, rendered inside the *same* `ScrollView` that hosts the carousels (both types are always searched, so flipping the segment is instant and the "Show N movies instead" hint stays accurate; flipping the segment while searching skips the carousel/browse reload since nothing needs refetching). Exactly one scroll container stays mounted under `.searchable` at all times — swapping it (e.g. for a `List`) makes the search field jump and drop focus, same as the `WatchlistSearchView` note above.
- **Airing This Week's air-date chip**: `/discover/tv` only carries the show's premiere date, not which episode airs this week, so each visible carousel card (`LazyHStack` mounts only what's on screen) fetches its own `next_episode_to_air` lazily via `.task(id:)` calling `TMDBService.getTVShowDetails` (same call the detail sheet makes, deduped/cached by `RequestDeduplicator`) and caches the result in `DiscoverViewModel.airingDates`/`airingEpisodeCodes` keyed by TMDB id. The chip ("S3E2 · Tuesday") only appears once that lands; no chip if `next_episode_to_air` is absent.

### Recommendations (`RecommendationEngine`)

- **Recommended For You** (search sheet, watchlist contexts): `weightedSeeds` picks ≤3 positive seeds sharing one budget (thumbs-up +2 → recent unwatched +1 → recently watched +0.75) and ≤2 thumbs-down seeds at −2. Each seed costs one `/recommendations`; alongside them one `/discover` sweep uses the top 3 positive-affinity genres (`with_genres` OR'd), `ProviderSettings.watchProvidersQueryValue` (whenever any providers are selected — independent of the Discover toggle), `vote_count.gte=100` and released-to-date. Skipped when there's neither a genre nor a provider constraint.
- **Scoring**: `Σ seedWeight × 1/(1+rank/10)` + 1.5 × genre affinity (sum over the candidate's `genreIds`, clamped ±2) + 0.5 × quality (`(voteAverage−6)/4`) + 1.0 if it came from the discover pool and providers are selected. Floors: 50 votes, 6.0 average, total > 0 (so a title only a thumbs-down seed vouches for drops out). Capped at 20. Providers are a strong boost, not a hard filter — `/recommendations` results carry no provider data.
- **Genre affinity** is keyed by the genre *names* stored on media rows (+2 thumbs-up / +1 neutral / −1 thumbs-down, normalised to [−1, 1]); `GenreCatalog.shared` memoises `/genre/{tv,movie}/list` per process to translate to/from the `genreIds` the list endpoints return. `TMDBTVShowSearchResult`/`TMDBMovieSearchResult` carry optional `genreIds` and `voteCount` for this.
- **Collection mode** (`selectListSeeds` + `aggregate` + thematic keywords / `searchThematicResults`) is unchanged apart from the 50-vote floor (a `nil` `voteCount` is kept, since `/search` may omit it).
- **Detail sheet**: `MediaDetailView.mergedMoreLikeThis` folds TMDB's `recommendations` (first) and `similar` into one "More Like This" row, deduped by `MediaIDKey`, minus the current title and anything in `existingIDs` *at open time* — titles added while the sheet is open keep their checkmark rather than vanishing. Capped at 12.

### Media IDs

TMDB movie and TV ids are separate namespaces. Any set that mixes both must use `MediaIDKey.make(mediaType, id)` (`"tv:123"` / `"movie:456"`) — see `MediaDetailSimilar.swift`.

### Design System (iOS 26 Liquid Glass)

- `.preferredColorScheme(.dark)` is set once on the root in `Watch_ListApp.swift` — don't repeat it per view. Font design is the system default app-wide (titles, body, cards, section headers); `.fontDesign(.rounded)` is opted into per-component only for chips, badges, counts and small metadata captions — `Chip` (`DesignTokens.swift`), `StarRatingLabel` and the toast text (`SharedViews.swift`), the network overflow "+N" badge (`NetworkLogosView.swift`), `SettingsToolbarButton`'s initials, the collection count captions in `MyListsView.swift`/`CustomListDetailView.swift`, and `UpcomingCard`'s detail caption in `MediaListView.swift`.
- Glass (`.glassEffect`, `.buttonStyle(.glass/.glassProminent)`) is reserved for the floating control layer: toolbar/tab bar, the toast, the detail sheet's action row, and empty-state CTAs. Content (rows, cards, pills, badges, logos, fields) uses `cardSurface` / `cellSurface` / `chipSurface` / `Chip` from `DesignTokens.swift`. No glass on glass.
- Metadata joiner is always `" \u{00B7} "` (middle dot with spaces) — never `•` or `" - "`. `Chip`'s text carries `.contentTransition(.numericText())` so count chips tick instead of blinking when their value changes inside an animated transaction.
- Use `Color.accentColor` for tints (asset `AccentColor`), `DesignTokens.Radius.*` for corner radii, and `DesignTokens.Colors.backgroundBase` when blending into `AppBackground`.
- Reorder in the watchlist is native `List` + `.onMove` driven by `editMode`.
- **Per-title hero tint**: `MediaDetailView`'s `HeaderImageView` derives a dominant color from the backdrop (or poster, in the poster-only fallback) via `UIImage.dominantColor()` and blends it into its `bottomFade` and a top-anchored wash over the sheet's `AppBackground()`; everywhere else in the design system stays purple.
- **Zoom transition into the detail sheet**: every presenter of `MediaDetailView` (watchlist rows, the upcoming strip, Discover carousels/Browse All/search, collection rows, the search sheet, and the nested "More Like This"/TMDB-collection sheet) owns a `@Namespace`, marks the tapped poster/row `.matchedTransitionSource(id:in:)`, and applies `.navigationTransition(.zoom(sourceID:in:))` to the presented `MediaDetailView`. Source ids are `MediaIDKey` strings (`"tv:123"` / `"movie:456"`); wherever the same title can render twice on one screen (a carousel + Browse All, two carousels, the watchlist row + upcoming strip), the id is additionally prefixed per surface (`"Trending:"`, `"browse:"`, `"upcoming:"`, …) so `matchedTransitionSource` ids never collide — the strip zooms from the list row's source, not its own card. `SearchResultRowWithImage`/`SearchResultRow` take an optional `transitionSource: (id:namespace:)?` (applied via `TransitionSourceModifier` in `SearchComponents.swift`) so rows stay source-compatible without forcing every caller to own a namespace.

### iPad / Size Classes

The target is universal (`TARGETED_DEVICE_FAMILY = 1,2`, resizable windows on iPadOS 26, "Designed for iPad" on Mac). Layouts branch on `@Environment(\.horizontalSizeClass)`; **compact must stay identical to the phone**, so iPad slide-over / narrow Split View just get the phone layout. The shape is Apple TV / Music — sidebar-adaptable tabs, full-width grid content, detail as a large sheet. A `NavigationSplitView` master-detail was tried and rejected: it crams the phone list into a sidebar (and a sidebar column reports `.compact` to its contents, which silently breaks size-class checks inside it). Don't reintroduce it.
- **Tabs**: `ContentView` uses `.tabViewStyle(.sidebarAdaptable)` — top tab bar on iPad that can collapse to a sidebar; iPhone unchanged. Collections are not sidebar entries yet (candidate for a later pass via `TabSection` + `.defaultVisibility(.hidden, for: .tabBar)`).
- **TV Shows / Movies** (`MediaListView`, regular width, not editing): `ScrollView` + `LazyVStack` — the upcoming strip full width, then `SectionHeader` + `LazyVGrid(.adaptive(minimum: 340, maximum: 520))` of the same `MediaListRow` cards for Up Next and Watched (`gridLayout`). Rows keep their `.contextMenu` (Mark Watched / Delete) as the iPad affordance; swipe/list-row modifiers are no-ops outside a `List`. **Editing** on regular width shows the phone `List` (`listLayout`, drag handles) capped at 640pt and centered — reorder is a focused mode, not drag-and-drop in the grid. Compact is `listLayout` untouched.
- **Detail** is always a sheet; on regular width the presenters add `.presentationSizing(.page)`. `MediaDetailView` caps its content column at 760pt and `HeaderImageView` caps the backdrop height on regular width.
- **Collections**: the overview list is capped at 720pt on regular width; inside a collection, regular width uses the same `LazyVGrid` of `row(for:)` cards (`gridLayout`) with the Watched header, compact keeps the `List`. `CustomListViewModel.removeWithUndo(_:from:toast:animation:)` (extension in `CustomListDetailView.swift`) owns the animated remove + Undo toast.
- **Discover** on regular width: media-type picker capped at 480pt, provider row at 640pt, posters 170×255 (`posterCardSize`), Browse All as a `LazyVGrid(.adaptive(minimum: 340, maximum: 520))` of the same row cards, page-sized detail sheet.

### Description truncation

The detail sheet presents metadata/providers, then the overall description and cast, then season/episode and tracking controls. Keep the description and cast above the season checklist.

`ClampedDescriptionText` uses a soft line limit: descriptions that fit within the limit plus one line show in full without more/less. Longer passages collapse to the original limit. Hidden copies measure the actual font and available width, so this adapts to Dynamic Type and resizing. Show/season overviews, season rows, episode rows, and search previews share this component; search previews disable expansion because they are inside navigation buttons. Titles, metadata, and editable notes keep their existing layout limits.

### Watched State (TV Shows)

- `watchedSeasons`: Array of watched season numbers (1-based)
- **Season availability** (`TVShow.availableSeasonCount` / `announcedSeasonNumber` / `announcedSeasonPremiere`, computed — no schema): a season counts only once it has episodes (`seasonEpisodeCounts`) *and* has started airing (`next_episode_to_air` pointing at its episode 1 means it hasn't). TMDB adds a season the moment it's announced, so without this a caught-up show bounces back into Up Next with nothing to watch. Stub rows without season data treat every season as available.
- `nextSeasonToWatch`: Computed from *available* seasons vs watched
- `syncWatchedStateFromSeasons()`: watched ⇔ every available season is in `watchedSeasons` (and at least one is). A caught-up show with an announced season therefore stays in Watched with a "Season N announced / premieres …" subtitle and no partial progress bar; the 6-hour refresh re-runs the sync for every library row, so it returns to Up Next by itself once the season starts. `handleSeasonCountUpdate` no longer un-marks on a season-count increase — the sync decides.
- **Season row actions**: only the bounded 44-point circle target marks a season watched/unwatched. Rows are independent checklist entries without timeline connectors. The header (title/count/score/chevron) and episode chart open season details; the summary’s more/less button only expands text. Keep these targets separate.
- `toggleSeason(_:)` changes only the selected season, preserving gaps and all other season marks. Partial-progress subtitles show “N of M seasons watched”; season-change notifications don't imply a viewing order. Clearing the last mark explicitly clears watched state before syncing, avoiding the legacy whole-show fallback.
- Shows remain in unwatched list when partially watched
- Rows can be marked watched/unwatched (or "Pick Back Up" for dropped shows) via leading swipe or context menu — the transition lives on `ListItem.toggleWatched()` (all seasons for TV). This is the *library's* watched state only; custom-list rows have their own, unrelated toggle (see "Custom Lists")
- Watched section is sorted most-recently-watched first
- **Episode lists are read-only**: `SeasonEpisodesView` fetches `/tv/{id}/season/{n}` (`TMDBService.getSeasonDetails`) on demand — number, title, description, air date, runtime, rating, still image. Reachable from each season row's chevron in `SeasonChecklistCard` (multi-season shows) or `EpisodesLinkCard` for single-season shows / the Discover "add" context / collections. A compact `SeasonRatingsSnapshot` above the rows shows TMDB scores on a fixed 0–10 scale and the unweighted mean of rated episodes; tapping a bar scrolls to its row. Bars have a Dynamic Type-scaled minimum width and scroll horizontally when needed, using the full available column on iPad. Unrated/upcoming episodes have no bar and are excluded from the mean; the snapshot is hidden if none are rated. No additional requests are made. Above the season rows, `SeasonComparisonChart` compares one TMDB score per season on a fixed 0–10 scale, with score/season labels and links to season details. It uses 30-point minimum columns (scaled with Dynamic Type) and 4-point gaps for 8+ seasons, fitting nine seasons at standard text size in a typical iPhone column. It scrolls horizontally when needed and uses the existing ratings without more requests. On the main detail screen, `SeasonChecklistCard` also shows TMDB season-level scores beside season titles, without an extra source label. `MediaDetailView` keeps those scores in transient state from `TMDBTVShowDetail.seasons[].voteAverage`; this is distinct from the episode chart’s calculated mean and needs no persistence or extra requests. Missing/zero scores and announced seasons have no rating label. Each available season also has a compact `CompactEpisodeRatings` strip beneath its description: every episode fits in the available width, a dashed line marks the mean of rated episodes on the same 0–10 scale, individual values appear only when there is room, and tapping opens the episode page. These optional strips fetch season details sequentially and reuse the service response cache; failures and wholly unrated seasons show no strip. No episode-level watched state exists or is planned; nothing here is persisted.

### Custom Lists (user-facing name: "Collections")

The code says `CustomList`/"list"; every user-facing string says "collection" — keep it that way. Never surface the word "library" to users (it's an internal term for the TV Shows/Movies tabs' data). Custom lists are thematic pools (Christmas, Halloween, kid-friendly…) kept deliberately separate from the Up Next queue. Rules:
- **One media row per TMDB id.** `canonicalMovieRow` / `canonicalTVShowRow` (`MediaItem.swift`) look up an existing `Movie`/`TVShow` before any insert — used by `MediaLibraryViewModel.add*` and `CustomListViewModel.addItem`. A search-stub row never overwrites a fully-fetched one.
- **Watched state is the collection's own and is stored on `CustomListItem.watchedAt`** (optional, CloudKit-safe; `isWatched`/`toggleWatched()` derive from it). Nothing in a collection creates, reads or modifies a library `ListItem` for watched purposes — `MediaLibraryViewModel` has no collection-facing watched API at all. `CustomListViewModel.toggleWatched(_:)` flips one entry; `markAllUnwatched(in:)` clears the whole collection.
- **Two sections**: unwatched (by `addedAt`) first, then a "Watched" section (most-recently-watched first) with a `SectionHeader`-style title + count chip, shown only when something is watched. Leading full-swipe and the context menu offer "Mark Watched"/"Mark Unwatched"; the toolbar's ellipsis menu offers "Mark All Unwatched" (confirmation dialog) whenever anything is watched. The row's corner chip reads "Watched Sep 2026" from `watchedAt` (`MediaCardView.watchedLabel`). No rating or season-progress on collection rows — those are library concepts.
- **Detail sheet** is the real `MediaDetailView`, but *always* bound to a transient `ListItem` wrapping the shared media row (like Discover) — inserted into the view context with `list == nil`, deleted on `.onDisappear`. The library fetches filter `list != nil` so collections never leak stray items to the Movies/TV tabs. `collectionWatched:`/`collectionName:` swap the watchlist cards (seasons, watched toggle, rating) for a single `CollectionWatchedCard` scoped to the collection. `onAdd` is nil — there is intentionally no "Add to Up Next" for the collection entry itself — but `onTVShowAdded`/`onMovieAdded` add to *that collection* (`CustomListViewModel.addItem`), `existingIDs` is the collection's membership, and `addTargetName` relabels the Add button/toasts ("Add to Christmas", "Elf added to Christmas"). Browsing similar titles from inside a collection grows the collection, never Up Next. `MediaDetailView.canAddToLibrary` hides those buttons (and the nested sheet's Add) whenever a presenter passes no add hooks, so a "+" can never toast without doing anything. `onRemove` there means remove from the collection (`removeLabel`/`removeMessage`).
- Removal is deferred 5 s with an Undo toast (`commitPendingRemoval` flushed on `scenePhase == .background`). `refreshAllItems` also refreshes rows referenced only by lists.
- **Overview + detail visuals**: `MyListsRow` (`MyListsView.swift`) shows a `PosterMosaicView` (2×2, first 4 items by `addedAt`) instead of a plain icon tile once a collection has items, with the collection's icon shrunk into a small badge next to the name; empty collections keep the SF-symbol tile. `CustomListDetailView` shows an icon/name/"N titles · M watched" header above the sections. Both read `viewModel.changeToken` (via `visibleItems(in:)`) so a sibling row's add/remove keeps them in sync.

### Upcoming Strip

`upcomingEntries(from:mediaType:)` in `MediaListHelpers.swift` builds the "Airing Soon" (TV) / "Coming Soon" (Movies) strip at the top of each watchlist tab. TV: any non-dropped show (watched or not) with `nextEpisodeAirDate` ≥ today; movies: unwatched with `releaseDate` > today. Only dates within the next 30 days qualify (TMDB reports placeholder premieres far out). Sorted soonest-first, capped at 12, ids namespaced `upcoming:<mediaID>`. `TVShow` stores `nextEpisodeSeason/Number/Name` and `status` (from TMDB `next_episode_to_air` / `status`) — cards and the detail chip render `"S3E2 · Jun 15"`, and the detail shows an Ended/Canceled/Returning chip. Relative day labels come from `AirDateFormat.relativeLabel` (UTC day math, consistent with the parser); any date outside the current year renders with the year ("Jul 8, 2027"). Pull-to-refresh calls `MediaLibraryViewModel.refreshNow()`, which bypasses the 6-hour interval and cancels any in-flight launch refresh.

### Image Caching

`CachedAsyncImage` uses `NSCache` (200 items, 100 MB). Prevents reloads on view recreation.

### Data Integrity

- `Movie`/`TVShow` store `backdropPath` (optional) for the detail-sheet header; the poster is the fallback.
- `networks` is an **unordered** Core Data relationship — never render it raw. `displayOrderedNetworks(_:categories:)` (`MediaItem.swift`; also `MediaItemProtocol.orderedNetworks`) gives the stable order (stream → ads → rent → buy, then name, then id); `MediaCardView` and `DetailProviderRow` sort internally so callers can pass the raw array.
- `update(from:)` only reassigns `networks` when providers actually changed, deleting `Network` rows nothing else references. Deleting a `ListItem`/`CustomListItem` deletes its media row when nothing else points at it (`deleteMediaIfUnreferenced`).
- Swipe-delete is deferred 5 s for Undo; it's flushed on `scenePhase == .background`.
- Full refresh (`refreshAllItems`) matches results by TMDB id, never array index, and only stamps `lastFullRefreshDate` when at least one fetch succeeded.
- Identity comparisons use `===` (same context ⇒ uniqued) — never compare temporary `objectID`s.
- Views that read from model objects use `@ObservedObject` (e.g., `@ObservedObject var listItem: ListItem`) since `NSManagedObject` is an `ObservableObject`.

## App Store Screenshots

DEBUG builds accept `--screenshots` (see `ScreenshotMode.swift`): the app uses an in-memory, non-CloudKit store, preselects six providers, skips onboarding, and seeds a curated set of real TMDB titles (with season progress, ratings, and two collections) through the normal view-model APIs. `--tab tvShows|movies|collections|discover` picks the tab, `--open <tmdbID>` presents a TV show's detail sheet, `--collection <name>` drills into that collection. Capture with the simulator: build for `platform=iOS Simulator`, `simctl install`, `simctl status_bar … override --time 9:41`, `simctl launch <udid> com.erichermanson.upnext --screenshots --tab …`, wait for seeding (~100 s; the DEBUG `seedStubData` fallback runs first on an empty store and is purged), then `simctl io <udid> screenshot`. Required sizes: iPhone 17 Pro Max (1320×2868) and iPad Pro 13" (2064×2752). Nothing here compiles into Release.

## CI/CD (Xcode Cloud)

`ci_scripts/ci_post_clone.sh`:
1. Generates `Info.plist` from template using `$TMDB_API_KEY` env var
2. Sets the build number (`CURRENT_PROJECT_VERSION`) from `$CI_BUILD_NUMBER`

`MARKETING_VERSION` is managed manually in the project (currently 2.0). To release a new version, bump `MARKETING_VERSION` in `project.pbxproj`, commit, and push.

**CloudKit schema**: When changes are made to the Core Data model (new attributes, entities, or relationships), the Development schema is automatically created by the first saves to the CloudKit container. Before any TestFlight build, the Development schema must be deployed to Production in CloudKit Console (do this by running a DEBUG build on a device first to let `NSPersistentCloudKitContainer` initialize the Development schema, then deploy it in the console). This is one-time per schema change; once deployed, subsequent builds sync incrementally.

**Important**: Distribution Preparation must be set to "App Store Connect" to select a build for distribution.
