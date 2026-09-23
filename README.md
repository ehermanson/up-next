# Up Next

Just a fun personal project to replace the running list of movies and TV shows my wife and I kept in the Notes app for years. Now with shared watchlist support so we can watch together.

## Features

- **Appearance**: Dark by default, with Light and System options in Settings. Your choice is saved on this device.

- **Manage your watchlist**: Track movies and TV shows you want to watch, mark them as watched, and leave notes. Watched starts collapsed, with a tappable count and chevron; each tab remembers its own expansion preference on this device. Expanding and collapsing animates smoothly, respecting Reduce Motion. Moving a title to Watched offers Undo without opening the section.
- **Watching**: Keep multiple TV shows above Up Next with Start Watching in the detail view, swipe actions, or context menu. Catching up preserves Watching; moving a show back preserves season progress. Upcoming episode dates appear on Watching rows, while Returning Soon highlights season premieres for other caught-up shows. Movies and collections keep their existing behavior.
- **Readable descriptions**: The title’s description and cast appear above seasons and tracking controls. Short overflows show in full automatically; “more” appears only when a description exceeds its usual limit by more than one line.
- **Season tracking**: For TV shows, mark each season watched independently using the dedicated circle controls (or mark the whole show watched at once), and browse every episode's title, description, air date and rating. Trailer appears above the seasons. A labeled season ratings chart compares one TMDB score per season, with a dotted reference line for the average of the displayed season ratings. Season rows show TMDB season scores and tiny episode-rating bars with a dashed episode-average line for quick comparison; tap a strip to open the episodes. A compact episode ratings chart shows the episode average and lets you jump straight to an episode; scroll horizontally on iPhone or see more at once on iPad
- **Collections**: Create custom collections (Christmas movies, kid-friendly, guilty pleasures, etc.). Suggestions appear inside each collection with one-tap adding. Jev ranks TMDB candidates against the exact collection name and member titles, with cached scores and a TMDB fallback. Adding a suggestion keeps the row stable until you reopen or rename the collection.
- **Discover**: Search, browse trending titles, see what's airing this week (with the exact episode and day), and get personalized recommendations
- **Provider filtering**: See only titles available on your streaming services, by region
- **Shared watchlist**: Share your entire watchlist with one other person (Apple Account) — changes sync across devices. Settings is reachable from every tab; once they join, the toolbar gear becomes the shared-with-people symbol, and each title's detail shows who added it and when
- **Activity notifications**: "Sarah added Elf to Movies" as a notification when the app is closed, or a toast while it's open — only for the other person's edits, never your own devices
- **Updating from 1.7**: The first launch offers to bring your Up Next lists over (titles, watched seasons, ratings, notes and collections). The old data is left in place, and you can run the import later from Settings.
- **Metadata**: Ratings, cast, descriptions, season/episode totals, and where to watch pulled from The Movie Database (TMDB) — the detail sheet leads with the services you subscribe to and tucks the rest behind a “+N” tap. Show details let you browse every season before adding a title, including from search and collections.

## Tech

- **Native iOS app** (Swift/SwiftUI, iOS 26.1+)
- **Core Data + CloudKit**: Local persistence with optional sharing (one person owns the shared watchlist; the other gets read-write access to it through their own iCloud account)
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
   Then replace `YOUR_API_KEY_HERE` with your TMDB API key. Set `TYPESAFE_API_KEY` in the same plist to enable Jev Collection ranking (leave blank for TMDB-only suggestions). This local file is gitignored. In Xcode Cloud, set `TMDB_API_KEY` and `TYPESAFE_API_KEY` as secret workflow environment variables; `ci_post_clone.sh` writes both into the app configuration. These credentials are bundled into the app, just like the existing TMDB key.

3. **Add CloudKit container** (required for sharing):
   - Open `Up Next.xcodeproj`
   - Select the Up Next target → Signing & Capabilities
   - Click "+ Capability" → iCloud
   - Add container: `iCloud.com.erichermanson.upnext.shared`

### Building & Running

```bash
open "Up Next.xcodeproj"
```

Then select the `Up Next` scheme and run on an iOS 26.1+ simulator or device.

**Simulator note**: Unsigned simulator builds (e.g., CI) must be launched with `--no-cloudkit` because CloudKit requires the `icloud-services` entitlement.

## Sharing Your Watchlist

### As the owner (the first person to use the app)

1. Settings → Sharing → "Share Your Watchlist"
2. Select who to share with (Messages, Mail, AirDrop, etc.)
3. They get a link and tap it to accept

### As the other person (accepting the share)

1. Tap the share link from Messages, Mail, etc.
2. The app opens and asks you to confirm — joining replaces your own watchlist across your Apple Account (it tells you exactly how many titles and collections)
3. Once you tap Join, the shared watchlist syncs down
4. You can add, edit, and remove titles just like the owner
5. Changes sync within seconds to minutes; the app asks for notification permission once sharing is live so you hear about each other's edits (deletions aren't announced)
6. Streaming services are shared too — it's one household. Either of you can change them in Settings → Streaming Services and the other sees the same set (the row reads "Shared with <name>"). Region stays per device.

### Leaving or stopping

- **Leaving**: Settings → Sharing → "Leave Shared Watchlist"
- **Owner stopping**: Settings → Sharing → Manage → Stop Sharing (the owner keeps everything; the other person is told, their copy is removed and they start over with an empty watchlist of their own — keeping the streaming services they were using)

## Development Notes

- No third-party dependencies — networking and persistence handled natively
- CloudKit sharing is zone-based; one share rooted at the app's `WatchListGroup`, everything else flows from there
- See `CLAUDE.md` for architecture details, file structure, and development patterns
- App Store screenshots are generated via DEBUG screenshot mode (`--screenshots` launch argument)

### Collection recommendation experiment

A standalone Jev evaluation compares real TMDB candidates across six test Collections, including the Anchorman/Dodgeball regression. See [the experiment guide](experiments/collection_recommendations/README.md). It uses `TYPESAFE_API_KEY` from the gitignored `.env.jev.local` and the existing TMDB configuration (or `TMDB_API_KEY`). Run `python3 experiments/collection_recommendations/evaluate.py prepare`, then `python3 experiments/collection_recommendations/evaluate.py run --batch-size 6`. Reports and cached responses stay in `.local/jev-eval/`; the experiment runs independently of the app. The app uses the same small-batch scoring approach for movies and TV, without experimental keyword scoring.

Legacy-store reader check (needs a copy of a 1.x `Watch_List.store`; see `experiments/legacy_import/README.md`):

```bash
swiftc -parse-as-library "Up Next/Services/LegacyStoreReader.swift" experiments/legacy_import/RuntimeChecks.swift -o /tmp/legacy-checks
/tmp/legacy-checks /path/to/Watch_List.store
```

Runtime networking checks (mock responses, no API charges):

```bash
swiftc -parse-as-library "Up Next/Services/JevRecommendationService.swift" experiments/collection_recommendations/RuntimeChecks.swift -o /tmp/up-next-jev-checks
/tmp/up-next-jev-checks
```
