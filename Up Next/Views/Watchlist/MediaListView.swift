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
    /// Heading for the upcoming strip — "Airing Soon" (TV) or "Coming Soon" (movies).
    let upcomingTitle: String
    /// Items with a future air/release date, shown in a horizontal strip above "Up Next".
    var upcomingItems: [UpcomingEntry] = []
    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onSearchTapped: (() -> Void)?

    var onSettingsTapped: (() -> Void)?
    var onItemDeleted: ((String) -> Void)?
    var onOrderChanged: (() -> Void)?
    var isLoaded: Bool = true
    /// Pull-to-refresh. Awaited by the refresh control, so it must not return early.
    var onRefresh: (() async -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    /// Wide iPad windows get a full-width adaptive grid. Reordering stays on the `List` even
    /// there — drag handles and `.onMove` are `List` features.
    private var usesGridLayout: Bool {
        horizontalSizeClass == .regular && !isEditingOrder
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
                } else if usesGridLayout {
                    gridLayout
                } else {
                    listLayout
                }
            }
            .background(AppBackground())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
                    // Outermost (rightmost) of the trailing group, set off with a spacer so it
                    // reads as its own glass pill — Add/Edit are list actions, Settings isn't.
                    if let onSettingsTapped {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItem(placement: .topBarTrailing) {
                            SettingsToolbarButton(action: onSettingsTapped)
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

    // MARK: - Layouts

    /// iPhone, narrow iPad windows, and reorder mode everywhere: one column of rows in a `List`,
    /// which is what provides the swipe actions and the drag handles.
    @ViewBuilder
    private var listLayout: some View {
        let list = List {
            if !upcomingItems.isEmpty && !isEditingOrder {
                upcomingStrip
            }

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
                    row(for: item)
                }
                .onMove(perform: moveHandler)
                .onDelete(perform: deleteUnwatched)
            }

            if !watchedItems.isEmpty && !isEditingOrder {
                SectionHeader(title: "Watched", count: watchedItems.count)

                ForEach(displayedWatchedItems, id: \.media?.id) { item in
                    row(for: item)
                }
                .onDelete(perform: deleteWatched)
            }
        }
        .refreshable {
            await onRefresh?()
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.bottom, 20, for: .scrollContent)
        .padding(.horizontal, 12)
        .environment(\.editMode, .constant(isEditingOrder ? .active : .inactive))

        if horizontalSizeClass == .regular {
            // Only reached while reordering. A drag list spanning a 1200pt window is a long throw
            // for every move, so keep it to a phone-width column in the middle.
            list
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        } else {
            list
        }
    }

    /// Wide iPad windows: full-width content with the rows in an adaptive grid, the shape TV and
    /// Music use. There's no `List`, so the rows lose their swipe actions — their context menu
    /// carries Mark Watched / Delete instead.
    private var gridLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !upcomingItems.isEmpty {
                    upcomingStrip
                }

                if unwatchedItems.isEmpty {
                    caughtUpRow
                } else {
                    section(
                        header: SectionHeader(
                            title: "Up Next",
                            count: filteredUnwatchedItems.count,
                            availableGenres: availableGenres,
                            selectedGenre: $selectedGenre,
                            availableProviderCategories: availableProviderCategories,
                            selectedProviderCategory: $selectedProviderCategory,
                            onlyMyServices: $onlyMyServices,
                            showsMyServicesFilter: showsMyServicesFilter
                        ),
                        items: displayedUnwatchedItems
                    )
                }

                if !watchedItems.isEmpty {
                    section(
                        header: SectionHeader(title: "Watched", count: watchedItems.count),
                        items: displayedWatchedItems
                    )
                }
            }
        }
        .refreshable {
            await onRefresh?()
        }
        .contentMargins(.bottom, 20, for: .scrollContent)
    }

    /// Cells are wide rather than poster-shaped, so the grid adapts by column count instead of
    /// stretching a fixed number of them.
    private static let gridColumns = [
        GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)
    ]

    private func section(
        header: SectionHeader,
        items: [ListItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 12) {
                ForEach(items, id: \.media?.id) { item in
                    row(for: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func row(for item: ListItem) -> some View {
        MediaListRow(
            item: item,
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

    private var upcomingStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: upcomingTitle, icon: "calendar.badge.clock", showsFilter: false)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(upcomingItems) { entry in
                        Button {
                            onItemExpanded(entry.item.media?.id)
                        } label: {
                            UpcomingCard(item: entry.item, dateLabel: entry.dateLabel, detail: entry.detail)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    private func toggleWatched(_ item: ListItem) {
        // Wrap the whole transition — the item moving between Up Next and Watched, plus the
        // derived arrays recomputed in onWatchedToggled() — in one animation so both sections
        // diff coherently instead of animating partially out of sync.
        withAnimation(Self.listChangeAnimation) {
            item.toggleWatched()

            if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
                allItems[index] = item
            }
            onWatchedToggled()
        }
        watchedToggleCount += 1
    }
}

/// Compact poster card in the "Airing Soon" / "Coming Soon" strip. Tapping it opens the same
/// detail sheet a list row does.
private struct UpcomingCard: View {
    @ObservedObject var item: ListItem
    let dateLabel: String
    let detail: String?

    private static let cardWidth: CGFloat = 110

    private var title: String {
        item.media?.title ?? ""
    }

    private var isImminent: Bool {
        dateLabel == "Today" || dateLabel == "Tomorrow"
    }

    /// "S3E2" reads badly out loud — spell it out for VoiceOver.
    private var spokenDetail: String? {
        guard let tvShow = item.tvShow,
              let season = tvShow.nextEpisodeSeason,
              let episode = tvShow.nextEpisodeNumber
        else { return nil }
        return "Season \(season) Episode \(episode)"
    }

    private var accessibilityDescription: String {
        [title, spokenDetail, dateLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Chip(icon: "calendar", text: dateLabel, isEmphasized: isImminent)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.cardWidth, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var poster: some View {
        Group {
            if let url = item.media?.thumbnailURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(.fill.tertiary)
                    }
                }
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .frame(width: 64, height: 96)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterSmall))
    }
}

struct MediaListRow: View {
    @ObservedObject var item: ListItem
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
        guard let tvShow = item.tvShow else { return nil }
        // Measure against what's actually watchable, so a caught-up show whose next season is only
        // announced reads as complete instead of "3 of 4".
        let available = tvShow.availableSeasonCount
        let total = available > 0 ? available : (tvShow.numberOfSeasons ?? 0)
        guard total > 0 else { return nil }
        // Marks on a not-yet-available season would otherwise read as "4 of 3".
        let watched = item.watchedSeasons.filter { $0 <= total }
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
                nextAirDate: item.tvShow?.nextEpisodeAirDate,
                nextEpisodeCode: episodeCode(
                    season: item.tvShow?.nextEpisodeSeason,
                    episode: item.tvShow?.nextEpisodeNumber
                )
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
    let list = MediaList(name: "TV Shows", createdAt: Date.now, context: nil)
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
                providerCategories: sampleProviderCategories,
                nextEpisodeAirDate: "2099-06-15",
                nextEpisodeSeason: 3,
                nextEpisodeNumber: 2,
                nextEpisodeName: "The Long Way Around"
            ),
            list: list,
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
        upcomingTitle: "Airing Soon",
        upcomingItems: upcomingEntries(from: stubItems, mediaType: .tvShow),
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
