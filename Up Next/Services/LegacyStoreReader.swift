import Foundation
import SQLite3

/// Media namespace of a legacy title. Deliberately its own type rather than the app's `MediaType`:
/// this file is pure Foundation + SQLite so it can be compiled and exercised on its own.
nonisolated enum LegacyMediaType: String, Sendable {
    case tvShow
    case movie
}

/// Everything the 1.x (SwiftData-backed) store holds that 2.0 can re-create: the two watchlists,
/// the user's collections, and the per-title state attached to both. Value types only, so the read
/// can happen off the main actor and the result be handed back.
nonisolated struct LegacyLibrary: Sendable {
    struct Title: Sendable, Hashable {
        let tmdbID: Int
        let mediaType: LegacyMediaType
        let title: String
        /// 1.x stored the fully-qualified image URL rather than TMDB's path.
        let posterURL: URL?
        let backdropPath: String?

        /// The TMDB-style `/abc.jpg` path `posterURL` was built from — what the search-result
        /// mappers expect when a detail fetch fails and the importer has to fall back to a stub.
        var posterPath: String? {
            guard let posterURL else { return nil }
            let file = posterURL.lastPathComponent
            guard !file.isEmpty, file != "/" else { return nil }
            return file.hasPrefix("/") ? file : "/" + file
        }
    }

    struct ListEntry: Sendable {
        let title: Title
        let isWatched: Bool
        let watchedAt: Date?
        let droppedAt: Date?
        let order: Int
        let watchedSeasons: [Int]
        let userRating: Int?
        let userNotes: String?
        let addedAt: Date
        /// Name of the parent `ZMEDIALIST` row, or nil when the item had none. 1.x persisted a
        /// list-less item for every detail sheet opened from a collection or Discover — 2.0 does
        /// the same and filters them out with `list != nil` — so a nil name marks a leftover
        /// wrapper rather than something the user put on a watchlist.
        let listName: String?

        var isLibraryEntry: Bool { listName != nil }
    }

    struct CollectionEntry: Sendable {
        let title: Title
        let addedAt: Date
        let watchedAt: Date?
    }

    struct Collection: Sendable {
        let name: String
        let iconName: String
        let createdAt: Date
        let entries: [CollectionEntry]
    }

    /// Counts for the offer sheet. Only entries that were really on a watchlist are counted —
    /// the leftover wrappers described on `ListEntry.listName` are not offered for import.
    struct Summary: Sendable {
        let tvShowCount: Int
        let movieCount: Int
        let collectionCount: Int
        let collectionItemCount: Int
        let skipped: Int

        var isEmpty: Bool { tvShowCount == 0 && movieCount == 0 && collectionCount == 0 }
    }

    /// Every TV entry in the store, watchlist members first (in their stored order).
    let tvShows: [ListEntry]
    /// Every movie entry in the store, watchlist members first (in their stored order).
    let movies: [ListEntry]
    let collections: [Collection]
    /// Rows that referenced no title, or a title whose TMDB id didn't parse.
    let skipped: Int

    /// The entries the importer actually brings over: watchlist members, TV before movies.
    var libraryEntries: [ListEntry] {
        tvShows.filter(\.isLibraryEntry) + movies.filter(\.isLibraryEntry)
    }

    var summary: Summary {
        Summary(
            tvShowCount: tvShows.count(where: \.isLibraryEntry),
            movieCount: movies.count(where: \.isLibraryEntry),
            collectionCount: collections.count,
            collectionItemCount: collections.reduce(0) { $0 + $1.entries.count },
            skipped: skipped
        )
    }
}

/// Reads the Up Next 1.x store directly with SQLite. 1.x used SwiftData over a Core Data-shaped
/// SQLite file, so there is no model to load — the table layout below is the contract.
///
/// The store is only ever opened read-only, and never the original file if that fails: a WAL
/// database needs a writable `-shm` sidecar, so the fallback copies the three files aside and
/// reads the copy.
nonisolated enum LegacyStoreReader {
    enum ReadError: LocalizedError {
        case missingStore(String)
        case cannotOpen(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingStore:
                return "Nothing from the previous version of Up Next was found on this device."
            case .cannotOpen(let message), .queryFailed(let message):
                return "The data from the previous version of Up Next couldn’t be read. (\(message))"
            }
        }
    }

    /// 1.x kept its store directly in Application Support — *not* in the `UpNext/` subdirectory
    /// the 2.0 stack uses, so the two never collide.
    static func defaultStoreURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appendingPathComponent("Watch_List.store")
    }

    static func storeExists(at url: URL = defaultStoreURL()) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func read(at url: URL = defaultStoreURL()) throws -> LegacyLibrary {
        guard storeExists(at: url) else { throw ReadError.missingStore(url.path) }
        do {
            return try withDatabase(at: url, perform: readLibrary)
        } catch {
            let copy = try copyAside(url)
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            return try withDatabase(at: copy, perform: readLibrary)
        }
    }

    // MARK: - SQLite plumbing

    private static func withDatabase<T>(
        at url: URL,
        perform body: (OpaquePointer) throws -> T
    ) throws -> T {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(handle)
            throw ReadError.cannotOpen(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    /// Copies the store and its WAL sidecars into a throwaway directory. The originals are left
    /// untouched so a 1.x reinstall can still read them.
    private static func copyAside(_ url: URL) throws -> URL {
        let manager = FileManager.default
        let directory = URL.temporaryDirectory
            .appendingPathComponent("legacy-import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try manager.copyItem(at: url, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: sidecar.path) else { continue }
            try? manager.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }

    // MARK: - Reading

    private static func readLibrary(from db: OpaquePointer) throws -> LegacyLibrary {
        let listNames = try readListNames(from: db)
        let tvTitles = try readTitles(from: db, table: "ZTVSHOW", mediaType: .tvShow)
        let movieTitles = try readTitles(from: db, table: "ZMOVIE", mediaType: .movie)

        var skipped = 0
        var tvShows: [LegacyLibrary.ListEntry] = []
        var movies: [LegacyLibrary.ListEntry] = []

        let items = try Statement(db: db, sql: """
            SELECT ZISWATCHED, ZORDER, ZUSERRATING, ZLIST, ZMOVIE, ZTVSHOW, \
            ZADDEDAT, ZDROPPEDAT, ZWATCHEDAT, ZUSERNOTES, ZWATCHEDSEASONS FROM ZLISTITEM
            """)
        while items.step() {
            guard let title = resolveTitle(
                tvPK: items.optionalInt(5), moviePK: items.optionalInt(4),
                tv: tvTitles, movies: movieTitles
            ) else {
                skipped += 1
                continue
            }
            let entry = LegacyLibrary.ListEntry(
                title: title,
                isWatched: items.optionalInt(0) == 1,
                watchedAt: items.date(8),
                droppedAt: items.date(7),
                order: items.optionalInt(1) ?? 0,
                watchedSeasons: decodeSeasons(items.blob(10)),
                userRating: items.optionalInt(2),
                userNotes: items.text(9),
                addedAt: items.date(6) ?? .distantPast,
                listName: items.optionalInt(3).flatMap { listNames[$0] }
            )
            // Route by media type rather than by list name: a movie in the "TV Shows" list (or in
            // no list at all) still only makes sense on the movies side.
            if title.mediaType == .tvShow {
                tvShows.append(entry)
            } else {
                movies.append(entry)
            }
        }

        let collections = try readCollections(from: db, tv: tvTitles, movies: movieTitles, skipped: &skipped)

        return LegacyLibrary(
            tvShows: sorted(tvShows),
            movies: sorted(movies),
            collections: collections,
            skipped: skipped
        )
    }

    private static func readListNames(from db: OpaquePointer) throws -> [Int: String] {
        var names: [Int: String] = [:]
        let statement = try Statement(db: db, sql: "SELECT Z_PK, ZNAME FROM ZMEDIALIST")
        while statement.step() {
            guard let name = statement.text(1), !name.isEmpty else { continue }
            names[statement.int(0)] = name
        }
        return names
    }

    /// Indexes a media table by primary key. Roughly half of these rows are orphans in a real
    /// store, which is why every caller walks in from `ZLISTITEM` / `ZCUSTOMLISTITEM` instead.
    private static func readTitles(
        from db: OpaquePointer, table: String, mediaType: LegacyMediaType
    ) throws -> [Int: LegacyLibrary.Title] {
        var titles: [Int: LegacyLibrary.Title] = [:]
        let statement = try Statement(
            db: db, sql: "SELECT Z_PK, ZID, ZTITLE, ZTHUMBNAILURL, ZBACKDROPPATH FROM \(table)"
        )
        while statement.step() {
            guard let rawID = statement.text(1), let tmdbID = Int(rawID), tmdbID > 0 else { continue }
            titles[statement.int(0)] = LegacyLibrary.Title(
                tmdbID: tmdbID,
                mediaType: mediaType,
                title: statement.text(2) ?? "",
                posterURL: statement.text(3).flatMap(URL.init(string:)),
                backdropPath: statement.text(4)
            )
        }
        return titles
    }

    private static func readCollections(
        from db: OpaquePointer,
        tv: [Int: LegacyLibrary.Title],
        movies: [Int: LegacyLibrary.Title],
        skipped: inout Int
    ) throws -> [LegacyLibrary.Collection] {
        var entries: [Int: [LegacyLibrary.CollectionEntry]] = [:]
        let items = try Statement(db: db, sql: """
            SELECT ZCUSTOMLIST, ZMOVIE, ZTVSHOW, ZADDEDAT, ZWATCHEDAT FROM ZCUSTOMLISTITEM
            """)
        while items.step() {
            guard let listPK = items.optionalInt(0) else {
                skipped += 1
                continue
            }
            guard let title = resolveTitle(
                tvPK: items.optionalInt(2), moviePK: items.optionalInt(1), tv: tv, movies: movies
            ) else {
                skipped += 1
                continue
            }
            entries[listPK, default: []].append(LegacyLibrary.CollectionEntry(
                title: title,
                addedAt: items.date(3) ?? .distantPast,
                watchedAt: items.date(4)
            ))
        }

        var collections: [LegacyLibrary.Collection] = []
        let lists = try Statement(
            db: db, sql: "SELECT Z_PK, ZNAME, ZICONNAME, ZCREATEDAT FROM ZCUSTOMLIST"
        )
        while lists.step() {
            guard let name = lists.text(1), !name.isEmpty else {
                skipped += 1
                continue
            }
            let members = (entries[lists.int(0)] ?? []).sorted { $0.addedAt < $1.addedAt }
            collections.append(LegacyLibrary.Collection(
                name: name,
                iconName: lists.text(2) ?? "list.bullet",
                createdAt: lists.date(3) ?? .distantPast,
                entries: members
            ))
        }
        return collections.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Decoding helpers

    private static func resolveTitle(
        tvPK: Int?, moviePK: Int?,
        tv: [Int: LegacyLibrary.Title], movies: [Int: LegacyLibrary.Title]
    ) -> LegacyLibrary.Title? {
        if let tvPK { return tv[tvPK] }
        if let moviePK { return movies[moviePK] }
        return nil
    }

    /// `ZWATCHEDSEASONS` is an `NSKeyedArchiver` plist of an `NSArray` of `NSNumber`. Returned
    /// sorted — 1.x wrote them in tap order, not season order.
    private static func decodeSeasons(_ data: Data?) -> [Int] {
        guard let data, !data.isEmpty else { return [] }
        let unarchived = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSNumber.self], from: data
        )
        guard let numbers = unarchived as? [NSNumber] else { return [] }
        return numbers.map(\.intValue).sorted()
    }

    /// Watchlist members first (by their stored order), leftover wrappers after them, so a caller
    /// that does take everything still sees the real list in the order the user arranged it.
    private static func sorted(_ entries: [LegacyLibrary.ListEntry]) -> [LegacyLibrary.ListEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isLibraryEntry != rhs.isLibraryEntry { return lhs.isLibraryEntry }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.addedAt < rhs.addedAt
        }
    }
}

// MARK: - Statement

/// Minimal RAII wrapper around a prepared statement — nothing is bound, so stepping and reading
/// columns is the whole surface.
private nonisolated final class Statement {
    private var handle: OpaquePointer?

    init(db: OpaquePointer, sql: String) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, handle != nil else {
            throw LegacyStoreReader.ReadError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit { sqlite3_finalize(handle) }

    func step() -> Bool { sqlite3_step(handle) == SQLITE_ROW }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }

    func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }

    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: bytes)
    }

    /// Core Data timestamps are seconds since the 2001 reference date.
    func date(_ column: Int32) -> Date? {
        guard !isNull(column) else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(handle, column))
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}
