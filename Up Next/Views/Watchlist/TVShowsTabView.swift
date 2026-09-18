import CloudKit
import SwiftUI

struct TVShowsTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var detailWatchState: (item: ListItem, state: ListItem.WatchState)?
    @State private var expandedItemID: String? = nil
    @State private var selectedGenre: String? = nil
    @State private var selectedProviderCategory: String? = nil
    @AppStorage("tvShows.onlyMyServices") private var onlyMyServices = false
    /// Detail sheet zooms in/out of the tapped poster — see `MediaListRow`'s
    /// `matchedTransitionSource` and `detailView(for:)` below.
    @Namespace private var detailNamespace

    /// Held (not read through the singleton inline) so `@Observable` tracks provider changes.
    private let settings = ProviderSettings.shared
    private let persistence = PersistenceController.shared

    /// Live share state for `showsSharePitch` below. Like `SharingSection`/`SettingsToolbarButton`,
    /// `existingShare()` isn't itself observable, so it's refreshed explicitly on appear, on
    /// returning to the foreground, and whenever a remote change might have made sharing live.
    @State private var liveShare: CKShare?

    private var selectedItem: ListItem? {
        guard let id = expandedItemID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    /// Upcoming season premieres for caught-up shows outside Watching.
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

    /// See the "Sharing" section of CLAUDE.md for the full rule. Re-checked whenever `liveShare`,
    /// `settings`, or `persistence`'s observed properties change.
    private var showsSharePitch: Bool {
        guard !settings.hasDismissedSharePitch,
              persistence.role != .participant,
              !persistence.isJoiningSharedLibrary,
              viewModel.isLoaded,
              viewModel.tvShows.count + viewModel.movies.count >= 3
        else { return false }
        // "Not live" mirrors `SettingsToolbarButton.participantPair`: a share with no accepted (or
        // even invited) non-owner participant hasn't actually started a partnership yet.
        if let liveShare, liveShare.participants.contains(where: { $0.role != .owner }) {
            return false
        }
        return true
    }

    private func refreshShareState() {
        liveShare = persistence.existingShare()
    }

    var body: some View {
        listView
        .onAppear(perform: refreshShareState)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshShareState()
        }
        .onChange(of: persistence.remoteChangeCount) {
            refreshShareState()
        }
        .sheet(
            item: Binding(
                get: { selectedItem },
                set: { _ in expandedItemID = nil }
            ),
            // Swipe-to-dismiss never runs the detail view's `dismiss` closure, so persist here
            // instead — that covers every way the sheet can go away. `persistChanges` is idempotent.
            onDismiss: {
                viewModel.persistChanges(for: .tvShow)
                if let previous = detailWatchState,
                   viewModel.tvShows.contains(where: { $0 === previous.item }) {
                    toast.showWatchedMove(for: previous.item, previous: previous.state) {
                        viewModel.persistChanges(for: .tvShow)
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

    private var listView: some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            filteredUnwatchedItems: filteredUnwatchedItems,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedItemID,
            mediaType: .tvShow,
            detailNamespace: detailNamespace,
            availableGenres: viewModel.availableTVGenres,
            selectedGenre: $selectedGenre,
            availableProviderCategories: viewModel.availableTVProviderCategories,
            selectedProviderCategory: $selectedProviderCategory,
            onlyMyServices: $onlyMyServices,
            showsMyServicesFilter: settings.hasSelectedProviders,
            navigationTitle: "TV Shows",
            upcomingTitle: "Returning Soon",
            upcomingItems: upcomingItems,
            watchingItems: viewModel.watchingTVShows,
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
            },
            topContent: showsSharePitch ? { AnyView(SharePitchCard()) } : nil
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
            onSeasonCountChanged: { listItem, previousCount in
                viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
            },
            customListViewModel: customListViewModel,
            existingIDs: MediaIDKey.makeSet(.tvShow, viewModel.existingTVShowIDs)
                .union(MediaIDKey.makeSet(.movie, viewModel.existingMovieIDs)),
            onTVShowAdded: { viewModel.addTVShow($0) },
            onMovieAdded: { viewModel.addMovie($0) }
        )
        .navigationTransition(.zoom(
            sourceID: MediaIDKey.make(.tvShow, item.media?.id ?? ""),
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
            viewModel.removeItem(withID: id, mediaType: .tvShow)
        }
        guard let title = removedTitle else { return }
        toast.show("Removed \u{201C}\(title)\u{201D}", icon: "trash.circle.fill", actionLabel: "Undo") {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.undoLastDeletion()
            }
        }
    }

    private func tvShowSubtitle(for item: ListItem) -> String? {
        guard let tvShow = item.tvShow else { return nil }

        if item.isWatching && item.isWatched { return "Caught up" }

        if item.isDropped {
            let count = item.watchedSeasons.count
            let total = tvShow.numberOfSeasons ?? 0
            return total > 0 ? "Dropped \u{00B7} \(count) of \(total) seasons" : "Dropped"
        }

        // Caught up, with the next season only announced: say so rather than falling through to a
        // plain season count, which reads like there's something waiting.
        if item.isWatched, let announced = tvShow.announcedSeasonNumber {
            if let premiere = tvShow.announcedSeasonPremiere {
                let label = AirDateFormat.shortLabel(from: premiere) ?? premiere
                return "Season \(announced) premieres \(label)"
            }
            return "Season \(announced) announced"
        }

        if !item.watchedSeasons.isEmpty,
           let total = tvShow.numberOfSeasons, total > 1,
           !item.isWatched {
            let watched = Set(item.watchedSeasons).filter { (1...total).contains($0) }.count
            return "\(watched) of \(total) seasons watched"
        }

        return tvShow.seasonsEpisodesSummary
    }
}
