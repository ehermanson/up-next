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

    let navigationTitle: String
    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onSearchTapped: (() -> Void)?
    var onSettingsTapped: (() -> Void)?
    var onItemDeleted: ((String) -> Void)?
    var isLoaded: Bool = true

    @State private var itemToDelete: ListItem?

    private var isEmpty: Bool {
        unwatchedItems.isEmpty && watchedItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isLoaded {
                    ShimmerLoadingView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "popcorn")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .frame(width: 96, height: 96)
                            .glassEffect(.regular, in: .circle)
                        Text("Your list is empty")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                        Text("Use the Search tab to find and add titles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fontDesign(.rounded)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GlassEffectContainer(spacing: 10) {
                        List {
                            if !unwatchedItems.isEmpty {
                                SectionHeader(
                                    title: "Up Next",
                                    count: filteredUnwatchedItems.count,
                                    availableGenres: availableGenres,
                                    selectedGenre: $selectedGenre,
                                    availableProviderCategories: availableProviderCategories,
                                    selectedProviderCategory: $selectedProviderCategory
                                )

                                ForEach(filteredUnwatchedItems, id: \.media?.id) { item in
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
                                            itemToDelete = item
                                        }
                                    )
                                }
                            }

                            if !watchedItems.isEmpty {
                                SectionHeader(title: "Watched", count: watchedItems.count)

                                ForEach(watchedItems, id: \.media?.id) { item in
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
                                            itemToDelete = item
                                        }
                                    )
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                        .contentMargins(.bottom, 20, for: .scrollContent)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: filteredUnwatchedItems.count)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .background(AppBackground())
            .navigationTitle(navigationTitle)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if let onSettingsTapped {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: onSettingsTapped) {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                if let onSearchTapped {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: onSearchTapped) {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            "Remove from Watchlist",
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button("Remove", role: .destructive) {
                if let id = item.media?.id {
                    onItemDeleted?(id)
                }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: { item in
            Text("Are you sure you want to remove \"\(item.media?.title ?? "this item")\" from your watchlist?")
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
        item.isWatched.toggle()
        item.watchedAt = item.isWatched ? Date() : nil

        if let tvShow = item.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
            item.watchedSeasons = item.isWatched ? Array(1...total) : []
        }

        if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
            allItems[index] = item
        }
        onWatchedToggled()
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var availableGenres: [String] = []
    @Binding var selectedGenre: String?
    var availableProviderCategories: [String] = []
    @Binding var selectedProviderCategory: String?

    init(
        title: String,
        count: Int,
        availableGenres: [String] = [],
        selectedGenre: Binding<String?> = .constant(nil),
        availableProviderCategories: [String] = [],
        selectedProviderCategory: Binding<String?> = .constant(nil)
    ) {
        self.title = title
        self.count = count
        self.availableGenres = availableGenres
        self._selectedGenre = selectedGenre
        self.availableProviderCategories = availableProviderCategories
        self._selectedProviderCategory = selectedProviderCategory
    }

    private var hasActiveFilter: Bool {
        selectedGenre != nil || selectedProviderCategory != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .foregroundStyle(.white)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            if !availableGenres.isEmpty || !availableProviderCategories.isEmpty {
                Menu {
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
                    Image(systemName: hasActiveFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(hasActiveFilter ? .white : .secondary)
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular, in: .circle)
                }
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

    var body: some View {
        Button {
            onItemExpanded(expandedItemID == itemID ? nil : itemID)
        } label: {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle,
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
                providerCategories: item.media?.providerCategories ?? [:],
                isWatched: item.isWatched,
                watchedToggleAction: { _ in
                    onWatchedToggled()
                }
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
    }
}

#Preview {
    let user = UserIdentity(id: "stub-user", displayName: "Stub User")
    let list = MediaList(name: "TV Shows", createdBy: user, createdAt: Date())
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
            addedAt: Date(),
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
            addedAt: Date(),
            isWatched: true,
            watchedAt: Date(),
            order: 0
        ),
        ListItem(
            tvShow: TVShow(
                id: "tv-3",
                title: "Stub TV Show 3",
                thumbnailURL: URL(string: "https://example.com/tvshow3.jpg")
            ),
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: false,
            watchedAt: nil,
            order: 1
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
