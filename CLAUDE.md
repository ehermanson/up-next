# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Native iOS app (Swift/SwiftUI, iOS 26+) for managing movie and TV show watchlists. Uses TMDB API for metadata, SwiftData for local persistence, and Liquid Glass for UI surfaces. No external dependencies.

## Build & Run

This is an Xcode project (`Watch List.xcodeproj`). There is no command-line build configured.

- **Build/Run:** Open in Xcode, ⌘B to build, ⌘R to run
- **No tests exist** — the test target is empty

## Setup Requirement

`Watch List/Info.plist` is gitignored (contains TMDB API key). To set up:
```bash
cp "Watch List/Info.plist.template" "Watch List/Info.plist"
```
Then replace `YOUR_API_KEY_HERE` with a real TMDB API key.

## Architecture

**Pattern:** MVVM with SwiftData persistence

**Data flow:**
```
TMDB API → TMDBService (actor singleton) → MediaLibraryViewModel (@MainActor) → SwiftUI Views → SwiftData
```

### Key layers:

- **Models** (`MediaItem.swift`, `ListItem.swift`, `MediaList.swift`): SwiftData `@Model` classes. `Movie` and `TVShow` conform to a shared `MediaItemProtocol`. `ListItem` wraps media items with watch state and ordering.
- **Service** (`TMDBService.swift`): Actor-based singleton for all TMDB API calls (search, details, watch providers, images). Uses `nonisolated` for thread-safe URL helpers. JSON decoding uses `.convertFromSnakeCase`.
- **ViewModel** (`MediaLibraryViewModel.swift`): Single `@MainActor` observable managing all UI state — tracked lists of TV shows and movies, persistence operations, watched/unwatched toggling.
- **Views**: Tab-based UI (TV Shows / Movies). `ContentView` manages navigation and sheet presentation. `SearchView` handles debounced async search. `MediaDetailView` shows full item details. `MediaListView` displays unwatched (draggable) and watched (collapsible) sections.

### API response models

`TMDBModels.swift` contains `Decodable` structs for TMDB API responses — these are separate from the SwiftData persistence models. The service maps API responses to SwiftData models.

### UI components

Files in `Watch List/UI/`: `NetworkLogosView` (streaming provider logos), `LiquidGlassCircleButtonStyle` (glass morphism button effect).

## Conventions

- All SwiftData models use `@Model final class`
- ViewModels are `@MainActor @Observable`
- API service uses Swift `actor` for concurrency safety
- Views use `@StateObject` / `@Binding` for state propagation
- Async work in views uses `.task {}` modifier
- Search uses `Task` cancellation for debouncing
