import SwiftData
import SwiftUI

struct CustomListDetailView: View {
    let viewModel: CustomListViewModel
    let list: CustomList

    /// Custom lists are thematic pools, kept out of the Up Next queue — but watched state, ratings
    /// and season progress all live in the library, so rows derive them from it.
    @Environment(MediaLibraryViewModel.self) private var library
    @Environment(ToastState.self) private var toast

    @State private var showingAddItems = false
    @State private var selectedItem: CustomListItem?

    private var sortedItems: [CustomListItem] {
        (list.items ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    var body: some View {
        Group {
            if list.items?.isEmpty ?? true {
                EmptyStateView(icon: list.iconName, title: "No items yet") {
                    Button {
                        showingAddItems = true
                    } label: {
                        Label("Add Items", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                .background(AppBackground())
            } else {
                List {
                    ForEach(sortedItems, id: \.persistentModelID) { item in
                        row(for: item)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .padding(.horizontal, 12)
                .background(AppBackground())
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Items", systemImage: "plus") {
                    showingAddItems = true
                }
            }
        }
        .sheet(isPresented: $showingAddItems) {
            WatchlistSearchView(
                context: .specificList(list),
                existingTVShowIDs: [],
                existingMovieIDs: [],
                onTVShowAdded: { _ in },
                onMovieAdded: { _ in },
                customListViewModel: viewModel
            )
        }
        .sheet(item: $selectedItem) { item in
            CustomListItemDetailSheet(
                item: item,
                list: list,
                listViewModel: viewModel,
                onRemove: { removeWithUndo(item) },
                dismiss: { selectedItem = nil }
            )
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: CustomListItem) -> some View {
        let mediaType: MediaType = item.tvShow != nil ? .tvShow : .movie
        let libraryItem = item.media.flatMap { library.libraryItem(for: $0.id, mediaType: mediaType) }

        Button {
            selectedItem = item
        } label: {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle(for: item),
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
                providerCategories: item.media?.providerCategories ?? [:],
                isWatched: libraryItem?.isWatched ?? false,
                voteAverage: item.media?.voteAverage,
                genres: item.media?.genres ?? [],
                userRating: libraryItem?.userRating,
                seasonProgress: seasonProgress(for: item, libraryItem: libraryItem),
                watchedLabel: watchedLabel(for: libraryItem)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                removeWithUndo(item)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                removeWithUndo(item)
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    /// Same rule as the watchlist's rows: only show the bar for partial progress.
    private func seasonProgress(
        for item: CustomListItem,
        libraryItem: ListItem?
    ) -> (watchedSeasons: [Int], total: Int)? {
        guard let libraryItem, let total = item.tvShow?.numberOfSeasons, total > 0 else { return nil }
        let watched = libraryItem.watchedSeasons
        guard !watched.isEmpty, watched.count < total || libraryItem.isDropped else { return nil }
        return (watchedSeasons: watched, total: total)
    }

    private func subtitle(for item: CustomListItem) -> String? {
        if let tvShow = item.tvShow {
            return tvShow.seasonsEpisodesSummary
        } else if let movie = item.movie {
            let parts = [movie.releaseYear, movie.runtime.map { "\($0) min" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
        }
        return nil
    }

    /// "Watched Sep 2026", rendered in the card's corner chip so it never crowds the subtitle.
    private func watchedLabel(for libraryItem: ListItem?) -> String? {
        guard let libraryItem, libraryItem.isWatched, let watchedAt = libraryItem.watchedAt else { return nil }
        return "Watched \(watchedAt.formatted(.dateTime.month(.abbreviated).year()))"
    }

    // MARK: - Removal

    /// Removes an item immediately (animated) and shows a toast with an Undo action — the same
    /// pattern as a watchlist swipe-delete. The title stays in the library either way.
    private func removeWithUndo(_ item: CustomListItem) {
        let removedTitle = withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            viewModel.removeItem(item, from: list)
        }
        guard let title = removedTitle else { return }
        toast.show(
            "Removed \u{201C}\(title)\u{201D} from \u{201C}\(list.name)\u{201D}",
            icon: "trash.circle.fill",
            actionLabel: "Undo"
        ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.undoLastRemoval()
            }
        }
    }
}

// MARK: - Detail sheet

/// Wraps `MediaDetailView` for a custom-list item. Reads the library itself so the binding — and
/// the "Mark as Watched" affordance — re-resolve the moment the title lands in the library.
private struct CustomListItemDetailSheet: View {
    let item: CustomListItem
    let list: CustomList
    let listViewModel: CustomListViewModel
    let onRemove: () -> Void
    let dismiss: () -> Void

    @Environment(MediaLibraryViewModel.self) private var library

    /// Stand-in for titles that aren't in the library. It wraps the *shared* media row, so anything
    /// the detail sheet fetches into that row survives the switch to the real library item.
    @State private var fallbackItem: ListItem

    init(
        item: CustomListItem,
        list: CustomList,
        listViewModel: CustomListViewModel,
        onRemove: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.item = item
        self.list = list
        self.listViewModel = listViewModel
        self.onRemove = onRemove
        self.dismiss = dismiss
        let placeholder: ListItem
        if let tvShow = item.tvShow {
            placeholder = ListItem(tvShow: tvShow)
        } else if let movie = item.movie {
            placeholder = ListItem(movie: movie)
        } else {
            placeholder = ListItem()
        }
        _fallbackItem = State(initialValue: placeholder)
    }

    private var mediaType: MediaType {
        item.tvShow != nil ? .tvShow : .movie
    }

    private var mediaID: String {
        item.media?.id ?? ""
    }

    /// Resolves to the library's `ListItem` whenever the title is in the library, so the sheet's
    /// state follows it in place the moment "Mark as Watched" inserts one.
    private var detailBinding: Binding<ListItem> {
        Binding<ListItem>(
            get: { library.libraryItem(for: mediaID, mediaType: mediaType) ?? fallbackItem },
            set: { (newValue: ListItem) in
                let type = mediaType
                let id = mediaID
                if type == .tvShow {
                    if let index = library.tvShows.firstIndex(where: { $0.media?.id == id }) {
                        library.tvShows[index] = newValue
                        return
                    }
                } else {
                    if let index = library.movies.firstIndex(where: { $0.media?.id == id }) {
                        library.movies[index] = newValue
                        return
                    }
                }
                fallbackItem = newValue
            }
        )
    }

    private var existingIDs: Set<String> {
        MediaIDKey.makeSet(.tvShow, library.existingTVShowIDs)
            .union(MediaIDKey.makeSet(.movie, library.existingMovieIDs))
    }

    var body: some View {
        // Read through the library every render: after "Mark as Watched" inserts the real
        // `ListItem`, this resolves to it and the season/rating cards take over in place.
        let isInLibrary: Bool = library.libraryItem(for: mediaID, mediaType: mediaType) != nil
        let markWatchedAction: (() -> Void)? = isInLibrary ? nil : { markWatched() }
        let removeMessage: String =
            "This removes it from \u{201C}\(list.name)\u{201D} only \u{2014} it stays in your library."

        return MediaDetailView(
            listItem: detailBinding,
            dismiss: dismiss,
            onRemove: onRemove,
            onSeasonCountChanged: { listItem, previousCount in
                library.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
            },
            customListViewModel: listViewModel,
            existingIDs: existingIDs,
            onTVShowAdded: { library.addTVShow($0) },
            onMovieAdded: { library.addMovie($0) },
            onMarkWatched: markWatchedAction,
            removeLabel: "Remove from list",
            removeMessage: removeMessage
        )
    }

    private func markWatched() {
        if let tvShow = item.tvShow {
            library.addWatched(tvShow: tvShow)
            library.persistChanges(for: .tvShow)
        } else if let movie = item.movie {
            library.addWatched(movie: movie)
            library.persistChanges(for: .movie)
        }
    }
}
