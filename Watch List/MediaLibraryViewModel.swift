import Foundation
import SwiftData

@MainActor
@Observable
final class MediaLibraryViewModel {
    var tvShows: [ListItem] = []
    var movies: [ListItem] = []
    var unwatchedTVShows: [ListItem] = []
    var unwatchedMovies: [ListItem] = []

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

    func add(listItem: ListItem, mediaType: MediaType) {
        guard
            let context = modelContext,
            let user = currentUser
        else { return }

        let list = ensureList(for: mediaType, using: user)
        let nextOrder = nextOrderValue(for: mediaType)

        switch mediaType {
        case .tvShow:
            guard let tvShow = listItem.tvShow else { return }
            let item = ListItem(
                tvShow: tvShow,
                list: list,
                addedBy: user,
                addedAt: Date(),
                isWatched: false,
                watchedAt: nil,
                order: nextOrder
            )
            context.insert(item)
            tvShows.append(item)
        case .movie:
            guard let movie = listItem.movie else { return }
            let item = ListItem(
                movie: movie,
                list: list,
                addedBy: user,
                addedAt: Date(),
                isWatched: false,
                watchedAt: nil,
                order: nextOrder
            )
            context.insert(item)
            movies.append(item)
        }

        syncUnwatched(for: mediaType)

        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to add item: \(error)")
            #endif
        }
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
        case .movie:
            unwatchedMovies = syncUnwatchedItems(
                allItems: movies,
                currentUnwatched: unwatchedMovies
            )
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
                seedStubData()
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

    private func seedStubData() {
        guard let context = modelContext, let user = currentUser else { return }
        do {
            let tvList = ensureList(for: .tvShow, using: user)
            let movieList = ensureList(for: .movie, using: user)

            let stubTV: [ListItem] = [
                ListItem(
                    tvShow: TVShow(
                        id: "tv-1",
                        title: "Stub TV Show 1",
                        thumbnailURL: URL(string: "https://example.com/tvshow1.jpg"),
                        networks: []
                    ),
                    list: tvList,
                    addedBy: user,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 0
                ),
                ListItem(
                    tvShow: TVShow(
                        id: "tv-2",
                        title: "Stub TV Show 2",
                        thumbnailURL: URL(string: "https://example.com/tvshow2.jpg"),
                        networks: []
                    ),
                    list: tvList,
                    addedBy: user,
                    addedAt: Date(),
                    isWatched: true,
                    watchedAt: Date(),
                    order: 1
                ),
                ListItem(
                    tvShow: TVShow(
                        id: "tv-3",
                        title: "Stub TV Show 3",
                        thumbnailURL: URL(string: "https://example.com/tvshow3.jpg")
                    ),
                    list: tvList,
                    addedBy: user,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 2
                ),
            ]

            let stubMovies: [ListItem] = [
                ListItem(
                    movie: Movie(
                        id: "movie-1",
                        title: "Stub Movie 1",
                        thumbnailURL: URL(string: "https://example.com/movie1.jpg"),
                        networks: [],
                        releaseDate: "2022-01-15"
                    ),
                    list: movieList,
                    addedBy: user,
                    addedAt: Date(),
                    isWatched: true,
                    watchedAt: Date(),
                    order: 0
                ),
                ListItem(
                    movie: Movie(
                        id: "movie-2",
                        title: "Stub Movie 2",
                        thumbnailURL: URL(string: "https://example.com/movie2.jpg"),
                        releaseDate: "2021-07-22"
                    ),
                    list: movieList,
                    addedBy: user,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 1
                ),
            ]

            for item in stubTV + stubMovies {
                context.insert(item)
            }

            tvShows = stubTV
            movies = stubMovies
            syncUnwatched(for: .tvShow)
            syncUnwatched(for: .movie)

            try context.save()
        } catch {
            #if DEBUG
                print("Failed to seed stub data: \(error)")
            #endif
        }
    }
}
