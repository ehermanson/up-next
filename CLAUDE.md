# CLAUDE.md

Native iOS app (Swift/SwiftUI, iOS 26+) for managing movie and TV show watchlists. Xcode project (`Up Next.xcodeproj`), no CLI build. No tests.

## Setup

`Up Next/Info.plist` is gitignored (contains TMDB API key):
```bash
cp "Up Next/Info.plist.template" "Up Next/Info.plist"
```
Then replace `YOUR_API_KEY_HERE` with a real TMDB API key.
