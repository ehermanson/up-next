import CoreData
import SwiftUI

struct CollectionSuggestionsView: View {
    @ObservedObject var list: CustomList
    let viewModel: CustomListViewModel

    @Environment(ToastState.self) private var toast
    @State private var movies: [TMDBMovieSearchResult] = []
    @State private var shows: [TMDBTVShowSearchResult] = []
    @State private var isLoading = false
    @State private var detailItem: ListItem?
    @State private var adding: Set<String> = []

    private let service = TMDBService.shared

    private var items: [CustomListItem] { viewModel.visibleItems(in: list) }
    private var existingIDs: Set<String> {
        Set(items.compactMap { item in
            guard let media = item.media else { return nil }
            return MediaIDKey.make(item.tvShow == nil ? .movie : .tvShow, media.id)
        })
    }
    private var requestID: String {
        // Keep the row stable while adding titles. Reopening or renaming refreshes it.
        [list.id.uuidString, list.name].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading || !movies.isEmpty || !shows.isEmpty {
                Label("Suggested for \(list.name)", systemImage: "sparkles")
                    .font(.headline)
                    .padding(.horizontal, 16)
                if movies.isEmpty && shows.isEmpty {
                    ProgressView("Finding suggestions…")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(movies) { movie in
                                PosterCard(
                                    posterPath: movie.posterPath, title: movie.title,
                                    isAdded: isAdded(.movie, movie.id),
                                    onTap: { detailItem = ListItem(movie: service.mapToMovie(movie)) },
                                    onAdd: { addMovie(movie) }
                                )
                            }
                            ForEach(shows) { show in
                                PosterCard(
                                    posterPath: show.posterPath, title: show.name,
                                    isAdded: isAdded(.tvShow, show.id),
                                    onTap: { detailItem = ListItem(tvShow: service.mapToTVShow(show)) },
                                    onAdd: { addTVShow(show) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .padding(.vertical, 16)
        .task(id: requestID) { await load() }
        .sheet(item: $detailItem) { item in
            MediaDetailView(
                listItem: item,
                dismiss: { detailItem = nil },
                onRemove: { detailItem = nil },
                onAdd: {
                    if let movie = item.movie { viewModel.addItem(movie: movie, to: list) }
                    if let show = item.tvShow { viewModel.addItem(tvShow: show, to: list) }
                },
                existingIDs: existingIDs,
                onTVShowAdded: { viewModel.addItem(tvShow: $0, to: list) },
                onMovieAdded: { viewModel.addItem(movie: $0, to: list) },
                addTargetName: list.name
            )
        }
    }

    private func isAdded(_ type: MediaType, _ id: Int) -> Bool {
        let key = MediaIDKey.make(type, id)
        return existingIDs.contains(key) || adding.contains(key)
    }

    private func load() async {
        let snapshot = items
        let name = list.name
        let movieSeeds = RecommendationEngine.selectListSeeds(from: snapshot, mediaType: .movie)
        let tvSeeds = RecommendationEngine.selectListSeeds(from: snapshot, mediaType: .tvShow)
        let movieIDs = RecommendationEngine.existingIDs(in: snapshot, mediaType: .movie)
        let tvIDs = RecommendationEngine.existingIDs(in: snapshot, mediaType: .tvShow)
        isLoading = true
        // Empty collections start with movies. Otherwise respect the types already collected.
        async let movieResults = movieSeeds.isEmpty && !snapshot.isEmpty ? [] :
            service.collectionMovies(name: name, seeds: movieSeeds, excluding: movieIDs)
        async let tvResults = tvSeeds.isEmpty ? [] :
            service.collectionTVShows(name: name, seeds: tvSeeds, excluding: tvIDs)
        let (newMovies, newShows) = await (movieResults, tvResults)
        guard !Task.isCancelled else { return }
        movies = Array(newMovies.prefix(tvSeeds.isEmpty ? 12 : 6))
        shows = Array(newShows.prefix(movieSeeds.isEmpty ? 12 : 6))
        isLoading = false
    }

    private func addMovie(_ result: TMDBMovieSearchResult) {
        guard !isAdded(.movie, result.id) else { return }
        let key = MediaIDKey.make(.movie, result.id)
        adding.insert(key)
        Task {
            let movie: Movie
            if let detail = try? await service.getMovieDetails(id: result.id) {
                movie = await service.mapToMovie(detail, providers: detail.watchProviders?.results?[service.currentRegion])
            } else {
                movie = service.mapToMovie(result)
            }
            guard !list.isDeleted else { adding.remove(key); return }
            viewModel.addItem(movie: movie, to: list)
            adding.remove(key)
            toast.show("\(result.title) added to \(list.name)")
        }
    }

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        guard !isAdded(.tvShow, result.id) else { return }
        let key = MediaIDKey.make(.tvShow, result.id)
        adding.insert(key)
        Task {
            let show: TVShow
            if let detail = try? await service.getTVShowDetails(id: result.id) {
                show = await service.mapToTVShow(detail, providers: detail.watchProviders?.results?[service.currentRegion])
            } else {
                show = service.mapToTVShow(result)
            }
            guard !list.isDeleted else { adding.remove(key); return }
            viewModel.addItem(tvShow: show, to: list)
            adding.remove(key)
            toast.show("\(result.name) added to \(list.name)")
        }
    }
}
