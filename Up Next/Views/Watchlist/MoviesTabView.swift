import SwiftUI

struct MoviesTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var detailWatchState: (item: ListItem, state: ListItem.WatchState)?
    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil
    @AppStorage("movies.onlyMyServices") private var onlyMyServices = false
    /// Detail sheet zooms in/out of the tapped poster — see `MediaListRow`'s
    /// `matchedTransitionSource` and `detailView(for:)` below.
    @Namespace private var detailNamespace

    /// Held (not read through the singleton inline) so `@Observable` tracks provider changes.
    private let settings = ProviderSettings.shared

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return viewModel.movies.first(where: { $0.media?.id == id })
    }

    /// Unwatched movies that haven't been released yet.
    private var upcomingItems: [UpcomingEntry] {
        upcomingEntries(from: viewModel.movies, mediaType: .movie)
    }

    private var filteredUnwatchedItems: [ListItem] {
        filterItems(
            viewModel.unwatchedMovies,
            genre: selectedGenre,
            providerCategory: selectedProviderCategory,
            onlyMyServices: onlyMyServices,
            selectedProviderIDs: settings.selectedProviderIDs
        )
    }

    var body: some View {
        listView
        .sheet(
            item: Binding(
                get: { selectedItem },
                set: { _ in expandedItemID = nil }
            ),
            // Swipe-to-dismiss never runs the detail view's `dismiss` closure, so persist here
            // instead — that covers every way the sheet can go away. `persistChanges` is idempotent.
            onDismiss: {
                viewModel.persistChanges(for: .movie)
                if let previous = detailWatchState,
                   viewModel.movies.contains(where: { $0 === previous.item }) {
                    toast.showWatchedMove(for: previous.item, previous: previous.state) {
                        viewModel.persistChanges(for: .movie)
                    }
                }
                detailWatchState = nil
            }
        ) { item in
            detailView(for: item)
                .onAppear {
                    if detailWatchState == nil {
                        detailWatchState = (item, item.watchState)
                    }
                }
        }
        .onChange(of: viewModel.availableMovieGenres) {
            if let genre = selectedGenre, !viewModel.availableMovieGenres.contains(genre) {
                selectedGenre = nil
            }
        }
        .onChange(of: settings.hasSelectedProviders) {
            // Without any selected services the filter would hide everything — turn it off.
            if !settings.hasSelectedProviders { onlyMyServices = false }
        }
        .onChange(of: viewModel.availableMovieProviderCategories) {
            if let cat = selectedProviderCategory, !viewModel.availableMovieProviderCategories.contains(cat) {
                selectedProviderCategory = nil
            }
        }
    }

    private var listView: some View {
        MediaListView(
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: $viewModel.watchedMovies,
            expandedItemID: $expandedItemID,
            mediaType: .movie,
            detailNamespace: detailNamespace,
            availableGenres: viewModel.availableMovieGenres,
            selectedGenre: $selectedGenre,
            availableProviderCategories: viewModel.availableMovieProviderCategories,
            selectedProviderCategory: $selectedProviderCategory,
            onlyMyServices: $onlyMyServices,
            showsMyServicesFilter: settings.hasSelectedProviders,
            navigationTitle: "Movies",
            upcomingTitle: "Coming Soon",
            upcomingItems: upcomingItems,
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
                deleteWithUndo(id: id)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .movie)
            },
            isLoaded: viewModel.isLoaded,
            onRefresh: {
                await viewModel.refreshNow()
            }
        )
    }

    /// The detail sheet. On a wide iPad window it presents as a large page sheet rather than the
    /// default form sheet, which is too narrow for the backdrop header and the cast row.
    @ViewBuilder
    private func detailView(for item: ListItem) -> some View {
        let detail = MediaDetailView(
            listItem: item,
            dismiss: {
                expandedItemID = nil
            },
            onRemove: {
                if let id = item.media?.id {
                    expandedItemID = nil
                    deleteWithUndo(id: id)
                }
            },
            customListViewModel: customListViewModel,
            existingIDs: MediaIDKey.makeSet(.tvShow, viewModel.existingTVShowIDs)
                .union(MediaIDKey.makeSet(.movie, viewModel.existingMovieIDs)),
            onTVShowAdded: { viewModel.addTVShow($0) },
            onMovieAdded: { viewModel.addMovie($0) }
        )
        .navigationTransition(.zoom(
            sourceID: MediaIDKey.make(.movie, item.media?.id ?? ""),
            in: detailNamespace
        ))

        if horizontalSizeClass == .regular {
            detail.presentationSizing(.page)
        } else {
            detail
        }
    }

    /// Removes an item immediately (animated) and shows a toast with an Undo action.
    private func deleteWithUndo(id: String) {
        let removedTitle = withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            viewModel.removeItem(withID: id, mediaType: .movie)
        }
        guard let title = removedTitle else { return }
        toast.show("Removed \u{201C}\(title)\u{201D}", icon: "trash.circle.fill", actionLabel: "Undo") {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.undoLastDeletion()
            }
        }
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
