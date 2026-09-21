import SwiftUI

struct MoviesTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    var body: some View {
        WatchlistTabView(
            viewModel: viewModel,
            customListViewModel: customListViewModel,
            mediaType: .movie,
            onlyMyServicesKey: StorageKey.movieOnlyMyServices,
            navigationTitle: "Movies",
            upcomingTitle: "Coming Soon",
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            watchedItems: $viewModel.watchedMovies,
            upcomingItems: upcomingEntries(from: viewModel.movies, mediaType: .movie),
            availableGenres: viewModel.availableMovieGenres,
            availableProviderCategories: viewModel.availableMovieProviderCategories,
            subtitleProvider: { item in movieSubtitle(for: item) },
            onSearchTapped: onSearchTapped,
            onSettingsTapped: onSettingsTapped
        )
    }

    private func movieSubtitle(for item: ListItem) -> String? {
        guard let movie = item.movie else { return nil }

        var meta: [String] = []
        if let year = movie.releaseYear {
            meta.append(year)
        }
        if let runtime = movie.runtime {
            meta.append("\(runtime) min")
        }

        return meta.isEmpty ? nil : meta.joined(separator: " \u{00B7} ")
    }
}
