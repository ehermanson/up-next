import Foundation
import SwiftData

func syncUnwatchedItems(
    allItems: [ListItem],
    currentUnwatched: [ListItem]
) -> [ListItem] {
    let currentOrder: [String: Int] = Dictionary(
        uniqueKeysWithValues: currentUnwatched.enumerated().map {
            ($0.element.media?.id ?? "", $0.offset)
        }
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
