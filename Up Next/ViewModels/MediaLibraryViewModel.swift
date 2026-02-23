import Foundation
import SwiftData

@MainActor
@Observable
final class MediaLibraryViewModel {
    var tvShows: [ListItem] = []
    var movies: [ListItem] = []
    var unwatchedTVShows: [ListItem] = []
    var unwatchedMovies: [ListItem] = []
    var watchedTVShows: [ListItem] = []
    var watchedMovies: [ListItem] = []
    var isLoaded = false

    private var modelContext: ModelContext?
    private var tvList: MediaList?
    private var movieList: MediaList?
    private var currentUser: UserIdentity?
    private var refreshTask: Task<Void, Never>?

    private static let lastRefreshVersionKey = "lastFullRefreshVersion"

    private var needsFullRefresh: Bool {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let last = UserDefaults.standard.string(forKey: Self.lastRefreshVersionKey)
        return last != current
    }

    private func markRefreshComplete() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        UserDefaults.standard.set(current, forKey: Self.lastRefreshVersionKey)
    }

    func configure(modelContext: ModelContext) async {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        await ensureDefaults()
        let didSeed = await loadItems()
        isLoaded = true
        if !didSeed && needsFullRefresh {
            refreshTask?.cancel()
            refreshTask = Task {
                await refreshAllItems()
                markRefreshComplete()
            }
        }
    }

    func containsItem(withID id: String, mediaType: MediaType) -> Bool {
        switch mediaType {
        case .tvShow: return tvShows.contains { $0.media?.id == id }
        case .movie: return movies.contains { $0.media?.id == id }
        }
    }

    func addTVShow(_ tvShow: TVShow) {
        guard let context = modelContext, let user = currentUser else { return }
        guard !containsItem(withID: tvShow.id, mediaType: .tvShow) else { return }

        let list = ensureList(for: .tvShow, using: user)
        let item = ListItem(
            tvShow: tvShow,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: false,
            watchedAt: nil,
            order: nextOrderValue(for: .tvShow)
        )
        context.insert(item)
        tvShows.append(item)

        syncUnwatched(for: .tvShow)
        try? context.save()
    }

    func addMovie(_ movie: Movie) {
        guard let context = modelContext, let user = currentUser else { return }
        guard !containsItem(withID: movie.id, mediaType: .movie) else { return }

        let list = ensureList(for: .movie, using: user)
        let item = ListItem(
            movie: movie,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: false,
            watchedAt: nil,
            order: nextOrderValue(for: .movie)
        )
        context.insert(item)
        movies.append(item)

        syncUnwatched(for: .movie)
        try? context.save()
    }

    func removeItem(withID id: String, mediaType: MediaType) {
        guard let context = modelContext else { return }

        switch mediaType {
        case .tvShow:
            if let index = tvShows.firstIndex(where: { $0.media?.id == id }) {
                let item = tvShows.remove(at: index)
                context.delete(item)
            }
        case .movie:
            if let index = movies.firstIndex(where: { $0.media?.id == id }) {
                let item = movies.remove(at: index)
                context.delete(item)
            }
        }

        syncUnwatched(for: mediaType)

        try? context.save()
    }

    func persistChanges(for mediaType: MediaType) {
        guard let context = modelContext else { return }
        syncUnwatched(for: mediaType)
        try? context.save()
    }

    func syncUnwatched(for mediaType: MediaType) {
        switch mediaType {
        case .tvShow:
            unwatchedTVShows = syncUnwatchedItems(
                allItems: tvShows,
                currentUnwatched: unwatchedTVShows
            )
            watchedTVShows = tvShows.filter { $0.isWatched }
                .sorted { lhs, rhs in
                    switch (lhs.watchedAt, rhs.watchedAt) {
                    case (let l?, let r?): return l < r
                    case (nil, _?): return false
                    case (_?, nil): return true
                    case (nil, nil): return false
                    }
                }
        case .movie:
            unwatchedMovies = syncUnwatchedItems(
                allItems: movies,
                currentUnwatched: unwatchedMovies
            )
            watchedMovies = movies.filter { $0.isWatched }
                .sorted { lhs, rhs in
                    switch (lhs.watchedAt, rhs.watchedAt) {
                    case (let l?, let r?): return l < r
                    case (nil, _?): return false
                    case (_?, nil): return true
                    case (nil, nil): return false
                    }
                }
        }
    }

    func updateOrderAfterUnwatchedMove(mediaType: MediaType) {
        guard let context = modelContext else { return }

        switch mediaType {
        case .tvShow:
            for (index, item) in unwatchedTVShows.enumerated() {
                item.order = index
            }
        case .movie:
            for (index, item) in unwatchedMovies.enumerated() {
                item.order = index
            }
        }

        try? context.save()
    }

    func handleSeasonCountUpdate(for listItem: ListItem, previousSeasonCount: Int?) {
        guard listItem.droppedAt == nil else { return }
        guard let previous = previousSeasonCount,
              let current = listItem.tvShow?.numberOfSeasons,
              current > previous
        else { return }

        // If all previous seasons were watched, the show was "complete" — move it back to Up Next
        let allPreviousWatched = (1...previous).allSatisfy { listItem.watchedSeasons.contains($0) }
        if allPreviousWatched {
            listItem.isWatched = false
            listItem.watchedAt = nil
        }
        listItem.syncWatchedStateFromSeasons()
        persistChanges(for: .tvShow)
    }

    // MARK: - Private helpers

    private func refreshAllItems() async {
        guard let context = modelContext else { return }
        let service = TMDBService.shared
        let maxConcurrent = 8

        // Collect value-type inputs — no @Model captures in task closures
        let tvInputs: [(index: Int, id: Int, prevSeasons: Int?)] = tvShows.enumerated().compactMap { i, item in
            guard let tvShow = item.tvShow, let id = Int(tvShow.id) else { return nil }
            return (i, id, tvShow.numberOfSeasons)
        }
        let movieInputs: [(index: Int, id: Int)] = movies.enumerated().compactMap { i, item in
            guard let movie = item.movie, let id = Int(movie.id) else { return nil }
            return (i, id)
        }

        // Fetch TV details in batches, returning Codable results
        for batch in stride(from: 0, to: tvInputs.count, by: maxConcurrent) {
            let slice = tvInputs[batch..<min(batch + maxConcurrent, tvInputs.count)]
            let results = await withTaskGroup(of: (Int, Int?, TMDBTVShowDetail?).self) { group in
                for input in slice {
                    group.addTask {
                        let detail = try? await service.getTVShowDetails(id: input.id)
                        return (input.index, input.prevSeasons, detail)
                    }
                }
                var out: [(Int, Int?, TMDBTVShowDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            // Apply updates on main actor (no isolation crossing)
            for (index, prevSeasons, detail) in results {
                guard let detail, index < tvShows.count,
                      let tvShow = tvShows[index].tvShow else { continue }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow.update(from: await service.mapToTVShow(detail, providers: providers))
                if let newCount = tvShow.numberOfSeasons,
                   let prev = prevSeasons, newCount > prev {
                    handleSeasonCountUpdate(for: tvShows[index], previousSeasonCount: prevSeasons)
                }
            }
        }

        // Fetch movie details in batches
        for batch in stride(from: 0, to: movieInputs.count, by: maxConcurrent) {
            let slice = movieInputs[batch..<min(batch + maxConcurrent, movieInputs.count)]
            let results = await withTaskGroup(of: (Int, TMDBMovieDetail?).self) { group in
                for input in slice {
                    group.addTask {
                        let detail = try? await service.getMovieDetails(id: input.id)
                        return (input.index, detail)
                    }
                }
                var out: [(Int, TMDBMovieDetail?)] = []
                for await result in group { out.append(result) }
                return out
            }

            for (index, detail) in results {
                guard let detail, index < movies.count,
                      let movie = movies[index].movie else { continue }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie.update(from: await service.mapToMovie(detail, providers: providers))
            }
        }

        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)
        try? context.save()
    }

    @discardableResult
    private func loadItems() async -> Bool {
        guard let context = modelContext else { return false }
        var didSeed = false
        do {
            let tvDescriptor = FetchDescriptor<ListItem>(
                predicate: #Predicate { $0.tvShow != nil },
                sortBy: [
                    SortDescriptor(\ListItem.order, order: .forward),
                    SortDescriptor(\ListItem.addedAt, order: .forward),
                ]
            )
            let movieDescriptor = FetchDescriptor<ListItem>(
                predicate: #Predicate { $0.movie != nil },
                sortBy: [
                    SortDescriptor(\ListItem.order, order: .forward),
                    SortDescriptor(\ListItem.addedAt, order: .forward),
                ]
            )

            tvShows = try context.fetch(tvDescriptor)
            movies = try context.fetch(movieDescriptor)

            #if DEBUG
            if tvShows.isEmpty && movies.isEmpty {
                await seedStubData()
                didSeed = true
            }
            #endif

            syncUnwatched(for: .tvShow)
            syncUnwatched(for: .movie)
        } catch { }
        return didSeed
    }

    private func ensureDefaults() async {
        guard let context = modelContext else { return }

        do {
            currentUser = try fetchOrCreateUser(context: context)
            tvList = try fetchOrCreateList(named: "TV Shows", context: context)
            movieList = try fetchOrCreateList(named: "Movies", context: context)
            try context.save()
        } catch { }
    }

    private func fetchOrCreateUser(context: ModelContext) throws -> UserIdentity {
        let descriptor = FetchDescriptor<UserIdentity>(
            predicate: #Predicate { $0.id == "current-user" }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let user = UserIdentity(id: "current-user", displayName: "Current User")
        context.insert(user)
        return user
    }

    private func fetchOrCreateList(named name: String, context: ModelContext) throws -> MediaList {
        let descriptor = FetchDescriptor<MediaList>(
            predicate: #Predicate { $0.name == name }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let creator = currentUser ?? UserIdentity(id: "current-user", displayName: "Current User")
        let list = MediaList(name: name, createdBy: creator, createdAt: Date())
        context.insert(list)
        return list
    }

    private func ensureList(for mediaType: MediaType, using user: UserIdentity) -> MediaList {
        switch mediaType {
        case .tvShow:
            if let list = tvList { return list }
            let list = MediaList(name: "TV Shows", createdBy: user, createdAt: Date())
            modelContext?.insert(list)
            tvList = list
            return list
        case .movie:
            if let list = movieList { return list }
            let list = MediaList(name: "Movies", createdBy: user, createdAt: Date())
            modelContext?.insert(list)
            movieList = list
            return list
        }
    }

    private func nextOrderValue(for mediaType: MediaType) -> Int {
        switch mediaType {
        case .tvShow:
            return (tvShows.map(\.order).max() ?? -1) + 1
        case .movie:
            return (movies.map(\.order).max() ?? -1) + 1
        }
    }

    private func seedStubData() async {
        guard let context = modelContext, let user = currentUser else { return }

        let service = TMDBService.shared
        let tvList = ensureList(for: .tvShow, using: user)
        let movieList = ensureList(for: .movie, using: user)

        // TV show IDs to seed: (tmdbID, isWatched, userRating, userNotes)
        let tvSeeds: [(id: Int, watched: Bool, rating: Int?, notes: String?)] = [
            (1396, false, nil, nil),   // Breaking Bad
            (2316, false, nil, nil),   // The Office
            (97546, false, nil, nil),  // Ted Lasso
            (76479, false, nil, nil),  // The Boys
            (82856, false, nil, nil),  // The Mandalorian
            (94997, false, nil, nil),  // House of the Dragon
            (103768, false, nil, nil), // Sweet Tooth
            (95557, false, nil, nil),  // Invincible
            (1399, true, 0, "Great first 4 seasons, ending was disappointing"),  // Game of Thrones
            (66732, true, 1, nil),          // Stranger Things
            (87108, true, 1, "Intense and brilliantly made"),  // Chernobyl
            (60625, true, -1, "Got too weird after season 3"), // Rick and Morty
        ]

        // Movie IDs to seed: (tmdbID, isWatched, userRating, userNotes)
        let movieSeeds: [(id: Int, watched: Bool, rating: Int?, notes: String?)] = [
            (603692, false, nil, nil), // John Wick: Chapter 4
            (693134, false, nil, nil), // Dune: Part Two
            (545611, false, nil, nil), // Everything Everywhere All at Once
            (346698, false, nil, nil), // Barbie
            (872585, false, nil, nil), // Oppenheimer
            (438631, true, 1, "Visually stunning, can't wait for Part Two"),   // Dune
            (299536, true, 1, nil),    // Avengers: Infinity War
            (550, true, 1, "First rule: you don't talk about it"),             // Fight Club
            (278, true, 1, "Perfect film"),  // The Shawshank Redemption
        ]

        // Fetch all TMDB details concurrently (raw Codable structs, not @Model objects)
        let tvDetails: [(Int, TMDBTVShowDetail?)] = await withTaskGroup(
            of: (Int, TMDBTVShowDetail?).self
        ) { group in
            for (index, seed) in tvSeeds.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getTVShowDetails(id: seed.id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBTVShowDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        let movieDetails: [(Int, TMDBMovieDetail?)] = await withTaskGroup(
            of: (Int, TMDBMovieDetail?).self
        ) { group in
            for (index, seed) in movieSeeds.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getMovieDetails(id: seed.id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBMovieDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        // Map to @Model objects on the main actor
        var seedTVItems: [ListItem] = []
        for (index, detail) in tvDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let tvShow = await service.mapToTVShow(detail, providers: providers)
            let seed = tvSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                tvShow: tvShow,
                list: tvList,
                addedBy: user,
                addedAt: Date().addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date().addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index,
                userRating: seed.rating,
                userNotes: seed.notes
            )
            context.insert(item)
            seedTVItems.append(item)
        }

        var seedMovieItems: [ListItem] = []
        for (index, detail) in movieDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let movie = await service.mapToMovie(detail, providers: providers)
            let seed = movieSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                movie: movie,
                list: movieList,
                addedBy: user,
                addedAt: Date().addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date().addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index,
                userRating: seed.rating,
                userNotes: seed.notes
            )
            context.insert(item)
            seedMovieItems.append(item)
        }

        tvShows = seedTVItems
        movies = seedMovieItems
        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)

        // Seed a "Christmas Stuff" custom list
        let christmasList = CustomList(name: "Christmas Stuff", iconName: "gift")
        context.insert(christmasList)

        let christmasMovieIDs = [10719, 12540, 771, 13675]  // Elf, Four Christmases, Home Alone, Rudolph
        let christmasDetails: [(Int, TMDBMovieDetail?)] = await withTaskGroup(
            of: (Int, TMDBMovieDetail?).self
        ) { group in
            for (index, id) in christmasMovieIDs.enumerated() {
                group.addTask {
                    do {
                        let detail = try await service.getMovieDetails(id: id)
                        return (index, detail)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBMovieDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        var christmasItems: [CustomListItem] = []
        for (_, detail) in christmasDetails {
            guard let detail else { continue }
            let providers = detail.watchProviders?.results?[service.currentRegion]
            let movie = await service.mapToMovie(detail, providers: providers)
            let item = CustomListItem(movie: movie, customList: christmasList, addedAt: Date())
            context.insert(item)
            christmasItems.append(item)
        }
        christmasList.items = christmasItems

        try? context.save()
    }
}
