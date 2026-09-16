import Foundation
import SwiftData

func syncUnwatchedItems(
    allItems: [ListItem],
    currentUnwatched: [ListItem]
) -> [ListItem] {
    let currentOrder: [String: Int] = Dictionary(
        currentUnwatched.enumerated().map {
            ($0.element.media?.id ?? "", $0.offset)
        },
        uniquingKeysWith: { first, _ in first }
    )
    let newUnwatched = allItems.filter { !$0.isWatched }

    // Preserve order for items that are already in unwatched list, sort new items by order/addedAt
    let preservedOrder = newUnwatched.sorted { lhs, rhs in
        let lhsID = lhs.media?.id ?? ""
        let rhsID = rhs.media?.id ?? ""
        let lhsIndex = currentOrder[lhsID]
        let rhsIndex = currentOrder[rhsID]

        // If both are in current list, preserve their relative order
        if let lhsIdx = lhsIndex, let rhsIdx = rhsIndex {
            return lhsIdx < rhsIdx
        }

        // If only one is in current list, it comes first
        if lhsIndex != nil { return true }
        if rhsIndex != nil { return false }

        // Otherwise sort by order, then by addedAt
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.addedAt < rhs.addedAt
    }

    return preservedOrder
}

/// True when the item is included with at least one of the user's selected streaming services.
/// Rent/buy storefronts don't count — "on my services" means watchable at no extra cost.
func isOnSelectedServices(_ item: ListItem, selectedProviderIDs: Set<Int>) -> Bool {
    guard let media = item.media, let networks = media.networks else { return false }
    let categories = media.providerCategories
    return networks.contains { network in
        guard selectedProviderIDs.contains(network.id),
              let category = categories[network.id]
        else { return false }
        return category == "stream" || category == "ads"
    }
}

/// Applies the watchlist's filter chips (genre, watch option, "on my services") to a section.
/// Returns `items` untouched when nothing is filtering.
func filterItems(
    _ items: [ListItem],
    genre: String?,
    providerCategory: String?,
    onlyMyServices: Bool,
    selectedProviderIDs: Set<Int>
) -> [ListItem] {
    guard genre != nil || providerCategory != nil || onlyMyServices else { return items }
    var result = items
    if let genre {
        result = result.filter { $0.media?.genres.contains(genre) == true }
    }
    if let providerCategory {
        let rawCategories: Set<String>
        switch providerCategory {
        case "Stream": rawCategories = ["stream"]
        case "Free with Ads": rawCategories = ["ads"]
        case "Rent or Buy": rawCategories = ["rent", "buy"]
        default: rawCategories = []
        }
        result = result.filter { item in
            guard let categories = item.media?.providerCategories.values else { return false }
            return categories.contains(where: { rawCategories.contains($0) })
        }
    }
    if onlyMyServices {
        result = result.filter { isOnSelectedServices($0, selectedProviderIDs: selectedProviderIDs) }
    }
    return result
}
