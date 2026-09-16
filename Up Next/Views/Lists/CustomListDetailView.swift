import SwiftData
import SwiftUI

struct CustomListDetailView: View {
    let viewModel: CustomListViewModel
    let list: CustomList

    @Environment(ToastState.self) private var toast

    @State private var showingAddItems = false
    @State private var selectedItem: CustomListItem?
    @State private var isConfirmingMarkAllUnwatched = false

    /// Collections keep their own watched state (`CustomListItem.watchedAt`) — nothing here reads
    /// or writes the Movies / TV Shows tabs.
    private var unwatchedItems: [CustomListItem] {
        (list.items ?? []).filter { !$0.isWatched }.sorted { $0.addedAt < $1.addedAt }
    }

    private var watchedItems: [CustomListItem] {
        (list.items ?? []).filter(\.isWatched).sorted {
            ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast)
        }
    }

    private var rowAnimation: Animation {
        .spring(response: 0.4, dampingFraction: 0.85)
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
                    ForEach(unwatchedItems, id: \.persistentModelID) { item in
                        row(for: item)
                    }

                    if !watchedItems.isEmpty {
                        watchedHeader

                        ForEach(watchedItems, id: \.persistentModelID) { item in
                            row(for: item)
                        }
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
            if !watchedItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Mark All Unwatched", systemImage: "arrow.counterclockwise") {
                            isConfirmingMarkAllUnwatched = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .confirmationDialog(
            markAllUnwatchedPrompt,
            isPresented: $isConfirmingMarkAllUnwatched,
            titleVisibility: .visible
        ) {
            Button("Mark All Unwatched") {
                withAnimation(rowAnimation) {
                    viewModel.markAllUnwatched(in: list)
                }
            }
            Button("Cancel", role: .cancel) {}
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

    private var markAllUnwatchedPrompt: String {
        let count = watchedItems.count
        return "Mark all \(count) \(count == 1 ? "title" : "titles") unwatched?"
    }

    // MARK: - Rows

    /// Matches the watchlist's section header: bold title plus a count chip.
    private var watchedHeader: some View {
        HStack(spacing: 8) {
            Text("Watched")
                .font(.title3)
                .fontWeight(.bold)
            Chip(text: "\(watchedItems.count)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(watchedItems.count) items")
            Spacer()
        }
        .padding(.vertical, 4)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func row(for item: CustomListItem) -> some View {
        let isWatched = item.isWatched

        Button {
            selectedItem = item
        } label: {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle(for: item),
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
                providerCategories: item.media?.providerCategories ?? [:],
                isWatched: isWatched,
                voteAverage: item.media?.voteAverage,
                genres: item.media?.genres ?? [],
                watchedLabel: watchedLabel(for: item)
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
        // Watched state here is the collection's own — the Movies / TV Shows tabs never change.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleWatched(item)
            } label: {
                Label(
                    isWatched ? "Mark Unwatched" : "Mark Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle.fill"
                )
            }
            .tint(isWatched ? .gray : .green)
        }
        .contextMenu {
            Button {
                toggleWatched(item)
            } label: {
                Label(
                    isWatched ? "Mark Unwatched" : "Mark Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle.fill"
                )
            }
            Button(role: .destructive) {
                removeWithUndo(item)
            } label: {
                Label("Remove from Collection", systemImage: "trash")
            }
        }
    }

    /// Flips the entry between the two sections, animating the move.
    private func toggleWatched(_ item: CustomListItem) {
        withAnimation(rowAnimation) {
            viewModel.toggleWatched(item)
        }
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
    private func watchedLabel(for item: CustomListItem) -> String? {
        guard let watchedAt = item.watchedAt else { return nil }
        return "Watched \(watchedAt.formatted(.dateTime.month(.abbreviated).year()))"
    }

    // MARK: - Removal

    /// Removes an item immediately (animated) and shows a toast with an Undo action — the same
    /// pattern as a watchlist swipe-delete.
    private func removeWithUndo(_ item: CustomListItem) {
        let removedTitle = withAnimation(rowAnimation) {
            viewModel.removeItem(item, from: list)
        }
        guard let title = removedTitle else { return }
        toast.show(
            "Removed \u{201C}\(title)\u{201D} from \u{201C}\(list.name)\u{201D}",
            icon: "trash.circle.fill",
            actionLabel: "Undo"
        ) {
            withAnimation(rowAnimation) {
                viewModel.undoLastRemoval()
            }
        }
    }
}

// MARK: - Detail sheet

/// Wraps `MediaDetailView` for a collection entry. The sheet is always bound to a *transient*
/// `ListItem` over the shared media row (like Discover does) so it never reaches into the
/// watchlist: the only watched state it can change is the collection entry's own.
private struct CustomListItemDetailSheet: View {
    let item: CustomListItem
    let list: CustomList
    let listViewModel: CustomListViewModel
    let onRemove: () -> Void
    let dismiss: () -> Void

    /// Wraps the *shared* media row, so anything the detail sheet fetches into that row (providers,
    /// cast, backdrop) is stored once and shows up everywhere else the title appears.
    @State private var detailItem: ListItem

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
        _detailItem = State(initialValue: placeholder)
    }

    var body: some View {
        // Hoisted into typed locals — the type-checker has choked on this call site before.
        let removeMessage: String = "This only removes it from \u{201C}\(list.name)\u{201D}."
        let collectionName: String = list.name
        let entry: CustomListItem = item
        let listVM: CustomListViewModel = listViewModel
        // Inside a collection, "+" on a similar / recommended title adds to *this* collection,
        // not to Up Next, and the checkmarks reflect this collection's membership.
        let collection: CustomList = list
        let existingIDs: Set<String> = Set((list.items ?? []).compactMap { item -> String? in
            guard let media = item.media else { return nil }
            return MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        })
        let addTVShow: (TVShow) -> Void = { listVM.addItem(tvShow: $0, to: collection) }
        let addMovie: (Movie) -> Void = { listVM.addItem(movie: $0, to: collection) }
        let watchedBinding: Binding<Bool> = Binding(
            get: { entry.isWatched },
            set: { (newValue: Bool) in
                guard newValue != entry.isWatched else { return }
                listVM.toggleWatched(entry)
            }
        )

        return MediaDetailView(
            listItem: $detailItem,
            dismiss: dismiss,
            onRemove: onRemove,
            customListViewModel: listVM,
            onAdd: nil,
            existingIDs: existingIDs,
            onTVShowAdded: addTVShow,
            onMovieAdded: addMovie,
            addTargetName: collectionName,
            collectionWatched: watchedBinding,
            collectionName: collectionName,
            removeLabel: "Remove from collection",
            removeMessage: removeMessage
        )
        .onDisappear { discardTransientItem() }
    }

    /// The wrapper points at a *persisted* media row, so SwiftData's autosave can cascade-insert it
    /// as a real watchlist entry. Tear it down when the sheet closes — a collection must never
    /// leave a `ListItem` behind in the Movies / TV Shows tabs.
    private func discardTransientItem() {
        if let context = detailItem.modelContext {
            context.delete(detailItem)
            try? context.save()
            return
        }
        detailItem.movie = nil
        detailItem.tvShow = nil
    }
}
