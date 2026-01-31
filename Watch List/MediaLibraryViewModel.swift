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

    private var modelContext: ModelContext?
    private var tvList: MediaList?
    private var movieList: MediaList?
    private var currentUser: UserIdentity?

    func configure(modelContext: ModelContext) async {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        await ensureDefaults()
        await loadItems()
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

        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to remove item: \(error)")
            #endif
        }
    }

    func persistChanges(for mediaType: MediaType) {
        guard let context = modelContext else { return }
        syncUnwatched(for: mediaType)
        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to save changes: \(error)")
            #endif
        }
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

        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to persist order: \(error)")
            #endif
        }
    }

    // MARK: - Private helpers

    private func loadItems() async {
        guard let context = modelContext else { return }
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

            if tvShows.isEmpty && movies.isEmpty {
                await seedStubData()
            }

            syncUnwatched(for: .tvShow)
            syncUnwatched(for: .movie)
        } catch {
            #if DEBUG
                print("Failed to load items: \(error)")
            #endif
        }
    }

    private func ensureDefaults() async {
        guard let context = modelContext else { return }

        do {
            currentUser = try fetchOrCreateUser(context: context)
            tvList = try fetchOrCreateList(named: "TV Shows", context: context)
            movieList = try fetchOrCreateList(named: "Movies", context: context)
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to ensure defaults: \(error)")
            #endif
        }
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

        // TV show IDs to seed: (tmdbID, isWatched)
        let tvSeeds: [(id: Int, watched: Bool)] = [
            (1396, false),   // Breaking Bad
            (2316, false),   // The Office
            (97546, false),  // Ted Lasso
            (76479, false),  // The Boys
            (82856, false),  // The Mandalorian
            (94997, false),  // House of the Dragon
            (103768, false), // Sweet Tooth
            (95557, false),  // Invincible
            (1399, true),    // Game of Thrones
            (66732, true),   // Stranger Things
            (87108, true),   // Chernobyl
            (60625, true),   // Rick and Morty
        ]

        // Movie IDs to seed: (tmdbID, isWatched)
        let movieSeeds: [(id: Int, watched: Bool)] = [
            (603692, false), // John Wick: Chapter 4
            (693134, false), // Dune: Part Two
            (545611, false), // Everything Everywhere All at Once
            (346698, false), // Barbie
            (872585, false), // Oppenheimer
            (438631, true),  // Dune
            (299536, true),  // Avengers: Infinity War
            (550, true),     // Fight Club
            (278, true),     // The Shawshank Redemption
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
                        #if DEBUG
                            print("Failed to fetch TV show \(seed.id): \(error)")
                        #endif
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, TMDBTVShowDetail?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        let movieDetails: [(Int, TMDBMovieDetail?, TMDBWatchProviderCountry?)] = await withTaskGroup(
            of: (Int, TMDBMovieDetail?, TMDBWatchProviderCountry?).self
        ) { group in
            for (index, seed) in movieSeeds.enumerated() {
                group.addTask {
                    do {
                        async let detailTask = service.getMovieDetails(id: seed.id)
                        async let providersTask = service.getMovieWatchProviders(id: seed.id, countryCode: "US")
                        let detail = try await detailTask
                        let providers = try await providersTask
                        return (index, detail, providers)
                    } catch {
                        #if DEBUG
                            print("Failed to fetch movie \(seed.id): \(error)")
                        #endif
                        return (index, nil, nil)
                    }
                }
            }
            var results: [(Int, TMDBMovieDetail?, TMDBWatchProviderCountry?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        // Map to @Model objects on the main actor
        var seedTVItems: [ListItem] = []
        for (index, detail) in tvDetails {
            guard let detail else { continue }
            let tvShow = service.mapToTVShow(detail)
            let seed = tvSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                tvShow: tvShow,
                list: tvList,
                addedBy: user,
                addedAt: Date().addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date().addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index
            )
            context.insert(item)
            seedTVItems.append(item)
        }

        var seedMovieItems: [ListItem] = []
        for (index, detail, providers) in movieDetails {
            guard let detail else { continue }
            let movie = service.mapToMovie(detail, providers: providers)
            let seed = movieSeeds[index]
            let daysAgo = seed.watched ? Double(30 + index * 15) : 0
            let item = ListItem(
                movie: movie,
                list: movieList,
                addedBy: user,
                addedAt: Date().addingTimeInterval(-86400 * daysAgo),
                isWatched: seed.watched,
                watchedAt: seed.watched ? Date().addingTimeInterval(-86400 * (daysAgo - 5)) : nil,
                order: index
            )
            context.insert(item)
            seedMovieItems.append(item)
        }

        tvShows = seedTVItems
        movies = seedMovieItems
        syncUnwatched(for: .tvShow)
        syncUnwatched(for: .movie)

        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to save seed data: \(error)")
            #endif
        }
    }
}
