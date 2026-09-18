import SwiftUI

/// `cardSurface` with a selected-state tint, mirroring `cellSurface(tint:)`.
/// `tint` has no default so this never becomes ambiguous with `cardSurface(cornerRadius:)`.
private extension View {
    func cardSurface(cornerRadius: CGFloat, tint: Color?) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.fill.tertiary)
                .overlay {
                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius).fill(tint.opacity(0.2))
                    }
                }
        }
    }
}

struct WatchedToggleCard: View {
    @ObservedObject var listItem: ListItem

    private var seasonSubtitle: String? {
        guard let tvShow = listItem.tvShow,
              let total = tvShow.numberOfSeasons, total > 0
        else { return nil }
        let count = listItem.watchedSeasons.count
        if listItem.isWatched {
            return "Watched"
        } else if count > 0 {
            return "\(count) of \(total) seasons"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listItem.isWatched ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(listItem.isWatched ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mark as Watched")
                    .font(.headline)
                if let subtitle = seasonSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if listItem.isWatched {
                    Text("Watched")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Toggle("Mark as Watched", isOn: Binding(
                get: { listItem.isWatched },
                set: { newValue in
                    listItem.droppedAt = nil
                    if let tvShow = listItem.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                        if newValue {
                            listItem.watchedSeasons = Array(1...total)
                        } else {
                            listItem.watchedSeasons = []
                        }
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date.now : nil
                    } else {
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date.now : nil
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .cardSurface(
            cornerRadius: DesignTokens.Radius.cardCompact,
            tint: listItem.isWatched ? .green : nil
        )
        .sensoryFeedback(.selection, trigger: listItem.isWatched)
    }
}

struct UserRatingCard: View {
    @ObservedObject var listItem: ListItem

    private func isSelected(_ value: Int) -> Bool {
        listItem.userRating == value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Rating")
                .font(.headline)

            HStack(spacing: 12) {
                ratingButton(value: -1, icon: "hand.thumbsdown.fill", tint: .red, label: "Thumbs down")
                ratingButton(value: 0, icon: "minus.circle.fill", tint: .gray, label: "Meh")
                ratingButton(value: 1, icon: "hand.thumbsup.fill", tint: .green, label: "Thumbs up")
            }
            .sensoryFeedback(.selection, trigger: listItem.userRating)

            TextField("Add notes...", text: Binding(
                get: { listItem.userNotes ?? "" },
                set: { listItem.userNotes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.control))
        }
    }

    private func ratingButton(value: Int, icon: String, tint: Color, label: String) -> some View {
        let selected = isSelected(value)
        return Button {
            listItem.userRating = selected ? nil : value
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .cellSurface(
                    cornerRadius: DesignTokens.Radius.cardCompact,
                    tint: selected ? tint : nil
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SeasonChecklistCard: View {
    @ObservedObject var listItem: ListItem
    var ratings: [Int: Double] = [:]

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var episodeCounts: [Int] {
        listItem.tvShow?.seasonEpisodeCounts ?? []
    }

    private var seasonDescriptions: [String] {
        listItem.tvShow?.seasonDescriptions ?? []
    }

    /// nil when the show's id isn't a TMDB int (shouldn't happen for a persisted row) — the
    /// episodes chevron just doesn't render.
    private var tvID: Int? {
        listItem.tvShow.flatMap { Int($0.id) }
    }

    private var showTitle: String {
        listItem.tvShow?.title ?? ""
    }

    @State private var seasonEpisodes: [Int: [TMDBSeasonEpisode]] = [:]

    private let circleSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.headline)

            if let tvID, ratings.contains(where: {
                $0.key > 0 && $0.key <= (listItem.tvShow?.availableSeasonCount ?? 0)
            }) {
                SeasonComparisonChart(
                    tvID: tvID,
                    showTitle: showTitle,
                    seasonCount: totalSeasons,
                    availableSeasonCount: listItem.tvShow?.availableSeasonCount ?? 0,
                    ratings: ratings
                )
            }

            VStack(spacing: 0) {
                ForEach(1...max(totalSeasons, 1), id: \.self) { season in
                    seasonRow(season: season)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: listItem.watchedSeasons)
        .task(id: "\(tvID ?? 0):\(listItem.tvShow?.availableSeasonCount ?? 0)") {
            await loadEpisodeRatings()
        }
    }

    /// Caption for a season that exists on TMDB but can't be watched yet — an announcement, with
    /// its premiere date when TMDB has scheduled one.
    private func announcedCaption(season: Int) -> String {
        guard season == listItem.tvShow?.announcedSeasonNumber,
              let premiere = listItem.tvShow?.announcedSeasonPremiere
        else { return "Announced" }
        return "Premieres \(AirDateFormat.shortLabel(from: premiere) ?? premiere)"
    }

    private func seasonRow(season: Int) -> some View {
        let isWatched = listItem.watchedSeasons.contains(season)
        let episodeCount = season <= episodeCounts.count ? episodeCounts[season - 1] : nil
        let description = season <= seasonDescriptions.count ? seasonDescriptions[season - 1] : nil
        let isLast = season == totalSeasons
        // Announced seasons stay tappable — TMDB's data can lag a real airing — but read as
        // unavailable rather than as something the user is behind on.
        let isAnnounced = season > (listItem.tvShow?.availableSeasonCount ?? 0) && season <= totalSeasons

        return VStack(alignment: .leading, spacing: 2) {
            if let tvID {
                NavigationLink {
                    SeasonEpisodesView(tvID: tvID, showTitle: showTitle, season: season)
                } label: {
                    seasonHeader(season: season, episodeCount: episodeCount, isAnnounced: isAnnounced)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View Season \(season) details")
                .accessibilityValue(seasonAccessibilityValue(season, isWatched: isWatched, isAnnounced: isAnnounced))
            } else {
                seasonHeader(season: season, episodeCount: episodeCount, isAnnounced: isAnnounced)
            }

            if let description, !description.isEmpty {
                ClampedDescriptionText(text: description, lineLimit: 2, font: .caption, color: .secondary)
            }
            if !isAnnounced, let tvID, let episodes = seasonEpisodes[season],
               episodes.contains(where: { $0.snapshotRating != nil }) {
                NavigationLink {
                    SeasonEpisodesView(tvID: tvID, showTitle: showTitle, season: season)
                } label: {
                    CompactEpisodeRatings(episodes: episodes)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Season \(season) episode ratings")
                .accessibilityHint("Opens the full episode ratings and details")
                .padding(.top, 6)
            }
        }
        .padding(.leading, 56)
        .padding(.bottom, isLast ? 0 : 16)
        .overlay(alignment: .topLeading) {
            // A bounded target with a separate gutter; no row-sized watched button.
            Button {
                listItem.toggleSeason(season)
            } label: {
                watchedCircle(isWatched: isWatched, isAnnounced: isAnnounced)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark Season \(season) as \(isWatched ? "unwatched" : "watched")")
            .accessibilityValue(isWatched ? "Watched" : "Not watched")
            .accessibilityHint("Changes only this season")
            .accessibilityAddTraits(.isToggle)
        }
    }

    private func seasonHeader(season: Int, episodeCount: Int?, isAnnounced: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Season \(season)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isAnnounced ? .secondary : .primary)
                if isAnnounced {
                    Text(announcedCaption(season: season))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let count = episodeCount, count > 0 {
                    Text("\(count) episode\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !isAnnounced, let rating = ratings[season] {
                StarRatingLabel(vote: rating)
                    .monospacedDigit()
                    .fixedSize()
            }
            if tvID != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    /// Optional charts load sequentially to avoid a burst of requests for long-running shows.
    /// The service caches season responses, including when the episode page is opened next.
    private func loadEpisodeRatings() async {
        guard let tvID else { return }
        let available = listItem.tvShow?.availableSeasonCount ?? 0
        guard available > 0 else { return }
        for season in 1...available {
            guard !Task.isCancelled else { return }
            if seasonEpisodes[season] != nil { continue }
            do {
                let detail = try await TMDBService.shared.getSeasonDetails(tvID: tvID, season: season)
                guard !Task.isCancelled else { return }
                seasonEpisodes[season] = detail.episodes ?? []
            } catch {
                // Season information remains useful when this optional chart isn't available.
                if Task.isCancelled { return }
            }
        }
    }

    private func seasonAccessibilityValue(_ season: Int, isWatched: Bool, isAnnounced: Bool) -> String {
        let status = isWatched ? "Watched" : (isAnnounced ? "Announced" : "Not watched")
        guard !isAnnounced, let rating = ratings[season] else { return status }
        return "\(status), TMDB season rating \(rating.formatted(.number.precision(.fractionLength(1)))) out of 10"
    }

    private func watchedCircle(isWatched: Bool, isAnnounced: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isWatched ? AnyShapeStyle(Color.green.opacity(0.15)) : AnyShapeStyle(.fill.tertiary))
            Circle()
                .strokeBorder(
                    isWatched ? AnyShapeStyle(Color.green.opacity(0.6)) : AnyShapeStyle(.fill.secondary),
                    style: isAnnounced
                        ? StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        : StrokeStyle(lineWidth: 1.5)
                )
                .opacity(isAnnounced && !isWatched ? 0.6 : 1)
            if isWatched {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            }
        }
        .frame(width: circleSize, height: circleSize)
    }

}

/// Compact link to the read-only episode list, for shows that don't get a `SeasonChecklistCard`
/// (single-season shows, or the Discover/collection "add" context, where the checklist itself
/// doesn't apply but people browsing still want episode info).
struct EpisodesLinkCard: View {
    let tvID: Int
    let showTitle: String
    /// From `TVShow.seasonEpisodeCounts`; omitted from the caption when TMDB hasn't reported it.
    var episodeCount: Int?

    private var caption: String {
        guard let episodeCount, episodeCount > 0 else { return "Season 1" }
        return "Season 1 \u{00B7} \(episodeCount) episode\(episodeCount == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationLink {
            SeasonEpisodesView(tvID: tvID, showTitle: showTitle, season: 1)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Episodes")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        }
        .buttonStyle(.plain)
    }
}

struct DoneWatchingCard: View {
    @ObservedObject var listItem: ListItem

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    /// Measured against the seasons that have actually aired — same basis as the item's watched
    /// state, so a caught-up show with an announced season isn't offered "Drop Show".
    private var allSeasonsWatched: Bool {
        guard totalSeasons > 0 else { return false }
        let available = listItem.tvShow?.availableSeasonCount ?? 0
        guard available > 0 else { return false }
        return (1...available).allSatisfy { listItem.watchedSeasons.contains($0) }
    }

    /// Show card when: not all seasons watched (partial/none), OR already dropped
    private var shouldShow: Bool {
        listItem.isDropped || !allSeasonsWatched
    }

    var body: some View {
        if shouldShow {
            if listItem.isDropped {
                Button {
                    listItem.resumeShow()
                } label: {
                    cardLabel(
                        icon: "arrow.uturn.backward.circle.fill",
                        title: "Pick Back Up",
                        subtitle: "Move back to your watchlist"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            } else {
                Button {
                    listItem.dropShow()
                } label: {
                    cardLabel(
                        icon: "archivebox",
                        title: "Drop Show",
                        subtitle: "Move to your watched list"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    private func cardLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(14)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }
}
