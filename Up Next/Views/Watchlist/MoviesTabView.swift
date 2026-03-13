import SwiftUI

struct MoviesTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return viewModel.movies.first(where: { $0.media?.id == id })
    }

    private var filteredUnwatchedItems: [ListItem] {
        filterItems(viewModel.unwatchedMovies, genre: selectedGenre, providerCategory: selectedProviderCategory)
    }

    var body: some View {
        MediaListView(
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: $viewModel.watchedMovies,
            expandedItemID: $expandedItemID,
            availableGenres: viewModel.availableMovieGenres,
            selectedGenre: $selectedGenre,
            availableProviderCategories: viewModel.availableMovieProviderCategories,
            selectedProviderCategory: $selectedProviderCategory,
            navigationTitle: "Movies",
            subtitleProvider: { item in
                movieSubtitle(for: item)
            },
            onItemExpanded: { id in
                expandedItemID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .movie)
            },
            onSearchTapped: onSearchTapped,
            onSettingsTapped: onSettingsTapped,
            onItemDeleted: { id in
                viewModel.removeItem(withID: id, mediaType: .movie)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .movie)
            },
            isLoaded: viewModel.isLoaded
        )
        .sheet(
            item: Binding(
                get: { selectedItem },
                set: { _ in expandedItemID = nil }
            )
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item),
                dismiss: {
                    expandedItemID = nil
                    viewModel.persistChanges(for: .movie)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedItemID = nil
                        viewModel.removeItem(withID: id, mediaType: .movie)
                    }
                },
                customListViewModel: customListViewModel,
                existingIDs: viewModel.existingTVShowIDs.union(viewModel.existingMovieIDs),
                onTVShowAdded: { viewModel.addTVShow($0) },
                onMovieAdded: { viewModel.addMovie($0) }
            )
        }
        .onChange(of: viewModel.availableMovieGenres) {
            if let genre = selectedGenre, !viewModel.availableMovieGenres.contains(genre) {
                selectedGenre = nil
            }
        }
        .onChange(of: viewModel.availableMovieProviderCategories) {
            if let cat = selectedProviderCategory, !viewModel.availableMovieProviderCategories.contains(cat) {
                selectedProviderCategory = nil
            }
        }
    }

    private func binding(forItem item: ListItem) -> Binding<ListItem> {
        Binding(
            get: {
                viewModel.movies.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard
                    let id = item.media?.id,
                    let index = viewModel.movies.firstIndex(where: { $0.media?.id == id })
                else { return }
                viewModel.movies[index] = newValue
            }
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

        return meta.isEmpty ? nil : meta.joined(separator: " \u{2022} ")
    }

    private func filterItems(_ items: [ListItem], genre: String?, providerCategory: String?) -> [ListItem] {
        guard genre != nil || providerCategory != nil else { return items }
        var result = items
        if let genre {
            result = result.filter { $0.media?.genres.contains(genre) == true }
        }
        if let providerCategory {
            let rawCategories: Set<String>
            switch providerCategory {
            case "Stream": rawCategories = ["stream"]
            case "Free with Ads": rawCategories = ["ads"]
            case "Rent or Buy": rawCategories = ["rent", "buy"]
            default: rawCategories = []
            }
            result = result.filter { item in
                guard let categories = item.media?.providerCategories.values else { return false }
                return categories.contains(where: { rawCategories.contains($0) })
            }
        }
        return result
    }
}
