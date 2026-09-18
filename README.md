# Up Next

Just a fun personal project to replace the running list of movies and TV shows my wife and I kept in the Notes app for years. Now with shared library support so we can watch together.

## Features

- **Appearance**: Dark by default, with Light and System options in Settings. Your choice is saved on this device.

- **Manage your watchlist**: Track movies and TV shows you want to watch, mark them as watched, and leave notes. Watched starts collapsed, with a tappable count and chevron; each tab remembers its own expansion preference on this device. Expanding and collapsing animates smoothly, respecting Reduce Motion. Moving a title to Watched offers Undo without opening the section.
- **Watching**: Keep multiple TV shows above Up Next with Start Watching in the detail view, swipe actions, or context menu. Catching up preserves Watching; moving a show back preserves season progress. Upcoming episode dates appear on Watching rows, while Returning Soon highlights season premieres for other caught-up shows. Movies and collections keep their existing behavior.
- **Readable descriptions**: The title’s description and cast appear above seasons and tracking controls. Short overflows show in full automatically; “more” appears only when a description exceeds its usual limit by more than one line.
- **Season tracking**: For TV shows, mark each season watched independently using the dedicated circle controls (or mark the whole show watched at once), and browse every episode's title, description, air date and rating. A compact chart above the season list compares one TMDB score per season. Season rows show TMDB season scores and tiny episode-rating bars with a dashed episode-average line for quick comparison; tap a strip to open the episodes. A compact episode ratings chart shows the episode average and lets you jump straight to an episode; scroll horizontally on iPhone or see more at once on iPad
- **Collections**: Create custom collections (Christmas movies, kid-friendly, guilty pleasures, etc.)
- **Discover**: Search, browse trending titles, see what's airing this week (with the exact episode and day), and get personalized recommendations
- **Provider filtering**: See only titles available on your streaming services, by region
- **Shared library**: Share your entire library with one partner (Apple Account) — changes sync across devices. Settings is reachable from every tab; once a partner joins, the toolbar button becomes your two avatars, and each title's detail shows who added it and when
- **Partner notifications**: "Sarah added Elf to Movies" as a notification when the app is closed, or a toast while it's open — only for the other person's edits, never your own devices
- **Metadata**: Ratings, cast, descriptions, and where to watch pulled from The Movie Database (TMDB)

## Tech

- **Native iOS app** (Swift/SwiftUI, iOS 26.1+)
- **Core Data + CloudKit**: Local persistence with optional sharing (one person owns the shared library; the partner gets read-write access to it through their own iCloud account)
- **TMDB API**: For media metadata and discovery
- **No analytics, no ads, no accounts** — just your data

## Setup

### Before running

1. **Get a TMDB API key**:
   - Visit [https://www.themoviedb.org/settings/api](https://www.themoviedb.org/settings/api)
   - Copy your API key

2. **Create Info.plist**:
   ```bash
   cp "Up Next/Info.plist.template" "Up Next/Info.plist"
   ```
   Then replace `YOUR_API_KEY_HERE` with your TMDB API key

3. **Add CloudKit container** (required for sharing):
   - Open `Up Next.xcodeproj`
   - Select the Up Next target → Signing & Capabilities
   - Click "+ Capability" → iCloud
   - Add container: `iCloud.com.erichermanson.upnext.shared`

### Building & Running

```bash
open "Up Next.xcodeproj"
```

Then select the Up Next scheme and run on an iOS 26.1+ simulator or device.

**Simulator note**: Unsigned simulator builds (e.g., CI) must be launched with `--no-cloudkit` because CloudKit requires the `icloud-services` entitlement.

## Sharing Your Library

### As the owner (the first person to use the app)

1. Settings → Sharing → "Share with a partner"
2. Select who to share with (Messages, Mail, AirDrop, etc.)
3. Your partner gets a link; they tap it to accept

### As a partner (accepting the share)

1. Tap the share link from Messages, Mail, etc.
2. The app opens and asks you to confirm — joining replaces anything already in your own library on that device (it tells you exactly how many titles and collections)
3. Once you tap Join, your partner's library syncs down
4. You can add, edit, and remove titles just like the owner
5. Changes sync within seconds to minutes; the app asks for notification permission once sharing is live so you hear about each other's edits (deletions aren't announced)

### Leaving or stopping

- **Partner leaving**: Settings → Sharing → "Leave shared library"
- **Owner stopping**: Settings → Sharing → Manage → Stop Sharing (the owner keeps everything; the partner's copy is removed and they start over with an empty library of their own)

## Development Notes

- No third-party dependencies — networking and persistence handled natively
- CloudKit sharing is zone-based; one share rooted at the app's `WatchListGroup`, everything else flows from there
- See `CLAUDE.md` for architecture details, file structure, and development patterns
- App Store screenshots are generated via DEBUG screenshot mode (`--screenshots` launch argument)
