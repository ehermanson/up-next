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
                        item.isWatched.toggle()
                        if item.isWatched {
                            item.watchedAt = Date()
                        } else {
                            item.watchedAt = nil
                        }
                        // Update order in allItems array
                        if let index = allItems.firstIndex(where: {
                            $0.media?.id == item.media?.id
                        }) {
                            allItems[index] = item
                        }
                        onWatchedToggled()
                    }
                )
            }
            .onMove { source, destination in
                items.move(fromOffsets: source, toOffset: destination)
                // Update order values after reordering
                for (index, item) in items.enumerated() {
                    item.order = index
                }
                // Also update in the main array to ensure persistence
                for item in items {
                    if let index = allItems.firstIndex(where: {
                        $0.media?.id == item.media?.id
                    }) {
                        allItems[index].order = item.order
                    }
                }
                onOrderChanged()
            }
        }
        .background(Color.clear)
    }
}

struct WatchedSection: View {
    @Binding var items: [ListItem]
    @Binding var expandedItemID: String?

    let subtitleProvider: (ListItem) -> String?
    let onItemExpanded: (String?) -> Void
    let onWatchedToggled: () -> Void

    private var watchedIndices: [Int] {
        items.indices.filter { items[$0].isWatched }
            .sorted { lhsIndex, rhsIndex in
                let lhs = items[lhsIndex]
                let rhs = items[rhsIndex]
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
        if !watchedIndices.isEmpty {
            Section {
                ForEach(watchedIndices, id: \.self) { sortedIndex in
                    let item = items[sortedIndex]
                    let itemBinding = Binding(
                        get: { items[sortedIndex] },
                        set: { newValue in
                            items[sortedIndex] = newValue
                        }
                    )
                    MediaListRow(
                        item: itemBinding,
                        itemID: item.media?.id ?? "",
                        expandedItemID: $expandedItemID,
                        subtitle: subtitleProvider(item),
                        onItemExpanded: onItemExpanded,
                        onWatchedToggled: {
                            var updatedItem = items[sortedIndex]
                            updatedItem.isWatched.toggle()
                            if updatedItem.isWatched {
                                updatedItem.watchedAt = Date()
                            } else {
                                updatedItem.watchedAt = nil
                            }
                            items[sortedIndex] = updatedItem
                            onWatchedToggled()
                        }
                    )
                }
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
