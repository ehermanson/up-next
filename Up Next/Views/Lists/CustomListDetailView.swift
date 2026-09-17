import CoreData
import SwiftUI

struct CustomListDetailView: View {
    let viewModel: CustomListViewModel
    /// `@ObservedObject` — `NSManagedObject` doesn't republish view updates on its own the way
    /// SwiftData's `@Model` did, so a rename (`list.name` in the nav title) needs this to redraw.
    @ObservedObject var list: CustomList

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingAddItems = false
    @State private var isConfirmingMarkAllUnwatched = false
    @State private var selectedItem: CustomListItem?

    /// Collections keep their own watched state (`CustomListItem.watchedAt`) — nothing here reads
    /// or writes the Movies / TV Shows tabs. Reads through `viewModel.visibleItems(in:)` rather than
    /// `list.items` directly so a swiped-away row (mid Undo window) disappears immediately.
    private var unwatchedItems: [CustomListItem] {
        viewModel.visibleItems(in: list).filter { !$0.isWatched }.sorted { $0.addedAt < $1.addedAt }
    }

    private var watchedItems: [CustomListItem] {
        viewModel.visibleItems(in: list).filter(\.isWatched).sorted {
            ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast)
        }
    }

    private var rowAnimation: Animation { CustomListViewModel.rowAnimation }

    var body: some View {
        Group {
            if viewModel.visibleItems(in: list).isEmpty {
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
            } else if horizontalSizeClass == .regular {
                gridLayout
            } else {
                listLayout
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
            let sheet = CustomListItemDetailSheet(
                item: item,
                list: list,
                listViewModel: viewModel,
                onRemove: { removeWithUndo(item) },
                dismiss: { selectedItem = nil }
            )
            // A roomy page sheet on iPad; compact keeps the standard full-height sheet.
            if horizontalSizeClass == .regular {
                sheet.presentationSizing(.page)
            } else {
                sheet
            }
        }
    }

    private var markAllUnwatchedPrompt: String {
        let count = watchedItems.count
        return "Mark all \(count) \(count == 1 ? "title" : "titles") unwatched?"
    }

    // MARK: - Layouts

    /// The phone layout: one column of rows with swipe actions.
    private var listLayout: some View {
        List {
            ForEach(unwatchedItems, id: \.objectID) { item in
                row(for: item)
            }

            if !watchedItems.isEmpty {
                watchedHeader

                ForEach(watchedItems, id: \.objectID) { item in
                    row(for: item)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .padding(.horizontal, 12)
        .background(AppBackground())
    }

    /// Regular width spreads the same rows across a grid. There are no swipe actions outside a
    /// `List`, so the row's context menu is the mark-watched / remove affordance here.
    private var gridLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                    ForEach(unwatchedItems, id: \.objectID) { item in
                        row(for: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !watchedItems.isEmpty {
                    watchedHeader

                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                        ForEach(watchedItems, id: \.objectID) { item in
                            row(for: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .background(AppBackground())
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)]
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

    private func row(for item: CustomListItem) -> some View {
        CustomListRow(
            item: item,
            onSelect: { selectedItem = item },
            onToggleWatched: { toggleWatched(item) },
            onRemove: { removeWithUndo(item) }
        )
    }

    /// Flips the entry between the two sections, animating the move.
    private func toggleWatched(_ item: CustomListItem) {
        withAnimation(rowAnimation) {
            viewModel.toggleWatched(item)
        }
    }

    // MARK: - Removal

    private func removeWithUndo(_ item: CustomListItem) {
        viewModel.removeWithUndo(item, from: list, toast: toast, animation: rowAnimation)
    }
}

/// One row in a collection's Unwatched/Watched grid or list. `@ObservedObject` so toggling
/// `item.watchedAt` (this collection's own watched state) redraws it — `NSManagedObject` doesn't
/// republish view updates on its own the way SwiftData's `@Model` did.
private struct CustomListRow: View {
    @ObservedObject var item: CustomListItem
    let onSelect: () -> Void
    let onToggleWatched: () -> Void
    let onRemove: () -> Void

    private var isWatched: Bool { item.isWatched }

    var body: some View {
        Button(action: onSelect) {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle,
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
                providerCategories: item.media?.providerCategories ?? [:],
                isWatched: isWatched,
                voteAverage: item.media?.voteAverage,
                genres: item.media?.genres ?? [],
                watchedLabel: watchedLabel
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
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
        // Watched state here is the collection's own — the Movies / TV Shows tabs never change.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onToggleWatched) {
                Label(
                    isWatched ? "Mark Unwatched" : "Mark Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle.fill"
                )
            }
            .tint(isWatched ? .gray : .green)
        }
        .contextMenu {
            Button(action: onToggleWatched) {
                Label(
                    isWatched ? "Mark Unwatched" : "Mark Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle.fill"
                )
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Collection", systemImage: "trash")
            }
        }
    }

    private var subtitle: String? {
        if let tvShow = item.tvShow {
            return tvShow.seasonsEpisodesSummary
        } else if let movie = item.movie {
            let parts = [movie.releaseYear, movie.runtime.map { "\($0) min" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
        }
        return nil
    }

    /// "Watched Sep 2026", rendered in the card's corner chip so it never crowds the subtitle.
    private var watchedLabel: String? {
        guard let watchedAt = item.watchedAt else { return nil }
        return "Watched \(watchedAt.formatted(.dateTime.month(.abbreviated).year()))"
    }
}

// MARK: - Removal helper

extension CustomListViewModel {
    /// Row move / removal animation, shared by every collection surface.
    static let rowAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    /// Removes an item immediately (animated) and shows a toast with an Undo action — the same
    /// pattern as a watchlist swipe-delete. Returns the removed title, if anything was removed.
    @discardableResult
    func removeWithUndo(
        _ item: CustomListItem,
        from list: CustomList,
        toast: ToastState,
        animation: Animation
    ) -> String? {
        let removedTitle = withAnimation(animation) {
            removeItem(item, from: list)
        }
        guard let title = removedTitle else { return nil }
        toast.show(
            "Removed \u{201C}\(title)\u{201D} from \u{201C}\(list.name)\u{201D}",
            icon: "trash.circle.fill",
            actionLabel: "Undo"
        ) { [weak self] in
            withAnimation(animation) {
                self?.undoLastRemoval()
            }
        }
        return title
    }
}

// MARK: - Detail sheet

/// Wraps `MediaDetailView` for a collection entry. The sheet is always bound to a *transient*
/// `ListItem` over the shared media row (like Discover does) so it never reaches into the
/// watchlist: the only watched state it can change is the collection entry's own.
private struct CustomListItemDetailSheet: View {
    /// `@ObservedObject` — `NSManagedObject` doesn't republish view updates on its own the way
    /// SwiftData's `@Model` did, and this sheet reads `item.isWatched` / `list.items` / `list.name`.
    @ObservedObject var item: CustomListItem
    @ObservedObject var list: CustomList
    let listViewModel: CustomListViewModel
    let onRemove: () -> Void
    let dismiss: () -> Void

    /// Wraps the *shared* media row, so anything the detail sheet fetches into that row (providers,
    /// cast, backdrop) is stored once and shows up everywhere else the title appears. The init
    /// automatically joins the persisted `tvShow`/`movie`'s context and store (see
    /// `inferredContext`/`assignToStore` in `MediaItem.swift`) — it must, since it's related to a
    /// stored row and Core Data forbids relating objects across contexts. Created once per
    /// presentation in `.task`, never in `init`: SwiftUI re-runs the presenting sheet closure (and
    /// so this init) whenever the presenter re-renders, and a wrapper built there is inserted into
    /// the context each time while only the one kept in `@State` would ever be cleaned up.
    @State private var detailItem: ListItem?

    var body: some View {
        Group {
            if let detailItem {
                detailSheet(for: detailItem)
            } else {
                Color.clear
            }
        }
        .task {
            guard detailItem == nil else { return }
            if let tvShow = item.tvShow {
                detailItem = ListItem(tvShow: tvShow)
            } else if let movie = item.movie {
                detailItem = ListItem(movie: movie)
            } else {
                detailItem = ListItem()
            }
        }
        .onDisappear { discardTransientItem() }
    }

    private func detailSheet(for detailItem: ListItem) -> some View {
        // Hoisted into typed locals — the type-checker has choked on this call site before.
        let removeMessage: String = "This only removes it from \u{201C}\(list.name)\u{201D}."
        let collectionName: String = list.name
        let entry: CustomListItem = item
        let listVM: CustomListViewModel = listViewModel
        // Inside a collection, "+" on a similar / recommended title adds to *this* collection,
        // not to Up Next, and the checkmarks reflect this collection's membership.
        let collection: CustomList = list
        let existingIDs: Set<String> = Set(listVM.visibleItems(in: collection).compactMap { item -> String? in
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
            listItem: detailItem,
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
    }

    /// The wrapper points at a *persisted* media row, so it lives in the view context and any save
    /// would persist it as a real watchlist entry. Tear it down when the sheet closes — a collection
    /// must never leave a `ListItem` behind in the Movies / TV Shows tabs. `list` stays nil on this
    /// wrapper the whole time, so `MediaLibraryViewModel`'s `list != nil` fetch filter never picks
    /// it up in between.
    private func discardTransientItem() {
        guard let detailItem else { return }
        let persistence = PersistenceController.shared
        detailItem.movie = nil
        detailItem.tvShow = nil
        if detailItem.managedObjectContext != nil {
            persistence.viewContext.delete(detailItem)
            persistence.save()
        }
        self.detailItem = nil
    }
}
