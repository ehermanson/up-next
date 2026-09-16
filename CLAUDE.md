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

**Up Next** — Native iOS app (Swift/SwiftUI, iOS 26+) for managing movie and TV show watchlists. Uses the TMDB API for media metadata. No accounts, no analytics, no ads. Optional CloudKit sync.

- **Xcode project**: `Up Next.xcodeproj` (no CLI build, no SPM packages)
- **Bundle ID**: `com.erichermanson.upnext`
- **Deployment target**: iOS 26.1
- **Swift version**: 5.0
- **Persistence**: SwiftData with optional CloudKit (`iCloud.com.erichermanson.upnext`)
- **No tests**
- **No third-party dependencies** — all networking and persistence handled natively

## Setup

`Up Next/Info.plist` is gitignored (contains TMDB API key):

```bash
cp "Up Next/Info.plist.template" "Up Next/Info.plist"
```

Then replace `YOUR_API_KEY_HERE` with a real TMDB API key.

## Architecture

MVVM with SwiftData persistence. Three `@Observable` ViewModels own business logic; Views are thin SwiftUI layers. `TMDBService` is a singleton API client. No dependency injection — ViewModels are created in the app entry point and passed via `.environment()`.

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
│   ├── Watch_ListApp.swift              # @main entry, SwiftData schema registration (in-memory store in screenshot mode)
│   ├── ContentView.swift                # Tab navigation (TV Shows, Movies, Collections, Discover)
│   └── ScreenshotMode.swift             # DEBUG-only: --screenshots seeds a curated demo library for App Store captures
│
├── Models/                              # SwiftData @Model classes
│   ├── MediaItem.swift                  # Movie, TVShow, Network models
│   ├── ListItem.swift                   # Watchlist item (refs Movie or TVShow, tracks watched state)
│   ├── MediaList.swift                  # Watchlist container
│   ├── CustomList.swift                 # User-created collection (name, icon)
│   ├── CustomListItem.swift             # Item in a custom list (own `watchedAt`, independent of the library)
│   ├── UserIdentity.swift               # User attribution for CloudKit sharing
│   └── WatchListGroup.swift             # Root CloudKit sharing object
│
├── ViewModels/
│   ├── MediaLibraryViewModel.swift      # Main watchlist state, add/remove, refresh, reorder
│   ├── DiscoverViewModel.swift          # Carousels (trending, airing this week / in theaters, top rated, new), browse, provider filter, error state
│   └── CustomListViewModel.swift        # Custom list CRUD, per-collection watched state, undo-able removal, one-time duplicate-row migration
│
├── Views/
│   ├── Watchlist/
│   │   ├── MediaListView.swift          # Main list with genre/provider filtering, watched toggle
│   │   ├── TVShowsTabView.swift         # TV Shows tab (list + detail sheet + filter state)
│   │   ├── MoviesTabView.swift          # Movies tab (list + detail sheet + filter state)
│   │   └── MediaListHelpers.swift       # Unwatched ordering, filterItems (genre / watch option / on my services)
│   ├── Detail/
│   │   ├── MediaDetailView.swift        # Detail sheet: edit watched state, rating, notes, seasons
│   │   ├── MediaDetailCards.swift       # Interactive cards: watched toggle, rating, season checklist
│   │   ├── MediaDetailMetadata.swift    # Metadata row, provider row, pills, flow layout
│   │   └── MediaDetailSimilar.swift     # "More Like This" row (recs + similar merged), TMDB collection section, MediaIDKey
│   ├── Search/
│   │   ├── WatchlistSearchView.swift    # Context-aware search (all, TV, movies, specific lists); one stable List under .searchable
│   │   ├── RecommendationEngine.swift   # Weighted seeds, genre affinity, discover pool + unified scoring; collection-mode thematic scoring; GenreCatalog
│   │   └── SearchComponents.swift       # MediaType, ShimmerRow/ShimmerRows (List-row placeholders), ShimmerLoadingView, result row
│   ├── Discover/
│   │   └── DiscoverView.swift           # Browse/discover tab with carousels and filters
│   ├── Lists/
│   │   ├── MyListsView.swift            # Custom lists overview
│   │   ├── CustomListDetailView.swift   # Unwatched/Watched sections, per-collection watched toggle + detail sheet wrapper
│   │   ├── CreateListView.swift         # Create/edit list dialog with icon picker
│   │   └── AddToListSheet.swift         # Add item to a custom list
│   └── Settings/
│       └── ProviderSettingsView.swift   # Region override picker + streaming service selection
│
├── Services/
│   ├── TMDBService.swift                # TMDB API client (singleton): search, details, providers, discover
│   ├── TMDBModels.swift                 # Codable structs for TMDB API responses
│   └── ProviderSettings.swift           # UserDefaults-backed provider preferences + region override (effectiveRegion)
│
├── UI/                                  # Shared/reusable UI components
│   ├── DesignTokens.swift               # Radius/spacing/color tokens, cardSurface/cellSurface/chipSurface, Chip
│   ├── MediaCardView.swift              # Media item card (poster, title, metadata, networks)
│   ├── NetworkLogosView.swift           # Inline streaming provider logos with overflow badge
│   ├── CachedAsyncImage.swift           # AsyncImage wrapper with NSCache (200 items, 100 MB)
│   ├── SharedViews.swift                # AirDateFormat, StarRatingLabel, EmptyStateView, toast overlay
│   ├── AppBackground.swift              # MeshGradient background
│   ├── SafariView.swift                 # In-app Safari (UIViewControllerRepresentable)
│   ├── TMDBAttributionView.swift        # TMDB attribution footer
│   └── SFSymbolPickerGrid.swift         # SF Symbol picker for custom list icons
│
├── AppIcon.icon/                        # Icon Composer (Liquid Glass) app icon: icon.json + Assets/{Ring,Core}.png layers; wins over the appiconset on iOS 26
├── Assets.xcassets                      # AccentColor, images, legacy flat AppIcon.appiconset (fallback / App Store)
├── Info.plist.template                  # Template with TMDB_API_KEY placeholder
├── Up Next.entitlements                 # CloudKit + APS entitlements
├── PrivacyInfo.xcprivacy                # Privacy manifest (no tracking)
└── Watch_List.xcdatamodeld/             # Legacy CoreData model (unused, can ignore)

ci_scripts/
└── ci_post_clone.sh                     # Xcode Cloud: generates Info.plist, sets build number

AppStore/
├── 1.7-metadata.md                      # Paste-ready App Store Connect copy (What's New, description, keywords)
└── screenshots/{iphone-6.9,iphone-6.5,ipad-13}/  # Store screenshots via screenshot mode; 6.5" is resized from 6.9"
```

## Key Patterns

### SwiftData Schema

Registered in `Watch_ListApp.swift`:
`Movie`, `TVShow`, `Network`, `MediaList`, `ListItem`, `UserIdentity`, `WatchListGroup`, `CustomList`, `CustomListItem`

CloudKit is optional — the app falls back to local-only if CloudKit is unavailable.

### Provider Logic (TMDBService)

- Full regional provider list from `/watch/providers/{movie,tv}`, minus rent/buy storefronts and resold "channel" variants
- Provider aliases collapse variants onto a canonical name **and canonical TMDB provider id** (e.g., "Netflix Standard with Ads" (1796) → Netflix (8)), so stored `Network.id`s always match `ProviderSettings` selections. Aliases resolve before the channel-variant filter, so e.g. "Paramount+ Amazon Channel" counts as Paramount+.
- Network → Provider ID mapping (e.g., "AMC" network → AMC+ provider)
- Region-aware lookups via `TMDBService.currentRegion` = `ProviderSettings.effectiveRegion`: the user's override (`providers.regionOverride`) if set, else `Locale.current.region`, else US. `effectiveRegion` is `nonisolated` and reads UserDefaults directly so the service can call it off the main actor.

### "On My Services" (ProviderSettings)

`ProviderSettings` (UserDefaults-backed, `@Observable` singleton) drives three things:
- **Discover**: `onlyMyServicesInDiscover` (key `discover.onlyMyServices`, default on) sends `with_watch_providers` + `watch_region` on every carousel/browse request via `DiscoverViewModel.providerFilter`. The toggle row under the media-type picker becomes a "Choose your streaming services" button when nothing is selected.
- **Watchlist filter**: per-tab `@AppStorage` flags `tvShows.onlyMyServices` / `movies.onlyMyServices`, applied by `filterItems(...)` in `MediaListHelpers.swift` (`isOnSelectedServices` = any network with category `stream`/`ads` whose id is selected). Auto-cleared if the user deselects all providers.
- **First launch**: `ContentView` presents `ProviderSettingsView` once when no providers are selected and `hasCompletedProviderOnboarding` is false; the flag is set on presentation so it never re-prompts. The DEBUG "Reset Providers & Onboarding" button clears it (and the region override).
- **Region override**: the "Region" row in `ProviderSettingsView` pushes `RegionPickerView`, a searchable list of `/watch/providers/regions` (Automatic stays selectable if the fetch fails). Never a menu-style `Picker` — ~100 entries, and its label wrapped over the subtitle. "Automatic" = `nil`; picking the device's own region still stores it. Changing it reloads the provider grid, re-issues Discover (`DiscoverView` observes `regionOverride`; the carousel guard and `BrowseRequest` carry the region so a superseded region can't land), and `ContentView` kicks `MediaLibraryViewModel.refreshNow()` so stored networks re-resolve. Selections are never pruned — an off-region provider id just matches nothing.

### Discover Data Sources

- **Trending**: `/trending/{tv,movie}/week` when the provider filter is off; `/discover` `popularity.desc` + providers when it's on (`/trending` can't take `with_watch_providers`).
- **Airing This Week** (TV): `/discover/tv` with `air_date.gte/lte` = today…+7d, respects the provider filter. **In Theaters** (movies): `/movie/now_playing` with `region`, always shown.
- **New Releases**: `first_air_date.lte` / `primary_release_date.lte` = today so unreleased titles don't leak in. Dates are built with `TMDBService.apiDateString` (UTC).
- Errors surface as `carouselError` / `browseError` with a retry `EmptyStateView` that calls `reload()` (cached). Pull-to-refresh calls `refresh()`, which first drops `RequestDeduplicator` entries for `/discover/`, `/trending/`, `/movie/now_playing` and `/genre/` via `TMDBService.invalidateResponseCache(pathPrefixes:)` — scoped, so detail/search responses stay cached.
- `initialLoad()` / `refresh()` run the reload on a view-model-owned task (`runOwnedReload`) and await its value. The loaders bail on cancellation and leave `isCarouselLoading` / `isBrowseLoading` for the replacement load to clear, so a load must never run directly on a SwiftUI-owned task (`.task`, `.refreshable`) — SwiftUI cancels those with no replacement and the shimmer never ends.
- Search runs `/search/tv` and `/search/movie` concurrently; when the selected segment has no results but the other does, the empty state offers "Show N movies instead". Rows show the release/premiere year.
- The search sheet keeps exactly one `List` mounted under `.searchable` — shimmer (`ShimmerRows`), error, empty-prompt, no-results and no-collection states are all rows in it (`emptyStateRow`). Swapping the scroll container under the search bar made it jump and drop focus.

### Recommendations (`RecommendationEngine`)

- **Recommended For You** (search sheet, watchlist contexts): `weightedSeeds` picks ≤3 positive seeds sharing one budget (thumbs-up +2 → recent unwatched +1 → recently watched +0.75) and ≤2 thumbs-down seeds at −2. Each seed costs one `/recommendations`; alongside them one `/discover` sweep uses the top 3 positive-affinity genres (`with_genres` OR'd), `ProviderSettings.watchProvidersQueryValue` (whenever any providers are selected — independent of the Discover toggle), `vote_count.gte=100` and released-to-date. Skipped when there's neither a genre nor a provider constraint.
- **Scoring**: `Σ seedWeight × 1/(1+rank/10)` + 1.5 × genre affinity (sum over the candidate's `genreIds`, clamped ±2) + 0.5 × quality (`(voteAverage−6)/4`) + 1.0 if it came from the discover pool and providers are selected. Floors: 50 votes, 6.0 average, total > 0 (so a title only a thumbs-down seed vouches for drops out). Capped at 20. Providers are a strong boost, not a hard filter — `/recommendations` results carry no provider data.
- **Genre affinity** is keyed by the genre *names* stored on media rows (+2 thumbs-up / +1 neutral / −1 thumbs-down, normalised to [−1, 1]); `GenreCatalog.shared` memoises `/genre/{tv,movie}/list` per process to translate to/from the `genreIds` the list endpoints return. `TMDBTVShowSearchResult`/`TMDBMovieSearchResult` carry optional `genreIds` and `voteCount` for this.
- **Collection mode** (`selectListSeeds` + `aggregate` + thematic keywords / `searchThematicResults`) is unchanged apart from the 50-vote floor (a `nil` `voteCount` is kept, since `/search` may omit it).
- **Detail sheet**: `MediaDetailView.mergedMoreLikeThis` folds TMDB's `recommendations` (first) and `similar` into one "More Like This" row, deduped by `MediaIDKey`, minus the current title and anything in `existingIDs` *at open time* — titles added while the sheet is open keep their checkmark rather than vanishing. Capped at 12.

### Media IDs

TMDB movie and TV ids are separate namespaces. Any set that mixes both must use `MediaIDKey.make(mediaType, id)` (`"tv:123"` / `"movie:456"`) — see `MediaDetailSimilar.swift`.

### Design System (iOS 26 Liquid Glass)

- `.preferredColorScheme(.dark)` and `.fontDesign(.rounded)` are set once on the root in `Watch_ListApp.swift` — don't repeat them per view.
- Glass (`.glassEffect`, `.buttonStyle(.glass/.glassProminent)`) is reserved for the floating control layer: toolbar/tab bar, the toast, the detail sheet's action row, and empty-state CTAs. Content (rows, cards, pills, badges, logos, fields) uses `cardSurface` / `cellSurface` / `chipSurface` / `Chip` from `DesignTokens.swift`. No glass on glass.
- Use `Color.accentColor` for tints (asset `AccentColor`), `DesignTokens.Radius.*` for corner radii, and `DesignTokens.Colors.backgroundBase` when blending into `AppBackground`.
- Reorder in the watchlist is native `List` + `.onMove` driven by `editMode`.

### iPad / Size Classes

The target is universal (`TARGETED_DEVICE_FAMILY = 1,2`, resizable windows on iPadOS 26, "Designed for iPad" on Mac). Layouts branch on `@Environment(\.horizontalSizeClass)`; **compact must stay identical to the phone**, so iPad slide-over / narrow Split View just get the phone layout. The shape is Apple TV / Music — sidebar-adaptable tabs, full-width grid content, detail as a large sheet. A `NavigationSplitView` master-detail was tried and rejected: it crams the phone list into a sidebar (and a sidebar column reports `.compact` to its contents, which silently breaks size-class checks inside it). Don't reintroduce it.
- **Tabs**: `ContentView` uses `.tabViewStyle(.sidebarAdaptable)` — top tab bar on iPad that can collapse to a sidebar; iPhone unchanged. Collections are not sidebar entries yet (candidate for a later pass via `TabSection` + `.defaultVisibility(.hidden, for: .tabBar)`).
- **TV Shows / Movies** (`MediaListView`, regular width, not editing): `ScrollView` + `LazyVStack` — the upcoming strip full width, then `SectionHeader` + `LazyVGrid(.adaptive(minimum: 340, maximum: 520))` of the same `MediaListRow` cards for Up Next and Watched (`gridLayout`). Rows keep their `.contextMenu` (Mark Watched / Delete) as the iPad affordance; swipe/list-row modifiers are no-ops outside a `List`. **Editing** on regular width shows the phone `List` (`listLayout`, drag handles) capped at 640pt and centered — reorder is a focused mode, not drag-and-drop in the grid. Compact is `listLayout` untouched.
- **Detail** is always a sheet; on regular width the presenters add `.presentationSizing(.page)`. `MediaDetailView` caps its content column at 760pt and `HeaderImageView` caps the backdrop height on regular width.
- **Collections**: the overview list is capped at 720pt on regular width; inside a collection, regular width uses the same `LazyVGrid` of `row(for:)` cards (`gridLayout`) with the Watched header, compact keeps the `List`. `CustomListViewModel.removeWithUndo(_:from:toast:animation:)` (extension in `CustomListDetailView.swift`) owns the animated remove + Undo toast.
- **Discover** on regular width: media-type picker capped at 480pt, provider row at 640pt, posters 170×255 (`posterCardSize`), Browse All as a `LazyVGrid(.adaptive(minimum: 340, maximum: 520))` of the same row cards, page-sized detail sheet.

### Watched State (TV Shows)

- `watchedSeasons`: Array of watched season numbers (1-based)
- **Season availability** (`TVShow.availableSeasonCount` / `announcedSeasonNumber` / `announcedSeasonPremiere`, computed — no schema): a season counts only once it has episodes (`seasonEpisodeCounts`) *and* has started airing (`next_episode_to_air` pointing at its episode 1 means it hasn't). TMDB adds a season the moment it's announced, so without this a caught-up show bounces back into Up Next with nothing to watch. Stub rows without season data treat every season as available.
- `nextSeasonToWatch`: Computed from *available* seasons vs watched
- `syncWatchedStateFromSeasons()`: watched ⇔ every available season is in `watchedSeasons` (and at least one is). A caught-up show with an announced season therefore stays in Watched with a "Season N announced / premieres …" subtitle and no partial progress bar; the 6-hour refresh re-runs the sync for every library row, so it returns to Up Next by itself once the season starts. `handleSeasonCountUpdate` no longer un-marks on a season-count increase — the sync decides.
- `toggleSeason(_:)` cascades: marking S*n* marks 1…*n*; un-marking S*n* un-marks *n*…last
- Shows remain in unwatched list when partially watched
- Rows can be marked watched/unwatched (or "Pick Back Up" for dropped shows) via leading swipe or context menu — the transition lives on `ListItem.toggleWatched()` (all seasons for TV). This is the *library's* watched state only; custom-list rows have their own, unrelated toggle (see "Custom Lists")
- Watched section is sorted most-recently-watched first

### Custom Lists (user-facing name: "Collections")

The code says `CustomList`/"list"; every user-facing string says "collection" — keep it that way. Never surface the word "library" to users (it's an internal term for the TV Shows/Movies tabs' data). Custom lists are thematic pools (Christmas, Halloween, kid-friendly…) kept deliberately separate from the Up Next queue. Rules:
- **One media row per TMDB id.** `canonicalMovieRow` / `canonicalTVShowRow` (`MediaItem.swift`) look up an existing `Movie`/`TVShow` before any insert — used by `MediaLibraryViewModel.add*` and `CustomListViewModel.addItem`. A search-stub row never overwrites a fully-fetched one. `CustomListViewModel.migrateDuplicateMediaRows` repoints legacy duplicates once per install (`customListMediaRowsMigrated`).
- **Watched state is the collection's own and is stored on `CustomListItem.watchedAt`** (optional, CloudKit-safe; `isWatched`/`toggleWatched()` derive from it). Nothing in a collection creates, reads or modifies a library `ListItem` for watched purposes — `MediaLibraryViewModel` has no collection-facing watched API at all. `CustomListViewModel.toggleWatched(_:)` flips one entry; `markAllUnwatched(in:)` clears the whole collection.
- **Two sections**: unwatched (by `addedAt`) first, then a "Watched" section (most-recently-watched first) with a `SectionHeader`-style title + count chip, shown only when something is watched. Leading full-swipe and the context menu offer "Mark Watched"/"Mark Unwatched"; the toolbar's ellipsis menu offers "Mark All Unwatched" (confirmation dialog) whenever anything is watched. The row's corner chip reads "Watched Sep 2026" from `watchedAt` (`MediaCardView.watchedLabel`). No rating or season-progress on collection rows — those are library concepts.
- **Detail sheet** is the real `MediaDetailView`, but *always* bound to a transient `ListItem` wrapping the shared media row (like Discover) — it never looks up or binds a library `ListItem`. `collectionWatched:`/`collectionName:` swap the watchlist cards (seasons, watched toggle, rating) for a single `CollectionWatchedCard` scoped to the collection. `onAdd` is nil — there is intentionally no "Add to Up Next" for the collection entry itself — but `onTVShowAdded`/`onMovieAdded` add to *that collection* (`CustomListViewModel.addItem`), `existingIDs` is the collection's membership, and `addTargetName` relabels the Add button/toasts ("Add to Christmas", "Elf added to Christmas"). Browsing similar titles from inside a collection grows the collection, never Up Next. `MediaDetailView.canAddToLibrary` hides those buttons (and the nested sheet's Add) whenever a presenter passes no add hooks, so a "+" can never toast without doing anything. The wrapper points at a persisted media row, so SwiftData autosave can cascade-insert it — the sheet tears it down on `.onDisappear` (deleting it if it was inserted), and `MediaLibraryViewModel.loadItems` additionally filters `list != nil`, so a collection can never leave a stray `ListItem` in the Movies/TV tabs. `onRemove` there means remove from the collection (`removeLabel`/`removeMessage`).
- Removal is deferred 5 s with an Undo toast (`commitPendingRemoval` flushed on `scenePhase == .background`). `refreshAllItems` also refreshes rows referenced only by lists.

### Upcoming Strip

`upcomingEntries(from:mediaType:)` in `MediaListHelpers.swift` builds the "Airing Soon" (TV) / "Coming Soon" (Movies) strip at the top of each watchlist tab. TV: any non-dropped show (watched or not) with `nextEpisodeAirDate` ≥ today; movies: unwatched with `releaseDate` > today. Only dates within the next 30 days qualify (TMDB reports placeholder premieres far out). Sorted soonest-first, capped at 12, ids namespaced `upcoming:<mediaID>`. `TVShow` stores `nextEpisodeSeason/Number/Name` and `status` (from TMDB `next_episode_to_air` / `status`) — cards and the detail chip render `"S3E2 · Jun 15"`, and the detail shows an Ended/Canceled/Returning chip. Relative day labels come from `AirDateFormat.relativeLabel` (UTC day math, consistent with the parser); any date outside the current year renders with the year ("Jul 8, 2027"). Pull-to-refresh calls `MediaLibraryViewModel.refreshNow()`, which bypasses the 6-hour interval and cancels any in-flight launch refresh.

### Image Caching

`CachedAsyncImage` uses `NSCache` (200 items, 100 MB). Prevents reloads on view recreation.

### Data Integrity

- `Movie`/`TVShow` store `backdropPath` (optional) for the detail-sheet header; the poster is the fallback.
- `networks` is an **unordered** SwiftData relationship — never render it raw. `displayOrderedNetworks(_:categories:)` (`MediaItem.swift`; also `MediaItemProtocol.orderedNetworks`) gives the stable order (stream → ads → rent → buy, then name, then id); `MediaCardView` and `DetailProviderRow` sort internally so callers can pass the raw array.
- `update(from:)` only reassigns `networks` when providers actually changed, deleting `Network` rows nothing else references. Deleting a `ListItem`/`CustomListItem` deletes its media row when nothing else points at it (`deleteMediaIfUnreferenced`).
- Swipe-delete is deferred 5 s for Undo; it's flushed on `scenePhase == .background`.
- Full refresh (`refreshAllItems`) matches results by TMDB id, never array index, and only stamps `lastFullRefreshDate` when at least one fetch succeeded.

## App Store Screenshots

DEBUG builds accept `--screenshots` (see `ScreenshotMode.swift`): the app uses an in-memory, non-CloudKit store, preselects six providers, skips onboarding, and seeds a curated set of real TMDB titles (with season progress, ratings, and two collections) through the normal view-model APIs. `--tab tvShows|movies|collections|discover` picks the tab, `--open <tmdbID>` presents a TV show's detail sheet, `--collection <name>` drills into that collection. Capture with the simulator: build for `platform=iOS Simulator`, `simctl install`, `simctl status_bar … override --time 9:41`, `simctl launch <udid> com.erichermanson.upnext --screenshots --tab …`, wait for seeding (~100 s; the DEBUG `seedStubData` fallback runs first on an empty store and is purged), then `simctl io <udid> screenshot`. Required sizes: iPhone 17 Pro Max (1320×2868) and iPad Pro 13" (2064×2752). Nothing here compiles into Release.

## CI/CD (Xcode Cloud)

`ci_scripts/ci_post_clone.sh`:
1. Generates `Info.plist` from template using `$TMDB_API_KEY` env var
2. Sets the build number (`CURRENT_PROJECT_VERSION`) from `$CI_BUILD_NUMBER`

`MARKETING_VERSION` is managed manually in the project (currently 1.7). To release a new version, bump `MARKETING_VERSION` in `project.pbxproj`, commit, and push.

**Important**: Distribution Preparation must be set to "App Store Connect" to select a build for distribution.
