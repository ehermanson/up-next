import SwiftUI

struct MediaListView: View {
    @Binding var allItems: [ListItem]
    @Binding var unwatchedItems: [ListItem]
    var filteredUnwatchedItems: [ListItem]
    @Binding var watchedItems: [ListItem]
    @Binding var expandedItemID: String?
    /// This tab's media type — namespaces the zoom-transition source ids (see `MediaIDKey`) so a
    /// row's id can never collide with anything outside this tab.
    let mediaType: MediaType
    /// Shared with the presenter so the detail sheet can zoom out of the tapped row.
    let detailNamespace: Namespace.ID
    var availableGenres: [String]
    @Binding var selectedGenre: String?
    var availableProviderCategories: [String]
    @Binding var selectedProviderCategory: String?
    @Binding var onlyMyServices: Bool
    /// Hidden entirely when the user hasn't picked any streaming services yet.
    var showsMyServicesFilter: Bool

    let navigationTitle: String
    /// Heading for the upcoming strip — "Returning Soon" (TV) or "Coming Soon" (movies).
    let upcomingTitle: String
    /// Items with a future air/release date, shown in a horizontal strip above "Up Next".
    var upcomingItems: [UpcomingEntry] = []
    var watchingItems: [ListItem] = []
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
    /// Optional content rendered above the upcoming strip (e.g. `SharePitchCard` on the TV Shows
    /// tab only). `AnyView` rather than a generic parameter so `MediaListView` stays a plain,
    /// easily-instantiated type at every other call site; `nil` (the default) renders nothing, so
    /// `MoviesTabView` doesn't have to opt out explicitly. Hidden automatically while the list is
    /// empty (the empty state has its own CTA) or while reordering.
    var topContent: (() -> AnyView)? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastState.self) private var toast
    @AppStorage(StorageKey.tvWatchedExpanded) private var tvWatchedExpanded = false
    @AppStorage(StorageKey.movieWatchedExpanded) private var movieWatchedExpanded = false

    private var isWatchedExpanded: Bool {
        mediaType == .tvShow ? tvWatchedExpanded : movieWatchedExpanded
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }

    /// Applied to the list/grid keyed to the filter inputs so titles fade/slide in and out when a
    /// genre, provider or "on my services" filter changes, instead of the set snapping. Keyed to the
    /// filter values (not the item array) so it never double-animates a reorder, delete or watched
    /// toggle — those own their own explicit transactions.
    private var filterAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    @State private var isEditingOrder = false
    /// Bumped on every reorder so `.sensoryFeedback` has a trigger to observe.
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
        unwatchedItems.isEmpty && watchedItems.isEmpty && watchingItems.isEmpty
    }

    /// A genre/provider/"on my services" filter matches nothing, even though Up Next isn't
    /// actually empty — distinct from `isEmpty`, which means there's nothing in any section.
    private var isFilteredToEmpty: Bool {
        !unwatchedItems.isEmpty && displayedUnwatchedItems.isEmpty
    }

    private func clearFilters() {
        selectedGenre = nil
        selectedProviderCategory = nil
        onlyMyServices = false
    }

    private var emptyStateTitle: String {
        mediaType == .tvShow ? "No Shows Yet" : "No Movies Yet"
    }

    private var emptyStateSubtitle: String {
        mediaType == .tvShow
            ? "Search for shows to start building your list"
            : "Search for movies to start building your list"
    }

    private var emptyStateCTA: String {
        mediaType == .tvShow ? "Add Your First Show" : "Add Your First Movie"
    }

    /// Rows actually rendered — drop any item without a stable media id so the two sections can't
    /// collide on a shared `nil` identity during a watched-toggle move.
    private var displayedUnwatchedItems: [ListItem] {
        filteredUnwatchedItems.filter { $0.media?.id != nil }
    }

    private var displayedWatchingItems: [ListItem] {
        watchingItems.filter { $0.media?.id != nil }
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
                        title: emptyStateTitle,
                        subtitle: emptyStateSubtitle
                    ) {
                        if let onSearchTapped {
                            Button(action: onSearchTapped) {
                                Label(emptyStateCTA, systemImage: "plus")
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
            .background(AppBackground(drifts: true))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.large)
            .tabRootNavigationBar()
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
                    // One item, not two: iOS 26 gives every toolbar item its own 44pt slot and
                    // adds the group gap on top, so an icon "+" next to a text "Edit" sat at
                    // opposite ends of one glass pill with dead space between. A single item
                    // keeps both in one capsule; `.plain` drops the toolbar button style's own
                    // ~12pt side padding (which turned a 4pt gap into ~28pt) so the spacing
                    // below is the spacing you get.
                    if onSearchTapped != nil || canReorder {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 12) {
                                if let onSearchTapped {
                                    // 28pt keeps a usable target around the ~17pt glyph; the
                                    // ~5pt it adds on the outside is mirrored on "Edit" below so
                                    // the pill's two insets match.
                                    Button("Add", systemImage: "plus", action: onSearchTapped)
                                        .labelStyle(.iconOnly)
                                        .frame(minWidth: 28, minHeight: 44)
                                        .contentShape(.rect)
                                }
                                if canReorder {
                                    Button("Edit") {
                                        withAnimation {
                                            isEditingOrder = true
                                        }
                                    }
                                    .frame(minHeight: 44)
                                    .padding(.trailing, 5)
                                    .contentShape(.rect)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 2)
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
            if let topContent, !isEditingOrder {
                topContent()
                    .listRowInsets(EdgeInsets(top: 4, leading: DesignTokens.Spacing.screenInset, bottom: 8, trailing: DesignTokens.Spacing.screenInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !watchingItems.isEmpty && !isEditingOrder {
                SectionHeader(title: "Watching", count: watchingItems.count, icon: "play.circle.fill", showsFilter: false)
                ForEach(displayedWatchingItems, id: \.media?.id) { item in
                    row(for: item)
                }
            }

            if !upcomingItems.isEmpty && !isEditingOrder {
                upcomingStrip
            }

            if unwatchedItems.isEmpty && watchingItems.isEmpty && !isEditingOrder {
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

                if isFilteredToEmpty {
                    noMatchesRow
                } else {
                    ForEach(displayedUnwatchedItems, id: \.media?.id) { item in
                        row(for: item)
                    }
                    .onMove(perform: moveHandler)
                    .onDelete(perform: deleteUnwatched)
                }
            }

            if !watchedItems.isEmpty && !isEditingOrder {
                watchedHeader

                // Keep the ForEach identity stable so List animates individual row changes.
                ForEach(isWatchedExpanded ? displayedWatchedItems : [], id: \.media?.id) { item in
                    row(for: item)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .onDelete(perform: deleteWatched)
            }
        }
        .refreshable {
            await onRefresh?()
        }
        // AppStorage can publish outside the button's transaction; key the layout animation
        // to the rendered preference so inserts/removals still receive an animation.
        .animation(disclosureAnimation, value: isWatchedExpanded)
        .animation(filterAnimation, value: selectedGenre)
        .animation(filterAnimation, value: selectedProviderCategory)
        .animation(filterAnimation, value: onlyMyServices)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.bottom, 20, for: .scrollContent)
        // Each row owns its inset; an outer List padding would compound header/card insets.
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
                if let topContent {
                    topContent()
                        .padding(.horizontal, DesignTokens.Spacing.screenInset)
                }

                if !watchingItems.isEmpty {
                    section(
                        header: SectionHeader(title: "Watching", count: watchingItems.count, icon: "play.circle.fill", showsFilter: false),
                        items: displayedWatchingItems
                    )
                }

                if !upcomingItems.isEmpty {
                    upcomingStrip
                }

                if unwatchedItems.isEmpty {
                    if watchingItems.isEmpty { caughtUpRow }
                } else if isFilteredToEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "Up Next",
                            count: filteredUnwatchedItems.count,
                            availableGenres: availableGenres,
                            selectedGenre: $selectedGenre,
                            availableProviderCategories: availableProviderCategories,
                            selectedProviderCategory: $selectedProviderCategory,
                            onlyMyServices: $onlyMyServices,
                            showsMyServicesFilter: showsMyServicesFilter
                        )
                        noMatchesRow
                    }
                    .padding(.horizontal, DesignTokens.Spacing.screenInset)
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
                    watchedGridSection
                }
            }
        }
        .refreshable {
            await onRefresh?()
        }
        .contentMargins(.bottom, 20, for: .scrollContent)
        .animation(filterAnimation, value: selectedGenre)
        .animation(filterAnimation, value: selectedProviderCategory)
        .animation(filterAnimation, value: onlyMyServices)
    }

    /// Cells are wide rather than poster-shaped, so the grid adapts by column count instead of
    /// stretching a fixed number of them.
    private static let gridColumns = [
        GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)
    ]

    private func section<Header: View>(
        header: Header,
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
        .padding(.horizontal, DesignTokens.Spacing.screenInset)
    }

    private var watchedGridSection: some View {
        VStack(alignment: .leading, spacing: isWatchedExpanded ? 12 : 0) {
            watchedHeader
            // Preserve the grid during collapse so its height can shrink smoothly instead of
            // snapping to the height of an empty LazyVGrid.
            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 12) {
                ForEach(displayedWatchedItems, id: \.media?.id) { item in
                    row(for: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: isWatchedExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isWatchedExpanded ? 1 : 0)
            .allowsHitTesting(isWatchedExpanded)
            .accessibilityHidden(!isWatchedExpanded)
        }
        .padding(.horizontal, DesignTokens.Spacing.screenInset)
        .animation(disclosureAnimation, value: isWatchedExpanded)
    }

    private var watchedExpandedBinding: Binding<Bool> {
        Binding(
            get: { isWatchedExpanded },
            set: { newValue in
                if mediaType == .tvShow {
                    tvWatchedExpanded = newValue
                } else {
                    movieWatchedExpanded = newValue
                }
            }
        )
    }

    private var watchedHeader: some View {
        SectionHeader(
            title: "Watched",
            count: watchedItems.count,
            showsFilter: false,
            isExpanded: watchedExpandedBinding
        )
    }

    private func row(for item: ListItem) -> some View {
        MediaListRow(
            item: item,
            itemID: item.media?.id ?? "",
            expandedItemID: $expandedItemID,
            subtitle: subtitleProvider(item),
            transitionID: MediaIDKey.make(mediaType, item.media?.id ?? ""),
            detailNamespace: detailNamespace,
            onItemExpanded: onItemExpanded,
            onWatchedToggled: {
                toggleWatched(item)
            },
            onDeleteRequested: {
                if let id = item.media?.id { onItemDeleted?(id) }
            },
            onWatchingToggled: {
                let previous = item.watchState
                withAnimation(Self.listChangeAnimation) {
                    item.toggleWatching()
                    onWatchedToggled()
                }
                toast.showWatchedMove(for: item, previous: previous, onUndo: onWatchedToggled)
            }
        )
    }

    private var upcomingStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: upcomingTitle, icon: "calendar.badge.clock", showsFilter: false)
                .padding(.horizontal, DesignTokens.Spacing.screenInset)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(upcomingItems) { entry in
                        Button {
                            onItemExpanded(entry.item.media?.id)
                        } label: {
                            UpcomingCard(item: entry.item, dateLabel: entry.dateLabel, detail: entry.detail)
                        }
                        .buttonStyle(.plain)
                        // The strip and the main list can show the same title at once, so this
                        // needs its own id (already namespaced "upcoming:" — see `entry.id`) —
                        // the sheet always zooms from the list row's source, not this one.
                        .matchedTransitionSource(id: entry.id, in: detailNamespace)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
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
            Text("You’re all caught up!")
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

    /// Shown in place of the Up Next rows when a genre/provider/"on my services" filter matches
    /// nothing — otherwise the section header reads "Up Next · 0" over an empty list with no way
    /// back except opening the filter menu again.
    private var noMatchesRow: some View {
        EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "No Matches",
            subtitle: "Nothing in Up Next matches these filters."
        ) {
            Button("Clear Filters") {
                clearFilters()
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowInsets(EdgeInsets())
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
        let previous = item.watchState
        // Wrap the whole transition — the item moving between Up Next and Watched, plus the
        // derived arrays recomputed in onWatchedToggled() — in one animation so both sections
        // diff coherently instead of animating partially out of sync.
        withAnimation(Self.listChangeAnimation) {
            item.toggleWatched()
            // Before `onWatchedToggled()`, which saves — the event rides the same save.
            PersistenceController.shared.recordWatchedActivity(for: item)

            if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
                allItems[index] = item
            }
            onWatchedToggled()
        }
        toast.showWatchedMove(for: item, previous: previous, onUndo: onWatchedToggled)
    }
}

/// Compact poster card in the "Returning Soon" / "Coming Soon" strip. Tapping it opens the same
/// detail sheet a list row does.
private struct UpcomingCard: View {
    @ObservedObject var item: ListItem
    let dateLabel: String
    let detail: String?

    /// Scales with Dynamic Type so a larger text size doesn't overflow the card's fixed width.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 110

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
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
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
                            .transition(Motion.posterAppear)
                    default:
                        Rectangle().fill(.fill.tertiary)
                    }
                }
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .frame(width: 60, height: 90)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterSmall))
    }
}

struct MediaListRow: View {
    @ObservedObject var item: ListItem
    let itemID: String
    @Binding var expandedItemID: String?
    let subtitle: String?
    /// Type-namespaced id (see `MediaIDKey`) the detail sheet zooms from/to.
    let transitionID: String
    let detailNamespace: Namespace.ID
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onDeleteRequested: () -> Void
    var onWatchingToggled: (() -> Void)? = nil

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
                nextAirDate: item.isWatching ? item.tvShow?.nextEpisodeAirDate : nil,
                nextEpisodeCode: episodeCode(
                    season: item.tvShow?.nextEpisodeSeason,
                    episode: item.tvShow?.nextEpisodeNumber
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(Color.accentColor.opacity(item.isWatching ? 0.45 : 0), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: transitionID, in: detailNamespace)
        .listRowInsets(EdgeInsets(
            top: DesignTokens.Spacing.rowGap / 2,
            leading: DesignTokens.Spacing.screenInset,
            bottom: DesignTokens.Spacing.rowGap / 2,
            trailing: DesignTokens.Spacing.screenInset
        ))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDeleteRequested()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        // Swipe actions are suppressed automatically while the list is in edit mode. Mark
        // Watched is edge-most (and the full-swipe default) so TV rows match movies and
        // collections; Start Watching sits second since it's TV-only.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onWatchedToggled()
            } label: {
                Label(watchedAction.title, systemImage: watchedAction.icon)
            }
            .tint(watchedAction.tint)
            watchingButton
        }
        .contextMenu {
            watchingButton
            Button {
                onWatchedToggled()
            } label: {
                Label(watchedAction.title, systemImage: watchedAction.icon)
            }
            Button(role: .destructive) {
                onDeleteRequested()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var watchingButton: some View {
        if item.tvShow != nil, let onWatchingToggled {
            Button(item.watchingActionTitle, systemImage: item.isWatching ? "arrow.uturn.backward" : "play.fill", action: onWatchingToggled)
                .tint(Color.accentColor)
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
        mediaType: .tvShow,
        detailNamespace: Namespace().wrappedValue,
        availableGenres: [],
        selectedGenre: .constant(nil),
        availableProviderCategories: [],
        selectedProviderCategory: .constant(nil),
        onlyMyServices: .constant(false),
        showsMyServicesFilter: true,
        navigationTitle: "TV Shows",
        upcomingTitle: "Returning Soon",
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
    .environment(ToastState())
}
