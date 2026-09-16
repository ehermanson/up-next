import SwiftUI

struct TVShowsTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @Environment(ToastState.self) private var toast

    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil
    @AppStorage("tvShows.onlyMyServices") private var onlyMyServices = false

    /// Held (not read through the singleton inline) so `@Observable` tracks provider changes.
    private let settings = ProviderSettings.shared

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    /// Upcoming episodes across the whole tab — watched shows included, dropped ones excluded.
    private var upcomingItems: [UpcomingEntry] {
        upcomingEntries(from: viewModel.tvShows, mediaType: .tvShow)
    }

    private var filteredUnwatchedItems: [ListItem] {
        filterItems(
            viewModel.unwatchedTVShows,
            genre: selectedGenre,
            providerCategory: selectedProviderCategory,
            onlyMyServices: onlyMyServices,
            selectedProviderIDs: settings.selectedProviderIDs
        )
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
            onlyMyServices: $onlyMyServices,
            showsMyServicesFilter: settings.hasSelectedProviders,
            navigationTitle: "TV Shows",
            upcomingTitle: "Airing Soon",
            upcomingItems: upcomingItems,
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
                deleteWithUndo(id: id)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .tvShow)
            },
            isLoaded: viewModel.isLoaded,
            onRefresh: {
                await viewModel.refreshNow()
            }
        )
        .sheet(
            item: Binding(
                get: { selectedItem },
                set: { _ in expandedItemID = nil }
            ),
            // Swipe-to-dismiss never runs the detail view's `dismiss` closure, so persist here
            // instead — that covers every way the sheet can go away. `persistChanges` is idempotent.
            onDismiss: {
                viewModel.persistChanges(for: .tvShow)
            }
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item),
                dismiss: {
                    expandedItemID = nil
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedItemID = nil
                        deleteWithUndo(id: id)
                    }
                },
                onSeasonCountChanged: { listItem, previousCount in
                    viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
                },
                customListViewModel: customListViewModel,
                existingIDs: MediaIDKey.makeSet(.tvShow, viewModel.existingTVShowIDs)
                    .union(MediaIDKey.makeSet(.movie, viewModel.existingMovieIDs)),
                onTVShowAdded: { viewModel.addTVShow($0) },
                onMovieAdded: { viewModel.addMovie($0) }
            )
        }
        .onChange(of: viewModel.availableTVGenres) {
            if let genre = selectedGenre, !viewModel.availableTVGenres.contains(genre) {
                selectedGenre = nil
            }
        }
        .onChange(of: settings.hasSelectedProviders) {
            // Without any selected services the filter would hide everything — turn it off.
            if !settings.hasSelectedProviders { onlyMyServices = false }
        }
        .onChange(of: viewModel.availableTVProviderCategories) {
            if let cat = selectedProviderCategory, !viewModel.availableTVProviderCategories.contains(cat) {
                selectedProviderCategory = nil
            }
        }
    }

    /// Removes an item immediately (animated) and shows a toast with an Undo action.
    private func deleteWithUndo(id: String) {
        let removedTitle = withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            viewModel.removeItem(withID: id, mediaType: .tvShow)
        }
        guard let title = removedTitle else { return }
        toast.show("Removed \u{201C}\(title)\u{201D}", icon: "trash.circle.fill", actionLabel: "Undo") {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.undoLastDeletion()
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
}
