import SwiftUI

struct TVShowsTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                compactLayout
            }
        }
        .onChange(of: expandedItemID) { previousID, _ in
            // The split layout has no sheet dismissal to hang persistence off, so a selection
            // losing focus is the save point. `persistChanges` is idempotent.
            if horizontalSizeClass == .regular, previousID != nil {
                viewModel.persistChanges(for: .tvShow)
            }
        }
        .onChange(of: horizontalSizeClass) {
            // A pinned selection would reappear as a surprise sheet (or vice versa) when the
            // window is resized on iPad — save its edits, then drop it.
            viewModel.persistChanges(for: .tvShow)
            expandedItemID = nil
        }
        .onDisappear {
            viewModel.persistChanges(for: .tvShow)
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

    // MARK: - Layouts

    /// iPhone (and narrow iPad windows): the list fills the tab, the detail arrives as a sheet.
    private var compactLayout: some View {
        listView(pinnedSelection: false)
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
                detailView(for: item, inColumn: false)
            }
    }

    /// Regular width: list in the sidebar, detail pinned alongside it.
    private var splitLayout: some View {
        NavigationSplitView {
            listView(pinnedSelection: true)
                // The column already has the list's own title bar; SwiftUI's automatic toggle
                // would sit at its trailing edge next to Add/Edit.
                .toolbar(removing: .sidebarToggle)
                // Fills the column edge to edge, bar area included — the list's own
                // `.background(AppBackground())` stops below the navigation bar.
                .containerBackground(for: .navigation) { AppBackground() }
                .navigationSplitViewColumnWidth(min: 360, ideal: 440, max: 560)
        } detail: {
            detailColumn
                .containerBackground(for: .navigation) { AppBackground() }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let item = selectedItem {
            // Keyed on the media id so switching rows rebuilds the detail's `@State`.
            detailView(for: item, inColumn: true)
                .id(item.media?.id)
        } else {
            EmptyStateView(icon: "tv", title: "Select a title")
                .background(AppBackground())
        }
    }

    /// `pinnedSelection` is true only in `splitLayout`: the list is the sidebar, so the selected
    /// row stays selected on a re-tap and is outlined to match the detail column.
    private func listView(pinnedSelection: Bool) -> some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedItemID,
            selectionIsSticky: pinnedSelection,
            highlightsSelection: pinnedSelection,
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
    }

    private func detailView(for item: ListItem, inColumn: Bool) -> some View {
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
            onMovieAdded: { viewModel.addMovie($0) },
            presentedInColumn: inColumn
        )
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
