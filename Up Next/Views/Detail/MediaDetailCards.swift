import SwiftUI

struct WatchedToggleCard: View {
    @Binding var listItem: ListItem

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

            Toggle("", isOn: Binding(
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
        .glassEffect(.regular.tint(listItem.isWatched ? .green.opacity(0.1) : .clear), in: .rect(cornerRadius: 20))
    }
}

struct UserRatingCard: View {
    @Binding var listItem: ListItem

    private func isSelected(_ value: Int) -> Bool {
        listItem.userRating == value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Rating")
                .font(.headline)

            HStack(spacing: 12) {
                ratingButton(value: -1, icon: "hand.thumbsdown.fill", tint: .red)
                ratingButton(value: 0, icon: "minus.circle.fill", tint: .gray)
                ratingButton(value: 1, icon: "hand.thumbsup.fill", tint: .green)
            }

            TextField("Add notes...", text: Binding(
                get: { listItem.userNotes ?? "" },
                set: { listItem.userNotes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .padding(12)
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: .rect(cornerRadius: 14))
        }
    }

    private func ratingButton(value: Int, icon: String, tint: Color) -> some View {
        let selected = isSelected(value)
        return Button {
            listItem.userRating = selected ? nil : value
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(selected ? tint : .secondary.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular.tint(selected ? tint.opacity(0.2) : .clear),
                    in: .rect(cornerRadius: 16)
                )
        }
        .buttonStyle(.plain)
    }
}

struct SeasonChecklistCard: View {
    @Binding var listItem: ListItem

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
    }

    private func toggleSeason(_ season: Int) {
        if listItem.watchedSeasons.contains(season) {
            listItem.watchedSeasons.removeAll { $0 == season }
        } else {
            listItem.watchedSeasons.append(season)
        }
        // If all seasons are now watched while dropped, clear the drop (legitimately complete)
        if listItem.isDropped, let total = listItem.tvShow?.numberOfSeasons, total > 0 {
            let allWatched = (1...total).allSatisfy { listItem.watchedSeasons.contains($0) }
            if allWatched { listItem.droppedAt = nil }
        }
        listItem.syncWatchedStateFromSeasons()
    }

    private func seasonRow(season: Int) -> some View {
        let isWatched = listItem.watchedSeasons.contains(season)
        let episodeCount = season <= episodeCounts.count ? episodeCounts[season - 1] : nil
        let description = season <= seasonDescriptions.count ? seasonDescriptions[season - 1] : nil
        let isLast = season == totalSeasons
        let isExpanded = expandedSeasons.contains(season)

        return HStack(alignment: .top, spacing: 12) {
            // Timeline: circle + connector line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(isWatched ? Color.green.opacity(0.15) : Color.white.opacity(0.05))
                    Circle()
                        .strokeBorder(isWatched ? Color.green.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1.5)
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
                        .fill(isWatched ? Color.green.opacity(0.3) : Color.white.opacity(0.06))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: circleSize)

            // Season info
            VStack(alignment: .leading, spacing: 2) {
                Text("Season \(season)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let count = episodeCount, count > 0 {
                    Text("\(count) episode\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(isExpanded ? nil : 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedSeasons.remove(season)
                                } else {
                                    expandedSeasons.insert(season)
                                }
                            }
                        }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(.bottom, isLast ? 0 : 12)
        .contentShape(Rectangle())
        .onTapGesture { toggleSeason(season) }
    }
}

struct DoneWatchingCard: View {
    @Binding var listItem: ListItem

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var allSeasonsWatched: Bool {
        guard totalSeasons > 0 else { return false }
        return (1...totalSeasons).allSatisfy { listItem.watchedSeasons.contains($0) }
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
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pick Back Up")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Move back to your watchlist")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            } else {
                Button {
                    listItem.dropShow()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Drop Show")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Move to your watched list")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }
}
