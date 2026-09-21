# Legacy import runtime checks

`RuntimeChecks.swift` exercises `Up Next/Services/LegacyStoreReader.swift` against a real Up Next
1.x store. The reader is pure Foundation + SQLite (no app types, no Core Data), so it compiles and
runs on its own — there is no Xcode test target to host this.

```bash
swiftc -parse-as-library "Up Next/Services/LegacyStoreReader.swift" \
  experiments/legacy_import/RuntimeChecks.swift -o /tmp/legacy-checks \
  && /tmp/legacy-checks /tmp/wl.store
```

The path argument defaults to `/tmp/wl.store`. The store (plus any `-wal` / `-shm` siblings) is
copied to a temporary directory before it is opened, so the original is never touched.

Success prints `Legacy reader checks passed` and exits 0; every failed expectation is written to
stderr and the exit status is non-zero.

## What the reference store contains

A copy of a real 1.7 library (33 `ZLISTITEM` rows, 95 TV rows, 113 movie rows, one collection):

- 17 of the 33 list items are on a watchlist — 9 in "TV Shows", 8 in "Movies".
- The other 16 have no parent list. 1.x persisted a list-less item for every detail sheet opened
  from a collection or Discover (2.0 does the same and filters them with `list != nil`), so they
  are leftover wrappers, not titles the user added. `LegacyLibrary.ListEntry.isLibraryEntry` is
  false for them and `LegacyImporter` skips them.
- One collection, "Christmas Stuff" (icon `gift`), with 4 entries.
- Season progress goes up to 4 marked seasons; one entry stored them out of order, so the reader
  sorts them.
- Most `ZMOVIE` / `ZTVSHOW` rows are orphans, which is why the reader walks in from `ZLISTITEM`
  and `ZCUSTOMLISTITEM` rather than from the media tables.
