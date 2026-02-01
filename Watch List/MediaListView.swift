//
//  MediaListView.swift
//  Watch List
//
//  Created by Eric Hermanson on 12/12/25.
//

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

    let navigationTitle: String
    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onOrderChanged: () -> Void
    let onSearchTapped: (() -> Void)?
    var onSettingsTapped: (() -> Void)?

    private var isEmpty: Bool {
        unwatchedItems.isEmpty && watchedItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
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
                        Text("Tap + to add your first title")
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
                                    selectedGenre: $selectedGenre
                                )

                                if !filteredUnwatchedItems.isEmpty {
                                    if selectedGenre == nil {
                                        UnwatchedSection(
                                            items: $unwatchedItems,
                                            allItems: $allItems,
                                            expandedItemID: $expandedItemID,
                                            subtitleProvider: subtitleProvider,
                                            onItemExpanded: onItemExpanded,
                                            onWatchedToggled: onWatchedToggled,
                                            onOrderChanged: onOrderChanged
                                        )
                                    } else {
                                        ForEach(filteredUnwatchedItems, id: \.media?.id) { item in
                                            MediaListRow(
                                                item: binding(for: item),
                                                itemID: item.media?.id ?? "",
                                                expandedItemID: $expandedItemID,
                                                subtitle: subtitleProvider(item),
                                                onItemExpanded: onItemExpanded,
                                                onWatchedToggled: {
                                                    toggleWatched(item)
                                                }
                                            )
                                        }
                                    }
                                }
                            }

                            WatchedSection(
                                items: $watchedItems,
                                expandedItemID: $expandedItemID,
                                subtitleProvider: subtitleProvider,
                                onItemExpanded: onItemExpanded,
                                onWatchedToggled: onWatchedToggled
                            )
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                        .contentMargins(.bottom, 80, for: .scrollContent)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: filteredUnwatchedItems.count)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: allItems.count)
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle(navigationTitle)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                #if !os(tvOS)
                    if let onSettingsTapped {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(action: onSettingsTapped) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                    ToolbarItem {
                        EditButton()
                    }
                    if let onSearchTapped {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: onSearchTapped) {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                    }
                #endif
            }
        }
        .preferredColorScheme(.dark)
    }

    private func binding(for item: ListItem) -> Binding<ListItem> {
        Binding(
            get: {
                unwatchedItems.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard let id = item.media?.id,
                      let index = unwatchedItems.firstIndex(where: { $0.media?.id == id })
                else { return }
                unwatchedItems[index] = newValue
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

    init(title: String, count: Int, availableGenres: [String] = [], selectedGenre: Binding<String?> = .constant(nil)) {
        self.title = title
        self.count = count
        self.availableGenres = availableGenres
        self._selectedGenre = selectedGenre
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
            if !availableGenres.isEmpty {
                Menu {
                    Button {
                        selectedGenre = nil
                    } label: {
                        if selectedGenre == nil {
                            Label("All", systemImage: "checkmark")
                        } else {
                            Text("All")
                        }
                    }
                    Divider()
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
                } label: {
                    Image(systemName: selectedGenre != nil
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selectedGenre != nil ? .white : .secondary)
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

struct UnwatchedSection: View {
    @Binding var items: [ListItem]
    @Binding var allItems: [ListItem]
    @Binding var expandedItemID: String?

    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onOrderChanged: () -> Void

    var body: some View {
        ForEach($items, id: \.media?.id) { $item in
            MediaListRow(
                item: $item,
                itemID: item.media?.id ?? "",
                expandedItemID: $expandedItemID,
                subtitle: subtitleProvider(item),
                onItemExpanded: onItemExpanded,
                onWatchedToggled: {
                    toggleWatched(item)
                }
            )
        }
        .onMove(perform: handleMove)
    }

    private func toggleWatched(_ item: ListItem) {
        item.isWatched.toggle()
        item.watchedAt = item.isWatched ? Date() : nil

        // Sync season tracking for TV shows
        if let tvShow = item.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
            item.watchedSeasons = item.isWatched ? Array(1...total) : []
        }

        if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
            allItems[index] = item
        }
        onWatchedToggled()
    }

    private func handleMove(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() {
            item.order = index
        }
        for item in items {
            if let index = allItems.firstIndex(where: { $0.media?.id == item.media?.id }) {
                allItems[index].order = item.order
            }
        }
        onOrderChanged()
    }
}

struct WatchedSection: View {
    @Binding var items: [ListItem]
    @Binding var expandedItemID: String?

    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void

    var body: some View {
        if !items.isEmpty {
            SectionHeader(title: "Watched", count: items.count)

            ForEach($items, id: \.media?.id) { $item in
                MediaListRow(
                    item: $item,
                    itemID: item.media?.id ?? "",
                    expandedItemID: $expandedItemID,
                    subtitle: subtitleProvider(item),
                    onItemExpanded: onItemExpanded,
                    onWatchedToggled: {
                        item.isWatched.toggle()
                        item.watchedAt = item.isWatched ? Date() : nil
                        if let tvShow = item.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                            item.watchedSeasons = item.isWatched ? Array(1...total) : []
                        }
                        onWatchedToggled()
                    }
                )
            }
        }
    }
}

struct MediaListRow: View {
    @Binding var item: ListItem
    let itemID: String
    @Binding var expandedItemID: String?
    let subtitle: String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void

    var body: some View {
        Button {
            onItemExpanded(expandedItemID == itemID ? nil : itemID)
        } label: {
            MediaCardView(
                title: item.media?.title ?? "",
                subtitle: subtitle,
                imageURL: item.media?.thumbnailURL,
                networks: item.media?.networks ?? [],
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
    }
}

#Preview {
    let user = UserIdentity(id: "stub-user", displayName: "Stub User")
    let list = MediaList(name: "TV Shows", createdBy: user, createdAt: Date())
    let sampleNetworks = [
        Network(
            id: 213,
            name: "Netflix",
            logoPath: "/pmvUqkQjmdJeuMkuGIcF1coIIJ1.png",
            originCountry: "US"
        ),
        Network(
            id: 49,
            name: "HBO",
            logoPath: "/tuomPhY2UtuPTqqFnKMVHvSb724.png",
            originCountry: "US"
        ),
    ]
    let stubItems = [
        ListItem(
            tvShow: TVShow(
                id: "tv-1",
                title: "Stub TV Show 1",
                thumbnailURL: URL(string: "https://example.com/tvshow1.jpg"),
                networks: sampleNetworks
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
                networks: sampleNetworks
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
        navigationTitle: "TV Shows",
        subtitleProvider: { item in
            if let summary = item.tvShow?.seasonsEpisodesSummary {
                return summary
            }
            return nil
        },
        onItemExpanded: { _ in },
        onWatchedToggled: {},
        onOrderChanged: {},
        onSearchTapped: nil
    )
}
