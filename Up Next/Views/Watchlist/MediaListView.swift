import SwiftData
import SwiftUI

struct MediaListView: View {
    @Binding var allItems: [ListItem]
    @Binding var unwatchedItems: [ListItem]
    var filteredUnwatchedItems: [ListItem]
    @Binding var watchedItems: [ListItem]
    @Binding var expandedItemID: String?
    var availableGenres: [String]
    @Binding var selectedGenre: String?
    var availableProviderCategories: [String]
    @Binding var selectedProviderCategory: String?
    @Binding var onlyMyServices: Bool
    /// Hidden entirely when the user hasn't picked any streaming services yet.
    var showsMyServicesFilter: Bool

    let navigationTitle: String
    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onSearchTapped: (() -> Void)?

    var onSettingsTapped: (() -> Void)?
    var onItemDeleted: ((String) -> Void)?
    var onOrderChanged: (() -> Void)?
    var isLoaded: Bool = true

    @State private var isEditingOrder = false
    /// Bumped on every watched toggle / reorder so `.sensoryFeedback` has a trigger to observe.
    @State private var watchedToggleCount = 0
    @State private var reorderCount = 0

    /// Animation used for user-driven list changes (watched toggle, delete). A watched-toggle is a
    /// *move* across the Up Next / Watched sections, so both sections must diff in one explicit
    /// transaction — an implicit animation keyed on a single section's count can't capture that.
    private static let listChangeAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    private var hasActiveFilter: Bool {
        selectedGenre != nil || selectedProviderCategory != nil || onlyMyServices
    }

    private var canReorder: Bool {
        !hasActiveFilter && unwatchedItems.count > 1
    }

    private var isEmpty: Bool {
        unwatchedItems.isEmpty && watchedItems.isEmpty
    }

    /// Rows actually rendered — drop any item without a stable media id so the two sections can't
    /// collide on a shared `nil` identity during a watched-toggle move.
    private var displayedUnwatchedItems: [ListItem] {
        filteredUnwatchedItems.filter { $0.media?.id != nil }
    }

    private var displayedWatchedItems: [ListItem] {
        watchedItems.filter { $0.media?.id != nil }
    }

    /// `nil` disables the drag handles entirely (filtered list, or a single item).
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { source, destination in
            moveUnwatched(from: source, to: destination)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isLoaded {
                    ShimmerLoadingView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmpty {
                    EmptyStateView(
                        icon: "popcorn",
                        title: "Your watchlist is empty",
                        subtitle: "Search for movies and shows to start building your list"
                    ) {
                        if let onSearchTapped {
                            Button(action: onSearchTapped) {
                                Label("Add Your First Title", systemImage: "plus")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    List {
                        if unwatchedItems.isEmpty && !isEditingOrder {
                            caughtUpRow
                        }

                        if !unwatchedItems.isEmpty {
                            SectionHeader(
                                title: "Up Next",
                                count: filteredUnwatchedItems.count,
                                // The filter menu is hidden while reordering — edit mode shows Up Next only.
                                showsFilter: !isEditingOrder,
                                availableGenres: availableGenres,
                                selectedGenre: $selectedGenre,
                                availableProviderCategories: availableProviderCategories,
                                selectedProviderCategory: $selectedProviderCategory,
                                onlyMyServices: $onlyMyServices,
                                showsMyServicesFilter: showsMyServicesFilter
                            )

                            ForEach(displayedUnwatchedItems, id: \.media?.id) { item in
                                MediaListRow(
                                    item: binding(for: item),
                                    itemID: item.media?.id ?? "",
                                    expandedItemID: $expandedItemID,
                                    subtitle: subtitleProvider(item),
                                    onItemExpanded: onItemExpanded,
                                    onWatchedToggled: {
                                        toggleWatched(item)
                                    },
                                    onDeleteRequested: {
                                        if let id = item.media?.id { onItemDeleted?(id) }
                                    }
                                )
                            }
                            .onMove(perform: moveHandler)
                            .onDelete(perform: deleteUnwatched)
                        }

                        if !watchedItems.isEmpty && !isEditingOrder {
                            SectionHeader(title: "Watched", count: watchedItems.count)

                            ForEach(displayedWatchedItems, id: \.media?.id) { item in
                                MediaListRow(
                                    item: binding(for: item, in: $watchedItems),
                                    itemID: item.media?.id ?? "",
                                    expandedItemID: $expandedItemID,
                                    subtitle: subtitleProvider(item),
                                    onItemExpanded: onItemExpanded,
                                    onWatchedToggled: {
                                        toggleWatched(item)
                                    },
                                    onDeleteRequested: {
                                        if let id = item.media?.id { onItemDeleted?(id) }
                                    }
                                )
                            }
                            .onDelete(perform: deleteWatched)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .contentMargins(.bottom, 20, for: .scrollContent)
                    .padding(.horizontal, 12)
                    .environment(\.editMode, .constant(isEditingOrder ? .active : .inactive))
                }
            }
            .background(AppBackground())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if let onSettingsTapped {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape", action: onSettingsTapped)
                    }
                }

                if isEditingOrder {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            withAnimation {
                                isEditingOrder = false
                            }
                        }
                    }
                } else {
                    if let onSearchTapped {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Add", systemImage: "plus", action: onSearchTapped)
                        }
                    }
                    if canReorder {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Edit") {
                                withAnimation {
                                    isEditingOrder = true
                                }
                            }
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: watchedToggleCount)
        .sensoryFeedback(.impact, trigger: reorderCount)
        .onChange(of: hasActiveFilter) {
            if hasActiveFilter { isEditingOrder = false }
        }
        .onChange(of: unwatchedItems.count) {
            if !canReorder { isEditingOrder = false }
        }
    }

    private var caughtUpRow: some View {
        VStack(spacing: 12) {
            Text("You're all caught up!")
                .font(.headline)
            if let onSearchTapped {
                Button(action: onSearchTapped) {
                    Label("Add More", systemImage: "plus")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Reorder / delete

    /// Reorders `unwatchedItems` to match the new order of the *rendered* rows. Rows are keyed by
    /// media id and `displayedUnwatchedItems` drops nil-id items, so offsets can't be applied to
    /// `unwatchedItems` directly — any nil-id item is re-inserted at its original absolute index.
    private func moveUnwatched(from source: IndexSet, to destination: Int) {
        var orderedIDs = displayedUnwatchedItems.compactMap { $0.media?.id }
        orderedIDs.move(fromOffsets: source, toOffset: destination)

        var itemsByID: [String: ListItem] = [:]
        for item in unwatchedItems {
            if let id = item.media?.id { itemsByID[id] = item }
        }

        let movedIDs = Set(orderedIDs)
        var reordered = orderedIDs.compactMap { itemsByID[$0] }
        for (index, item) in unwatchedItems.enumerated() {
            let id = item.media?.id
            if id == nil || !movedIDs.contains(id!) {
                reordered.insert(item, at: min(index, reordered.count))
            }
        }

        unwatchedItems = reordered
        reorderCount += 1
        onOrderChanged?()
    }

    private func deleteUnwatched(at offsets: IndexSet) {
        delete(offsets, from: displayedUnwatchedItems)
    }

    private func deleteWatched(at offsets: IndexSet) {
        delete(offsets, from: displayedWatchedItems)
    }

    private func delete(_ offsets: IndexSet, from items: [ListItem]) {
        for index in offsets where items.indices.contains(index) {
            if let id = items[index].media?.id { onItemDeleted?(id) }
        }
    }

    private func binding(for item: ListItem) -> Binding<ListItem> {
        binding(for: item, in: $unwatchedItems)
    }

    private func binding(for item: ListItem, in items: Binding<[ListItem]>) -> Binding<ListItem> {
        Binding(
            get: {
                items.wrappedValue.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard let id = item.media?.id,
                      let index = items.wrappedValue.firstIndex(where: { $0.media?.id == id })
                else { return }
                items.wrappedValue[index] = newValue
            }
        )
    }

    private func toggleWatched(_ item: ListItem) {
        // Wrap the whole transition — the item moving between Up Next and Watched, plus the
        // derived arrays recomputed in onWatchedToggled() — in one animation so both sections
        // diff coherently instead of animating partially out of sync.
        withAnimation(Self.listChangeAnimation) {
            if item.isDropped && item.isWatched {
                // A dropped show toggled from watched → unwatched: resume instead of un-watching.
                item.resumeShow()
            } else {
                item.isWatched.toggle()
                item.watchedAt = item.isWatched ? Date.now : nil

                if let tvShow = item.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                    item.watchedSeasons = item.isWatched ? Array(1...total) : []
                }
            }

            if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
                allItems[index] = item
            }
            onWatchedToggled()
        }
        watchedToggleCount += 1
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var showsFilter: Bool = true
    var availableGenres: [String] = []
    @Binding var selectedGenre: String?
    var availableProviderCategories: [String] = []
    @Binding var selectedProviderCategory: String?
    @Binding var onlyMyServices: Bool
    var showsMyServicesFilter: Bool = false

    init(
        title: String,
        count: Int,
        showsFilter: Bool = true,
        availableGenres: [String] = [],
        selectedGenre: Binding<String?> = .constant(nil),
        availableProviderCategories: [String] = [],
        selectedProviderCategory: Binding<String?> = .constant(nil),
        onlyMyServices: Binding<Bool> = .constant(false),
        showsMyServicesFilter: Bool = false
    ) {
        self.title = title
        self.count = count
        self.showsFilter = showsFilter
        self.availableGenres = availableGenres
        self._selectedGenre = selectedGenre
        self.availableProviderCategories = availableProviderCategories
        self._selectedProviderCategory = selectedProviderCategory
        self._onlyMyServices = onlyMyServices
        self.showsMyServicesFilter = showsMyServicesFilter
    }

    private var hasActiveFilter: Bool {
        selectedGenre != nil || selectedProviderCategory != nil || onlyMyServices
    }

    /// The filter menu is worth showing as soon as *any* of its sections has something to offer.
    private var hasFilterOptions: Bool {
        showsMyServicesFilter || !availableGenres.isEmpty || !availableProviderCategories.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Chip(text: "\(count)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) items")
            Spacer()
            if showsFilter, hasFilterOptions {
                Menu {
                    if showsMyServicesFilter {
                        Section {
                            Button {
                                onlyMyServices.toggle()
                            } label: {
                                if onlyMyServices {
                                    Label("On my services", systemImage: "checkmark")
                                } else {
                                    Text("On my services")
                                }
                            }
                        }
                    }
                    if availableProviderCategories.count > 1 {
                        Section("Watch Option") {
                            Button {
                                selectedProviderCategory = nil
                            } label: {
                                if selectedProviderCategory == nil {
                                    Label("All", systemImage: "checkmark")
                                } else {
                                    Text("All")
                                }
                            }
                            ForEach(availableProviderCategories, id: \.self) { category in
                                Button {
                                    selectedProviderCategory = category
                                } label: {
                                    if selectedProviderCategory == category {
                                        Label(category, systemImage: "checkmark")
                                    } else {
                                        Text(category)
                                    }
                                }
                            }
                        }
                    }
                    if !availableGenres.isEmpty {
                        Section("Genre") {
                            Button {
                                selectedGenre = nil
                            } label: {
                                if selectedGenre == nil {
                                    Label("All", systemImage: "checkmark")
                                } else {
                                    Text("All")
                                }
                            }
                            ForEach(availableGenres, id: \.self) { genre in
                                Button {
                                    selectedGenre = genre
                                } label: {
                                    if selectedGenre == genre {
                                        Label(genre, systemImage: "checkmark")
                                    } else {
                                        Text(genre)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Chip(
                        icon: hasActiveFilter
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        text: "Filter",
                        isEmphasized: hasActiveFilter
                    )
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .accessibilityLabel("Filter")
            }
        }
        .padding(.vertical, 4)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct MediaListRow: View {
    @Binding var item: ListItem
    let itemID: String
    @Binding var expandedItemID: String?
    let subtitle: String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onDeleteRequested: () -> Void

    /// Rows are buttons; while reordering, a tap must not open the detail sheet.
    @Environment(\.editMode) private var editMode

    /// Show progress bar for any TV show with partial season progress
    private var seasonProgress: (watchedSeasons: [Int], total: Int)? {
        guard let total = item.tvShow?.numberOfSeasons, total > 0 else { return nil }
        let watched = item.watchedSeasons
        // Only show when there's partial progress (not 0/N or N/N unless dropped)
        guard !watched.isEmpty, (watched.count < total || item.isDropped) else { return nil }
        return (watchedSeasons: watched, total: total)
    }

    /// Label/icon/tint for the watched action. A dropped show that's watched resumes rather than
    /// un-watching — same branch `toggleWatched(_:)` takes.
    private var watchedAction: (title: String, icon: String, tint: Color) {
        if !item.isWatched {
            return ("Mark Watched", "checkmark.circle.fill", .green)
        }
        if item.isDropped {
            return ("Pick Back Up", "arrow.uturn.backward.circle.fill", Color.accentColor)
        }
        return ("Mark Unwatched", "circle", .gray)
    }

    var body: some View {
        Button {
            guard editMode?.wrappedValue.isEditing != true else { return }
            onItemExpanded(expandedItemID == itemID ? nil : itemID)
        } label: {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle,
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
                providerCategories: item.media?.providerCategories ?? [:],
                isWatched: item.isWatched,
                voteAverage: item.media?.voteAverage,
                genres: item.media?.genres ?? [],
                userRating: item.userRating,
                seasonProgress: seasonProgress,
                nextAirDate: item.tvShow?.nextEpisodeAirDate
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
                onDeleteRequested()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // Swipe actions are suppressed automatically while the list is in edit mode.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onWatchedToggled()
            } label: {
                Label(watchedAction.title, systemImage: watchedAction.icon)
            }
            .tint(watchedAction.tint)
        }
        .contextMenu {
            Button {
                onWatchedToggled()
            } label: {
                Label(watchedAction.title, systemImage: watchedAction.icon)
            }
            Button(role: .destructive) {
                onDeleteRequested()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    let user = UserIdentity(id: "stub-user", displayName: "Stub User")
    let list = MediaList(name: "TV Shows", createdBy: user, createdAt: Date.now)
    let sampleNetworks = [
        Network(
            id: 8,
            name: "Netflix",
            logoPath: "/pbpMk2JmcoNnQwx5JGpXngfoWtp.png",
            originCountry: "US"
        ),
        Network(
            id: 1899,
            name: "HBO Max",
            logoPath: "/6Q3ZYUNA9Hsgj6iWnVsw2gR5V77.png",
            originCountry: "US"
        ),
    ]
    let sampleProviderCategories: [Int: String] = [8: "stream", 1899: "stream"]
    let stubItems = [
        ListItem(
            tvShow: TVShow(
                id: "tv-1",
                title: "Stub TV Show 1",
                thumbnailURL: URL(string: "https://example.com/tvshow1.jpg"),
                networks: sampleNetworks,
                providerCategories: sampleProviderCategories
            ),
            list: list,
            addedBy: user,
            addedAt: Date.now,
            isWatched: false,
            watchedAt: nil,
            order: 0
        ),
        ListItem(
            tvShow: TVShow(
                id: "tv-2",
                title: "Stub TV Show 2",
                thumbnailURL: URL(string: "https://example.com/tvshow2.jpg"),
                networks: sampleNetworks,
                providerCategories: sampleProviderCategories
            ),
            list: list,
            addedBy: user,
            addedAt: Date.now,
            isWatched: true,
            watchedAt: Date.now,
            order: 0,
            userRating: 1,
            userNotes: "Loved every episode"
        ),
        ListItem(
            tvShow: TVShow(
                id: "tv-3",
                title: "Stub TV Show 3",
                thumbnailURL: URL(string: "https://example.com/tvshow3.jpg")
            ),
            list: list,
            addedBy: user,
            addedAt: Date.now,
            isWatched: false,
            watchedAt: nil,
            order: 1
        ),
        ListItem(
            tvShow: TVShow(
                id: "tv-4",
                title: "Stub TV Show 4",
                thumbnailURL: URL(string: "https://example.com/tvshow4.jpg"),
                networks: sampleNetworks,
                providerCategories: sampleProviderCategories
            ),
            list: list,
            addedBy: user,
            addedAt: Date.now,
            isWatched: true,
            watchedAt: Date.now,
            order: 2,
            userRating: -1
        ),
    ]

    MediaListView(
        allItems: .constant(stubItems),
        unwatchedItems: .constant(stubItems.filter { !$0.isWatched }),
        filteredUnwatchedItems: stubItems.filter { !$0.isWatched },
        watchedItems: .constant(stubItems.filter { $0.isWatched }),
        expandedItemID: .constant("tv-1"),
        availableGenres: [],
        selectedGenre: .constant(nil),
        availableProviderCategories: [],
        selectedProviderCategory: .constant(nil),
        onlyMyServices: .constant(false),
        showsMyServicesFilter: true,
        navigationTitle: "TV Shows",
        subtitleProvider: { item in
            if let summary = item.tvShow?.seasonsEpisodesSummary {
                return summary
            }
            return nil
        },
        onItemExpanded: { _ in },
        onWatchedToggled: {},
        onSearchTapped: nil
    )
}
