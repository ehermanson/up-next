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
| My Lists | `MyListsView` | `CustomListViewModel` |
| Discover | `DiscoverView` | `DiscoverViewModel` |

## File Map

```
Up Next/
├── App/
│   ├── Watch_ListApp.swift              # @main entry, SwiftData schema registration
│   └── ContentView.swift                # Tab navigation (TV Shows, Movies, My Lists, Discover)
│
├── Models/                              # SwiftData @Model classes
│   ├── MediaItem.swift                  # Movie, TVShow, Network models
│   ├── ListItem.swift                   # Watchlist item (refs Movie or TVShow, tracks watched state)
│   ├── MediaList.swift                  # Watchlist container
│   ├── CustomList.swift                 # User-created collection (name, icon)
│   ├── CustomListItem.swift             # Item in a custom list
│   ├── UserIdentity.swift               # User attribution for CloudKit sharing
│   └── WatchListGroup.swift             # Root CloudKit sharing object
│
├── ViewModels/
│   ├── MediaLibraryViewModel.swift      # Main watchlist state, add/remove, refresh, reorder
│   ├── DiscoverViewModel.swift          # Carousels (trending, airing this week / in theaters, top rated, new), browse, provider filter, error state
│   └── CustomListViewModel.swift        # CRUD for custom lists and their items
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
│   │   └── MediaDetailSimilar.swift     # Similar/recommended sections, collection section
│   ├── Search/
│   │   ├── WatchlistSearchView.swift    # Context-aware search (all, TV, movies, specific lists)
│   │   ├── RecommendationEngine.swift   # Seed selection, aggregation, thematic scoring
│   │   └── SearchComponents.swift       # Loading states and utility views
│   ├── Discover/
│   │   └── DiscoverView.swift           # Browse/discover tab with carousels and filters
│   ├── Lists/
│   │   ├── MyListsView.swift            # Custom lists overview
│   │   ├── CustomListDetailView.swift   # Items in a custom list
│   │   ├── CreateListView.swift         # Create/edit list dialog with icon picker
│   │   └── AddToListSheet.swift         # Add item to a custom list
│   └── Settings/
│       └── ProviderSettingsView.swift   # Streaming service selection
│
├── Services/
│   ├── TMDBService.swift                # TMDB API client (singleton): search, details, providers, discover
│   ├── TMDBModels.swift                 # Codable structs for TMDB API responses
│   └── ProviderSettings.swift           # UserDefaults-backed streaming provider preferences
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
├── Assets.xcassets                      # App icons, colors, images
├── Info.plist.template                  # Template with TMDB_API_KEY placeholder
├── Up Next.entitlements                 # CloudKit + APS entitlements
├── PrivacyInfo.xcprivacy                # Privacy manifest (no tracking)
└── Watch_List.xcdatamodeld/             # Legacy CoreData model (unused, can ignore)

ci_scripts/
└── ci_post_clone.sh                     # Xcode Cloud: generates Info.plist, sets build number
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
- Region-aware lookups via `Locale.current.region`, fallback to US

### "On My Services" (ProviderSettings)

`ProviderSettings` (UserDefaults-backed, `@Observable` singleton) drives three things:
- **Discover**: `onlyMyServicesInDiscover` (key `discover.onlyMyServices`, default on) sends `with_watch_providers` + `watch_region` on every carousel/browse request via `DiscoverViewModel.providerFilter`. The toggle row under the media-type picker becomes a "Choose your streaming services" button when nothing is selected.
- **Watchlist filter**: per-tab `@AppStorage` flags `tvShows.onlyMyServices` / `movies.onlyMyServices`, applied by `filterItems(...)` in `MediaListHelpers.swift` (`isOnSelectedServices` = any network with category `stream`/`ads` whose id is selected). Auto-cleared if the user deselects all providers.
- **First launch**: `ContentView` presents `ProviderSettingsView` once when no providers are selected and `hasCompletedProviderOnboarding` is false; the flag is set on presentation so it never re-prompts. The DEBUG "Reset Providers & Onboarding" button clears it.

### Discover Data Sources

- **Trending**: `/trending/{tv,movie}/week` when the provider filter is off; `/discover` `popularity.desc` + providers when it's on (`/trending` can't take `with_watch_providers`).
- **Airing This Week** (TV): `/discover/tv` with `air_date.gte/lte` = today…+7d, respects the provider filter. **In Theaters** (movies): `/movie/now_playing` with `region`, always shown.
- **New Releases**: `first_air_date.lte` / `primary_release_date.lte` = today so unreleased titles don't leak in. Dates are built with `TMDBService.apiDateString` (UTC).
- Errors surface as `carouselError` / `browseError` with a retry `EmptyStateView`; pull-to-refresh calls `reload()`. Responses still go through the 10-minute `RequestDeduplicator` cache.
- Search runs `/search/tv` and `/search/movie` concurrently; when the selected segment has no results but the other does, the empty state offers "Show N movies instead". Rows show the release/premiere year.

### Media IDs

TMDB movie and TV ids are separate namespaces. Any set that mixes both must use `MediaIDKey.make(mediaType, id)` (`"tv:123"` / `"movie:456"`) — see `MediaDetailSimilar.swift`.

### Design System (iOS 26 Liquid Glass)

- `.preferredColorScheme(.dark)` and `.fontDesign(.rounded)` are set once on the root in `Watch_ListApp.swift` — don't repeat them per view.
- Glass (`.glassEffect`, `.buttonStyle(.glass/.glassProminent)`) is reserved for the floating control layer: toolbar/tab bar, the toast, the detail sheet's action row, and empty-state CTAs. Content (rows, cards, pills, badges, logos, fields) uses `cardSurface` / `cellSurface` / `chipSurface` / `Chip` from `DesignTokens.swift`. No glass on glass.
- Use `Color.accentColor` for tints (asset `AccentColor`), `DesignTokens.Radius.*` for corner radii, and `DesignTokens.Colors.backgroundBase` when blending into `AppBackground`.
- Reorder in the watchlist is native `List` + `.onMove` driven by `editMode`.

### Watched State (TV Shows)

- `watchedSeasons`: Array of watched season numbers (1-based)
- `nextSeasonToWatch`: Computed from total seasons vs watched
- `syncWatchedStateFromSeasons()`: Auto-marks fully-watched shows
- `toggleSeason(_:)` cascades: marking S*n* marks 1…*n*; un-marking S*n* un-marks *n*…last
- Shows remain in unwatched list when partially watched
- Rows can be marked watched/unwatched (or "Pick Back Up" for dropped shows) via leading swipe or context menu — `MediaListView.toggleWatched` marks all seasons
- Watched section is sorted most-recently-watched first

### Upcoming Strip

`upcomingEntries(from:mediaType:)` in `MediaListHelpers.swift` builds the "Airing Soon" (TV) / "Coming Soon" (Movies) strip at the top of each watchlist tab. TV: any non-dropped show (watched or not) with `nextEpisodeAirDate` ≥ today; movies: unwatched with `releaseDate` > today. Only dates within the next 30 days qualify (TMDB reports placeholder premieres far out). Sorted soonest-first, capped at 12, ids namespaced `upcoming:<mediaID>`. `TVShow` stores `nextEpisodeSeason/Number/Name` and `status` (from TMDB `next_episode_to_air` / `status`) — cards and the detail chip render `"S3E2 · Jun 15"`, and the detail shows an Ended/Canceled/Returning chip. Relative day labels come from `AirDateFormat.relativeLabel` (UTC day math, consistent with the parser); any date outside the current year renders with the year ("Jul 8, 2027"). Pull-to-refresh calls `MediaLibraryViewModel.refreshNow()`, which bypasses the 6-hour interval and cancels any in-flight launch refresh.

### Image Caching

`CachedAsyncImage` uses `NSCache` (200 items, 100 MB). Prevents reloads on view recreation.

### Data Integrity

- `Movie`/`TVShow` store `backdropPath` (optional) for the detail-sheet header; the poster is the fallback.
- `update(from:)` only reassigns `networks` when providers actually changed, deleting `Network` rows nothing else references. Deleting a `ListItem`/`CustomListItem` deletes its media row when nothing else points at it (`deleteMediaIfUnreferenced`).
- Swipe-delete is deferred 5 s for Undo; it's flushed on `scenePhase == .background`.
- Full refresh (`refreshAllItems`) matches results by TMDB id, never array index, and only stamps `lastFullRefreshDate` when at least one fetch succeeded.

## CI/CD (Xcode Cloud)

`ci_scripts/ci_post_clone.sh`:
1. Generates `Info.plist` from template using `$TMDB_API_KEY` env var
2. Sets the build number (`CURRENT_PROJECT_VERSION`) from `$CI_BUILD_NUMBER`

`MARKETING_VERSION` is managed manually in the project (currently 1.6). To release a new version, bump `MARKETING_VERSION` in `project.pbxproj`, commit, and push.

**Important**: Distribution Preparation must be set to "App Store Connect" to select a build for distribution.
