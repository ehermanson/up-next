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

struct WatchingToggleCard: View {
    @ObservedObject var listItem: ListItem

    var body: some View {
        Button {
            withAnimation { listItem.toggleWatching() }
            PersistenceController.shared.save()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: listItem.isWatching ? "play.circle.fill" : "play.circle")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(listItem.watchingActionTitle).font(.headline)
                    Text(listItem.isWatching ? "Keep your season progress when you move this show." : "Keep this show at the top of your TV list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact, tint: listItem.isWatching ? Color.accentColor : nil)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: listItem.isWatching)
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
            withAnimation(Motion.pop) { listItem.userRating = selected ? nil : value }
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: selected)
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

/// Observe the show itself so asynchronously loaded season data updates every detail context.
struct DetailSeasonsSection: View {
    let listItem: ListItem
    @ObservedObject var tvShow: TVShow
    var ratings: [Int: Double]
    var allowsWatchedChanges: Bool

    var body: some View {
        if let total = tvShow.numberOfSeasons, total > 1 {
            SeasonChecklistCard(
                listItem: listItem,
                tvShow: tvShow,
                ratings: ratings,
                allowsWatchedChanges: allowsWatchedChanges
            )
        } else if tvShow.numberOfSeasons == 1, let tvID = Int(tvShow.id) {
            EpisodesLinkCard(
                tvID: tvID,
                showTitle: tvShow.title,
                episodeCount: tvShow.seasonEpisodeCounts.first
            )
        }
    }
}

struct SeasonChecklistCard: View {
    @ObservedObject var listItem: ListItem
    @ObservedObject var tvShow: TVShow
    var ratings: [Int: Double] = [:]
    var allowsWatchedChanges = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastState.self) private var toast

    /// Per-season pulse counters for the "caught up" wave. A `Task` bumps each in sequence; every
    /// checkmark runs its own self-contained pop (keyframe) when its counter changes, so the pops
    /// overlap — the next check starts rising before the previous one has settled — instead of a
    /// single crest that hands off instantly.
    @State private var pulseCounts: [Int: Int] = [:]

    private var totalSeasons: Int {
        tvShow.numberOfSeasons ?? 0
    }

    /// Seasons that have actually aired — the basis for "caught up" (an announced-but-unaired
    /// season doesn't count against the user).
    private var availableSeasonCount: Int {
        tvShow.availableSeasonCount
    }

    /// Every aired season is checked (and there's at least one). Drives the catch-up celebration.
    private var isCaughtUp: Bool {
        guard availableSeasonCount > 0 else { return false }
        return (1...availableSeasonCount).allSatisfy { listItem.watchedSeasons.contains($0) }
    }

    /// TMDB marks a show done with these statuses; anything else (incl. "Returning Series") means
    /// more may come, so completing it reads as "all caught up" rather than "finished".
    private var isEnded: Bool {
        let status = tvShow.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == "Ended" || status == "Canceled" || status == "Cancelled"
    }

    private var episodeCounts: [Int] {
        tvShow.seasonEpisodeCounts
    }

    private var seasonDescriptions: [String] {
        tvShow.seasonDescriptions
    }

    /// nil when the show's id isn't a TMDB int (shouldn't happen for a persisted row) — the
    /// episodes chevron just doesn't render.
    private var tvID: Int? {
        Int(tvShow.id)
    }

    private var showTitle: String {
        tvShow.title
    }

    @State private var seasonEpisodes: [Int: [TMDBSeasonEpisode]] = [:]

    private let circleSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.headline)

            if let tvID, ratings.contains(where: {
                $0.key > 0 && $0.key <= (tvShow.availableSeasonCount)
            }) {
                SeasonComparisonChart(
                    tvID: tvID,
                    showTitle: showTitle,
                    seasonCount: totalSeasons,
                    availableSeasonCount: tvShow.availableSeasonCount,
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
        // Only the library context can toggle seasons, so the catch-up moment can only originate
        // there. `onChange` never fires for the initial value, so reopening an already-complete
        // show stays quiet — the celebration is reserved for the check that completes the set.
        .onChange(of: isCaughtUp) { _, caughtUp in
            guard allowsWatchedChanges, caughtUp else { return }
            celebrateCatchUp()
        }
        .task(id: "\(tvID ?? 0):\(tvShow.availableSeasonCount)") {
            await loadEpisodeRatings()
        }
    }

    /// Checking the last aired season: pop a contextual toast and send a wave back across every
    /// checkmark. "Finished <show>" when TMDB says the show is done; "All caught up" when more
    /// seasons may still come. Reduce Motion keeps the toast but skips the wave.
    private func celebrateCatchUp() {
        toast.show(
            isEnded ? "Finished \(showTitle)" : "All caught up",
            icon: isEnded ? "checkmark.seal.fill" : "clock.badge.checkmark"
        )

        guard !reduceMotion else { return }
        let count = availableSeasonCount
        guard count > 0 else { return }
        Task {
            for season in 1...count {
                pulseCounts[season, default: 0] += 1
                // Shorter than a single pop's duration (~0.5s), so consecutive checks overlap.
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    /// Caption for a season that exists on TMDB but can't be watched yet — an announcement, with
    /// its premiere date when TMDB has scheduled one.
    private func announcedCaption(season: Int) -> String {
        guard season == tvShow.announcedSeasonNumber,
              let premiere = tvShow.announcedSeasonPremiere
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
        let isAnnounced = season > (tvShow.availableSeasonCount) && season <= totalSeasons

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
        .padding(.leading, allowsWatchedChanges ? 56 : 0)
        .padding(.bottom, isLast ? 0 : 16)
        .overlay(alignment: .topLeading) {
            if allowsWatchedChanges {
                // A bounded target with a separate gutter; no row-sized watched button.
                Button {
                    listItem.toggleSeason(season)
                } label: {
                    watchedCircle(season: season, isWatched: isWatched, isAnnounced: isAnnounced)
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
        let available = tvShow.availableSeasonCount
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
        let status = allowsWatchedChanges
            ? (isWatched ? "Watched" : (isAnnounced ? "Announced" : "Not watched"))
            : (isAnnounced ? "Announced" : "")
        guard !isAnnounced, let rating = ratings[season] else { return status }
        return [status, "TMDB season rating \(rating.formatted(.number.precision(.fractionLength(1)))) out of 10"]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func watchedCircle(season: Int, isWatched: Bool, isAnnounced: Bool) -> some View {
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
                    .transition(reduceMotion ? .identity : Motion.checkPop)
                    .symbolEffect(.bounce, value: reduceMotion ? false : isWatched)
            }
        }
        .frame(width: circleSize, height: circleSize)
        // Keyed to the value (not a `withAnimation` at the tap site) so the fill/border colour
        // and the checkmark's scale-in animate reliably even when the model mutation republishes
        // outside an animated transaction.
        .animation(reduceMotion ? nil : Motion.pop, value: isWatched)
        // Self-contained swell-and-settle for the catch-up wave, replayed when this season's pulse
        // counter ticks. Each pop outlasts the 140ms stagger, so neighbours overlap.
        .keyframeAnimator(initialValue: 1.0, trigger: pulseCounts[season] ?? 0) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1.4, duration: 0.2)
                CubicKeyframe(1.0, duration: 0.34)
            }
        }
    }

}

/// Compact link to the read-only episode list, for shows that don't get a `SeasonChecklistCard`
/// (shows confirmed to have exactly one season).
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
