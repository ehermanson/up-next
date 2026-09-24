# Up Next

Just a fun personal project to replace the running list of movies and TV shows my wife and I kept in the Notes app for years. Now with shared watchlist support so we can watch together.

## What it does

- **Watchlist**: Keep track of the movies and shows you want to watch, what you're watching now, and what you've finished.
- **Season tracking**: Mark TV seasons watched one at a time and browse every episode, with ratings for each season and episode.
- **Collections**: Group titles however you like (Christmas movies, kid-friendly, guilty pleasures), with suggestions for what else fits.
- **Discover**: Trending titles, what's airing this week, and recommendations based on your watchlist.
- **Your streaming services**: See where each title is streaming, and filter to the services you actually have.
- **Shared watchlist**: Share everything with one other person over iCloud. You both see the same watchlist, get notified when the other person makes changes, and can check what's changed recently in Activity.

Movie and TV data comes from [The Movie Database (TMDB)](https://www.themoviedb.org). No accounts, ads or analytics.

## Tech

Native Swift/SwiftUI for iOS 26.1+, with Core Data + CloudKit for storage and sharing. No third-party dependencies.

## Getting started

1. Get a [TMDB API key](https://www.themoviedb.org/settings/api).
2. `cp "Up Next/Info.plist.template" "Up Next/Info.plist"` and fill in `TMDB_API_KEY` (`Info.plist` is gitignored).
3. In Xcode, go to the Up Next target → Signing & Capabilities → iCloud and add the container `iCloud.com.erichermanson.upnext.shared`.
4. Open `Up Next.xcodeproj` and run the `Up Next` scheme.

See [AGENTS.md](AGENTS.md) for architecture and development notes.
