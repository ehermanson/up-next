import Foundation

/// Runtime checks for `LegacyStoreReader` against a real Up Next 1.x store. Compiled together
/// with the reader (which is pure Foundation + SQLite, no app types) so the parsing can be
/// exercised without building or running the app. See `README.md` for the command.
///
/// The store is copied to a temporary directory first — the checks never touch the original.
@main
enum LegacyReaderChecks {
    static func main() {
        exit(run())
    }

    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    private static func copyStoreAside(_ path: String) throws -> URL {
        let manager = FileManager.default
        let directory = URL.temporaryDirectory
            .appendingPathComponent("legacy-checks-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try manager.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: path + suffix)
            guard manager.fileExists(atPath: sidecar.path) else { continue }
            try manager.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func run() -> Int32 {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/wl.store"
        let copy: URL
        do {
            copy = try copyStoreAside(path)
        } catch {
            return fail("Couldn't copy \(path): \(error)")
        }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        let library: LegacyLibrary
        do {
            library = try LegacyStoreReader.read(at: copy)
        } catch {
            return fail("Read failed: \(error)")
        }

        let entries = library.tvShows + library.movies
        let summary = library.summary

        // Both 1.x watchlists resolved, so every watchlist member carries a list name.
        let listNames = Set(entries.compactMap(\.listName))
        expect(listNames == ["TV Shows", "Movies"],
               "expected both media lists, got \(listNames.sorted())")

        expect(entries.count == 33, "expected 33 list items, got \(entries.count)")
        // 16 of those 33 are 1.x detail-sheet wrappers with no parent list; the importer skips them.
        expect(summary.tvShowCount + summary.movieCount == 17,
               "expected 17 watchlist members, got \(summary.tvShowCount + summary.movieCount)")

        expect(library.collections.count == 1,
               "expected 1 collection, got \(library.collections.count)")
        if let collection = library.collections.first {
            expect(collection.name == "Christmas Stuff", "collection name was \(collection.name)")
            expect(collection.iconName == "gift", "collection icon was \(collection.iconName)")
            expect(collection.entries.count == 4,
                   "collection had \(collection.entries.count) entries")
        }

        let titles = entries.map(\.title) + library.collections.flatMap { $0.entries.map(\.title) }
        expect(titles.allSatisfy { $0.tmdbID > 0 }, "some titles had a non-positive TMDB id")
        expect(titles.allSatisfy { !$0.title.isEmpty }, "some titles had an empty name")
        expect(titles.allSatisfy { $0.posterPath?.hasPrefix("/") ?? true },
               "some poster paths weren't TMDB-style")

        let deepestProgress = entries.map(\.watchedSeasons.count).max() ?? 0
        expect(deepestProgress >= 4,
               "deepest season progress was \(deepestProgress), expected >= 4")
        expect(entries.allSatisfy { $0.watchedSeasons == $0.watchedSeasons.sorted() },
               "watched seasons came back unsorted")

        expect(entries.contains { $0.userNotes == "Got too weird after season 3" },
               "expected the known note to survive the read")

        let dates = entries.flatMap { [$0.addedAt] + [$0.watchedAt, $0.droppedAt].compactMap { $0 } }
            + library.collections.map(\.createdAt)
        let lower = Date(timeIntervalSince1970: 1_420_070_400)  // 2015-01-01
        let upper = Date(timeIntervalSince1970: 1_893_456_000)  // 2030-01-01
        expect(dates.allSatisfy { $0 >= lower && $0 <= upper },
               "a timestamp fell outside 2015…2030")

        expect(summary.skipped == 0, "expected nothing to be skipped, got \(summary.skipped)")

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            return 1
        }

        print("""
            \(entries.count) list items \
            (\(summary.tvShowCount) shows, \(summary.movieCount) movies on a watchlist), \
            \(summary.collectionCount) collection(s) with \(summary.collectionItemCount) entries
            """)
        print("Legacy reader checks passed")
        return 0
    }
}
