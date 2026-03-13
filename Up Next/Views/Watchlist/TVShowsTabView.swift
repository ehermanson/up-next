import SwiftUI

struct TVShowsTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    private var filteredUnwatchedItems: [ListItem] {
        filterItems(viewModel.unwatchedTVShows, genre: selectedGenre, providerCategory: selectedProviderCategory)
    }

    var body: some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedItemID,
            availableGenres: viewModel.availableTVGenres,
            selectedGenre: $selectedGenre,
            availableProviderCategories: viewModel.availableTVProviderCategories,
            selectedProviderCategory: $selectedProviderCategory,
            navigationTitle: "TV Shows",
            subtitleProvider: { item in
                tvShowSubtitle(for: item)
            },
            onItemExpanded: { id in
                expandedItemID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .tvShow)
            },
            onSearchTapped: onSearchTapped,
            onSettingsTapped: onSettingsTapped,
            onItemDeleted: { id in
                viewModel.removeItem(withID: id, mediaType: .tvShow)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .tvShow)
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
                    viewModel.persistChanges(for: .tvShow)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedItemID = nil
                        viewModel.removeItem(withID: id, mediaType: .tvShow)
                    }
                },
                onSeasonCountChanged: { listItem, previousCount in
                    viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
                },
                customListViewModel: customListViewModel,
                existingIDs: viewModel.existingTVShowIDs.union(viewModel.existingMovieIDs),
                onTVShowAdded: { viewModel.addTVShow($0) },
                onMovieAdded: { viewModel.addMovie($0) }
            )
        }
        .onChange(of: viewModel.availableTVGenres) {
            if let genre = selectedGenre, !viewModel.availableTVGenres.contains(genre) {
                selectedGenre = nil
            }
        }
        .onChange(of: viewModel.availableTVProviderCategories) {
            if let cat = selectedProviderCategory, !viewModel.availableTVProviderCategories.contains(cat) {
                selectedProviderCategory = nil
            }
        }
    }

    private func binding(forItem item: ListItem) -> Binding<ListItem> {
        Binding(
            get: {
                viewModel.tvShows.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard
                    let id = item.media?.id,
                    let index = viewModel.tvShows.firstIndex(where: { $0.media?.id == id })
                else { return }
                viewModel.tvShows[index] = newValue
            }
        )
    }

    private func tvShowSubtitle(for item: ListItem) -> String? {
        guard let tvShow = item.tvShow else { return nil }

        if item.isDropped {
            let count = item.watchedSeasons.count
            let total = tvShow.numberOfSeasons ?? 0
            return total > 0 ? "Dropped \u{2022} \(count) of \(total) seasons" : "Dropped"
        }

        if !item.watchedSeasons.isEmpty,
           let total = tvShow.numberOfSeasons, total > 1,
           let next = item.nextSeasonToWatch {
            if next == total {
                return "Next Season: S\(next)"
            } else {
                return "Next Season: S\(next) (of \(total))"
            }
        }

        return tvShow.seasonsEpisodesSummary
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
