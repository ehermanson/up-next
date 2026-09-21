import SwiftUI

/// Shared shell for the TV Shows / Movies tabs: the detail-sheet presentation (sheet item binding,
/// the watched-move toast on dismiss, the season-count hook), delete-with-undo, and the
/// `MediaListView` wiring — otherwise ~120 identical lines between `TVShowsTabView` and
/// `MoviesTabView`. Tab-specific bits (the share pitch card, subtitle text, watching items) are
/// supplied by the thin wrapper.
struct WatchlistTabView: View {
    let viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    let mediaType: MediaType
    let navigationTitle: String
    let upcomingTitle: String
    let allItems: Binding<[ListItem]>
    let unwatchedItems: Binding<[ListItem]>
    let watchedItems: Binding<[ListItem]>
    let watchingItems: [ListItem]
    let upcomingItems: [UpcomingEntry]
    let availableGenres: [String]
    let availableProviderCategories: [String]
    let subtitleProvider: (ListItem) -> String?
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void
    var topContent: (() -> AnyView)?
    /// TV-only: reconciles a show's watched state against a season count that changed underneath it.
    var onSeasonCountChanged: ((ListItem, Int?) -> Void)?

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var detailWatchState: (item: ListItem, state: ListItem.WatchState)?
    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil
    @AppStorage private var onlyMyServices: Bool
    /// Detail sheet zooms in/out of the tapped poster — see `MediaListRow`'s
    /// `matchedTransitionSource` and `detailView(for:)` below.
    @Namespace private var detailNamespace

    /// Held (not read through the singleton inline) so `@Observable` tracks provider changes.
    private let settings = ProviderSettings.shared

    init(
        viewModel: MediaLibraryViewModel,
        customListViewModel: CustomListViewModel,
        mediaType: MediaType,
        onlyMyServicesKey: String,
        navigationTitle: String,
        upcomingTitle: String,
        allItems: Binding<[ListItem]>,
        unwatchedItems: Binding<[ListItem]>,
        watchedItems: Binding<[ListItem]>,
        watchingItems: [ListItem] = [],
        upcomingItems: [UpcomingEntry],
        availableGenres: [String],
        availableProviderCategories: [String],
        subtitleProvider: @escaping (ListItem) -> String?,
        onSearchTapped: @escaping () -> Void,
        onSettingsTapped: @escaping () -> Void,
        topContent: (() -> AnyView)? = nil,
        onSeasonCountChanged: ((ListItem, Int?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.customListViewModel = customListViewModel
        self.mediaType = mediaType
        self.navigationTitle = navigationTitle
        self.upcomingTitle = upcomingTitle
        self.allItems = allItems
        self.unwatchedItems = unwatchedItems
        self.watchedItems = watchedItems
        self.watchingItems = watchingItems
        self.upcomingItems = upcomingItems
        self.availableGenres = availableGenres
        self.availableProviderCategories = availableProviderCategories
        self.subtitleProvider = subtitleProvider
        self.onSearchTapped = onSearchTapped
        self.onSettingsTapped = onSettingsTapped
        self.topContent = topContent
        self.onSeasonCountChanged = onSeasonCountChanged
        _onlyMyServices = AppStorage(wrappedValue: false, onlyMyServicesKey)
    }

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return allItems.wrappedValue.first(where: { $0.media?.id == id })
    }

    private var filteredUnwatchedItems: [ListItem] {
        filterItems(
            unwatchedItems.wrappedValue,
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
                viewModel.persistChanges(for: mediaType)
                if let previous = detailWatchState,
                   allItems.wrappedValue.contains(where: { $0 === previous.item }) {
                    toast.showWatchedMove(for: previous.item, previous: previous.state) {
                        viewModel.persistChanges(for: mediaType)
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
        .onChange(of: availableGenres) {
            if let genre = selectedGenre, !availableGenres.contains(genre) {
                selectedGenre = nil
            }
        }
        .onChange(of: settings.hasSelectedProviders) {
            // Without any selected services the filter would hide everything — turn it off.
            if !settings.hasSelectedProviders { onlyMyServices = false }
        }
        .onChange(of: availableProviderCategories) {
            if let cat = selectedProviderCategory, !availableProviderCategories.contains(cat) {
                selectedProviderCategory = nil
            }
        }
    }

    private var listView: some View {
        MediaListView(
            allItems: allItems,
            unwatchedItems: unwatchedItems,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: watchedItems,
            expandedItemID: $expandedItemID,
            mediaType: mediaType,
            detailNamespace: detailNamespace,
            availableGenres: availableGenres,
            selectedGenre: $selectedGenre,
            availableProviderCategories: availableProviderCategories,
            selectedProviderCategory: $selectedProviderCategory,
            onlyMyServices: $onlyMyServices,
            showsMyServicesFilter: settings.hasSelectedProviders,
            navigationTitle: navigationTitle,
            upcomingTitle: upcomingTitle,
            upcomingItems: upcomingItems,
            watchingItems: watchingItems,
            subtitleProvider: subtitleProvider,
            onItemExpanded: { id in
                expandedItemID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: mediaType)
            },
            onSearchTapped: onSearchTapped,
            onSettingsTapped: onSettingsTapped,
            onItemDeleted: { id in
                deleteWithUndo(id: id)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: mediaType)
            },
            isLoaded: viewModel.isLoaded,
            onRefresh: {
                await viewModel.refreshNow()
            },
            topContent: topContent
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
            onSeasonCountChanged: onSeasonCountChanged,
            customListViewModel: customListViewModel,
            existingIDs: MediaIDKey.makeSet(.tvShow, viewModel.existingTVShowIDs)
                .union(MediaIDKey.makeSet(.movie, viewModel.existingMovieIDs)),
            onTVShowAdded: { viewModel.addTVShow($0) },
            onMovieAdded: { viewModel.addMovie($0) }
        )
        .navigationTransition(.zoom(
            sourceID: MediaIDKey.make(mediaType, item.media?.id ?? ""),
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
            viewModel.removeItem(withID: id, mediaType: mediaType)
        }
        guard let title = removedTitle else { return }
        toast.show(
            "Removed \(title)",
            icon: "trash.circle.fill",
            actionLabel: "Undo",
            feedback: .impact
        ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.undoLastDeletion()
            }
        }
    }
}
