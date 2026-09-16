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

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var episodeCounts: [Int] {
        listItem.tvShow?.seasonEpisodeCounts ?? []
    }

    private var seasonDescriptions: [String] {
        listItem.tvShow?.seasonDescriptions ?? []
    }

    @State private var expandedSeasons: Set<Int> = []

    private let circleSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(1...max(totalSeasons, 1), id: \.self) { season in
                    seasonRow(season: season)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: listItem.watchedSeasons)
    }

    private func toggleDescription(_ season: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedSeasons.contains(season) {
                expandedSeasons.remove(season)
            } else {
                expandedSeasons.insert(season)
            }
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
        let isExpanded = expandedSeasons.contains(season)
        // Announced seasons stay tappable — TMDB's data can lag a real airing — but read as
        // unavailable rather than as something the user is behind on.
        let isAnnounced = season > (listItem.tvShow?.availableSeasonCount ?? 0) && season <= totalSeasons

        return VStack(alignment: .leading, spacing: 2) {
            Button {
                listItem.toggleSeason(season)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Season \(season)")
                        .font(.subheadline)
                        .fontWeight(.medium)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Season \(season)")
            .accessibilityValue(isWatched ? "Watched" : (isAnnounced ? "Announced" : "Not watched"))
            .accessibilityAddTraits(.isToggle)

            if let description, !description.isEmpty {
                Button {
                    toggleDescription(season)
                } label: {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse season description" : "Expand season description")
            }
        }
        .padding(.top, 4)
        .padding(.leading, circleSize + 12)
        .padding(.bottom, isLast ? 0 : 12)
        // The timeline sits in the gutter the leading padding reserves, so it can span the
        // row's full height (circle + connector) regardless of how tall the text is.
        .overlay(alignment: .topLeading) {
            Button {
                listItem.toggleSeason(season)
            } label: {
                timeline(isWatched: isWatched, isLast: isLast, isAnnounced: isAnnounced)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }

    private func timeline(isWatched: Bool, isLast: Bool, isAnnounced: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isWatched ? AnyShapeStyle(Color.green.opacity(0.15)) : AnyShapeStyle(.fill.tertiary))
                Circle()
                    .strokeBorder(
                        isWatched ? AnyShapeStyle(Color.green.opacity(0.6)) : AnyShapeStyle(.fill.secondary),
                        // Dashed and fainter: this season isn't out yet.
                        style: isAnnounced
                            ? StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                            : StrokeStyle(lineWidth: 1.5)
                    )
                    .opacity(isAnnounced && !isWatched ? 0.6 : 1)
                if isWatched {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: circleSize, height: circleSize)

            if !isLast {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isWatched ? AnyShapeStyle(Color.green.opacity(0.3)) : AnyShapeStyle(.fill.tertiary))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: circleSize)
        .contentShape(.rect)
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
