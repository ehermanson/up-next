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
    @Binding var expandedItemID: String?

    let navigationTitle: String
    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void
    let onOrderChanged: () -> Void
    let onSearchTapped: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                if !unwatchedItems.isEmpty {
                    UnwatchedSection(
                        items: $unwatchedItems,
                        allItems: $allItems,
                        expandedItemID: $expandedItemID,
                        subtitleProvider: subtitleProvider,
                        onItemExpanded: onItemExpanded,
                        onWatchedToggled: onWatchedToggled,
                        onOrderChanged: onOrderChanged
                    )
                }

                WatchedSection(
                    items: $allItems,
                    expandedItemID: $expandedItemID,
                    subtitleProvider: subtitleProvider,
                    onItemExpanded: onItemExpanded,
                    onWatchedToggled: onWatchedToggled
                )
            }.scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
                .listStyle(.plain)
                .navigationTitle(navigationTitle)
                .toolbar {
                    #if !os(tvOS)
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
        Section {
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
        .background(Color.clear)
    }

    private func toggleWatched(_ item: ListItem) {
        item.isWatched.toggle()
        item.watchedAt = item.isWatched ? Date() : nil
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

    private var watchedItems: [ListItem] {
        items.filter { $0.isWatched }
            .sorted { lhs, rhs in
                // Sort by watchedAt ascending, nils last
                switch (lhs.watchedAt, rhs.watchedAt) {
                case (let l?, let r?):
                    return l < r
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    return false
                }
            }
    }

    var body: some View {
        if !watchedItems.isEmpty {
            Section {
                ForEach(watchedItems, id: \.media?.id) { item in
                    let itemBinding = Binding(
                        get: {
                            items.first(where: { $0.media?.id == item.media?.id }) ?? item
                        },
                        set: { newValue in
                            if let index = items.firstIndex(where: { $0.media?.id == item.media?.id }) {
                                items[index] = newValue
                            }
                        }
                    )
                    MediaListRow(
                        item: itemBinding,
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

    private func toggleWatched(_ item: ListItem) {
        if let index = items.firstIndex(where: { $0.media?.id == item.media?.id }) {
            items[index].isWatched.toggle()
            items[index].watchedAt = items[index].isWatched ? Date() : nil
        }
        onWatchedToggled()
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
        .padding(.vertical, 6)
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
        expandedItemID: .constant("tv-1"),
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
