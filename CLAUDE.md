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
│   ├── DiscoverViewModel.swift          # Trending/top-rated/new carousels, browse with pagination
│   └── CustomListViewModel.swift        # CRUD for custom lists and their items
│
├── Views/
│   ├── Watchlist/
│   │   ├── MediaListView.swift          # Main list with genre/provider filtering, watched toggle
│   │   ├── ReorderableMediaList.swift   # UITableView wrapper for drag-to-reorder
│   │   └── MediaListHelpers.swift       # Helper functions for list display
│   ├── Detail/
│   │   └── MediaDetailView.swift        # Detail sheet: edit watched state, rating, notes, seasons
│   ├── Search/
│   │   ├── WatchlistSearchView.swift    # Context-aware search (all, TV, movies, specific lists)
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
│   ├── MediaCardView.swift              # Media item card (poster, title, metadata, networks)
│   ├── NetworkLogosView.swift           # Inline streaming provider logos with overflow badge
│   ├── CachedAsyncImage.swift           # AsyncImage wrapper with NSCache (200 items, 100 MB)
│   ├── SharedViews.swift                # ShimmerLoadingView, GlassEffectContainer, EmptyStateView, StarRatingLabel, etc.
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
└── ci_post_clone.sh                     # Xcode Cloud: generates Info.plist, sets MARKETING_VERSION & build number
```

## Key Patterns

### SwiftData Schema

Registered in `Watch_ListApp.swift`:
`Movie`, `TVShow`, `Network`, `MediaList`, `ListItem`, `UserIdentity`, `WatchListGroup`, `CustomList`, `CustomListItem`

CloudKit is optional — the app falls back to local-only if CloudKit is unavailable.

### Provider Logic (TMDBService)

- Curated list of real subscription services (Netflix, Prime, Disney+, HBO Max, etc.)
- Provider aliases normalize variants (e.g., "Netflix with Ads" → "Netflix")
- Network → Provider ID mapping (e.g., "AMC" network → AMC+ provider)
- Region-aware lookups via `Locale.current.region`, fallback to US

### Watched State (TV Shows)

- `watchedSeasons`: Array of watched season numbers (1-based)
- `nextSeasonToWatch`: Computed from total seasons vs watched
- `syncWatchedStateFromSeasons()`: Auto-marks fully-watched shows
- Shows remain in unwatched list when partially watched

### Image Caching

`CachedAsyncImage` uses `NSCache` (200 items, 100 MB). Prevents reloads on view recreation.

## CI/CD (Xcode Cloud)

`ci_scripts/ci_post_clone.sh`:
1. Generates `Info.plist` from template using `$TMDB_API_KEY` env var
2. Sets build number from `$CI_BUILD_NUMBER`
3. Sets `MARKETING_VERSION` directly in project.pbxproj (currently 1.3)

**Important**: Distribution Preparation must be set to "App Store Connect" to select a build for distribution.
