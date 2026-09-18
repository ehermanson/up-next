import Foundation

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
    let newUnwatched = allItems.filter { !$0.isWatched && !$0.isWatching }

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

// MARK: - Upcoming

/// A watchlist item with a release/air date that hasn't happened yet, rendered in the
/// "Returning Soon" / "Coming Soon" strip above the list.
struct UpcomingEntry: Identifiable {
    let item: ListItem
    let date: Date
    /// "Today" / "Tomorrow" / "Thursday" / "Jun 15".
    let dateLabel: String
    /// "S3E2" (optionally " · Episode Title") for TV; nil for movies.
    let detail: String?
    /// Namespaced so it can never collide with a list row's media-id identity.
    var id: String
}

/// "S3E2", or nil when TMDB didn't give us both numbers.
func episodeCode(season: Int?, episode: Int?) -> String? {
    guard let season, let episode else { return nil }
    return "S\(season)E\(episode)"
}

/// TMDB falls back to "Episode 7" when an episode has no real title — not worth showing.
func isGenericEpisodeName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("episode ") else { return false }
    let suffix = trimmed.dropFirst("episode ".count).trimmingCharacters(in: .whitespaces)
    return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
}

/// Upcoming episodes (TV) or releases (movies) within the next `windowDays`, soonest first.
///
/// TV includes season premieres for caught-up shows outside Watching, never dropped ones.
/// Movies only include unwatched items, and only those
/// releasing *after* today (a movie released today is already watchable, not "coming soon").
/// The window keeps far-off placeholder dates (TMDB will happily report a premiere ten months
/// out) from squatting at the top of the list.
func upcomingEntries(
    from items: [ListItem],
    mediaType: MediaType,
    now: Date = .now,
    windowDays: Int = 30,
    limit: Int = 12
) -> [UpcomingEntry] {
    let today = AirDateFormat.startOfUTCDay(for: now)
    let horizon = today.addingTimeInterval(TimeInterval(windowDays) * 24 * 60 * 60)
    var entries: [UpcomingEntry] = []

    for item in items {
        guard let mediaID = item.media?.id else { continue }

        let date: Date
        let detail: String?

        switch mediaType {
        case .tvShow:
            guard !item.isDropped, !item.isWatching, item.isWatched,
                  let tvShow = item.tvShow,
                  tvShow.nextEpisodeNumber == 1,
                  let airDate = tvShow.nextEpisodeAirDate,
                  let parsed = AirDateFormat.date(from: airDate),
                  parsed >= today, parsed <= horizon
            else { continue }
            date = parsed
            if let code = episodeCode(season: tvShow.nextEpisodeSeason, episode: tvShow.nextEpisodeNumber) {
                let name = tvShow.nextEpisodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail = name.isEmpty || isGenericEpisodeName(name) ? code : "\(code) \u{00B7} \(name)"
            } else {
                detail = nil
            }
        case .movie:
            guard !item.isWatched,
                  let movie = item.movie,
                  let releaseDate = movie.releaseDate,
                  let parsed = AirDateFormat.date(from: releaseDate),
                  parsed > today, parsed <= horizon
            else { continue }
            date = parsed
            detail = nil
        }

        entries.append(
            UpcomingEntry(
                item: item,
                date: date,
                dateLabel: AirDateFormat.relativeLabel(for: date, now: now),
                detail: detail,
                id: "upcoming:" + mediaID
            )
        )
    }

    let sorted = entries.sorted { lhs, rhs in
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return (lhs.item.media?.title ?? "") < (rhs.item.media?.title ?? "")
    }
    return Array(sorted.prefix(limit))
}
