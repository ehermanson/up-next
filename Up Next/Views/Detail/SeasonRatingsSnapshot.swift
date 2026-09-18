import SwiftUI

/// Shared bar geometry for season, episode, and compact charts. The plot's bottom is always
/// zero; labels are overlays so their size cannot move the bar or change its measured height.
struct RatingChartBar<ScoreLabel: View>: View {
    enum LabelPlacement {
        case inside
        case above
    }

    let rating: Double?
    let plotHeight: CGFloat
    let cornerRadius: CGFloat
    let fillOpacity: Double
    let labelHeight: CGFloat
    var labelPlacement: LabelPlacement = .inside
    @ViewBuilder var scoreLabel: () -> ScoreLabel

    private var barHeight: CGFloat {
        rating.map { max(2, plotHeight * $0 / 10) } ?? 2
    }

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius)
            .fill(.tint.opacity(fillOpacity))
            .frame(height: barHeight)
            .overlay(alignment: .top) {
                scoreLabel()
                    .frame(height: labelHeight)
                    .offset(y: labelPlacement == .above ? -labelHeight - 4 : min(4, barHeight - labelHeight))
            }
            .frame(height: plotHeight, alignment: .bottom)
    }
}

/// Season-level scores from the show response, aligned to a shared zero baseline.
struct SeasonComparisonChart: View {
    let tvID: Int
    let showTitle: String
    let seasonCount: Int
    let availableSeasonCount: Int
    let ratings: [Int: Double]

    @ScaledMetric(relativeTo: .caption) private var minimumWidth = 30.0
    @ScaledMetric(relativeTo: .caption) private var plotHeight = 64.0
    @ScaledMetric(relativeTo: .caption) private var labelHeight = 24.0

    /// Unweighted mean of the same available, valid season scores shown by the bars.
    private var seasonAverage: Double? {
        guard seasonCount > 0 else { return nil }
        let scores = (1...seasonCount).compactMap { rating(for: $0) }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    chartTitle
                    Spacer(minLength: 12)
                    seasonAverageLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    chartTitle
                    seasonAverageLabel
                }
            }

            GeometryReader { geometry in
                let count = max(1, seasonCount)
                let gap = count >= 8 ? 4.0 : 8.0
                let width = max(minimumWidth, (geometry.size.width - gap * Double(count - 1)) / Double(count))
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(1...count, id: \.self) { season in
                            let score = rating(for: season)
                            NavigationLink {
                                SeasonEpisodesView(tvID: tvID, showTitle: showTitle, season: season)
                            } label: {
                                VStack(spacing: 4) {
                                    RatingChartBar(
                                        rating: score,
                                        plotHeight: plotHeight,
                                        cornerRadius: 4,
                                        fillOpacity: score == nil ? 0.1 : 0.45,
                                        labelHeight: labelHeight,
                                        labelPlacement: .above
                                    ) {
                                        Group {
                                            if let score {
                                                Text(score, format: .number.precision(.fractionLength(1)))
                                            } else {
                                                Text("—")
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(score == nil ? .secondary : .primary)
                                    }
                                    .frame(height: plotHeight + labelHeight + 4, alignment: .bottom)

                                    Text("S\(season)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(height: labelHeight)
                                }
                                .frame(width: width)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Season \(season)")
                            .accessibilityValue(score.map {
                                "TMDB rating \($0.formatted(.number.precision(.fractionLength(1)))) out of 10"
                            } ?? "Not rated")
                            .accessibilityHint("Opens season details")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let seasonAverage {
                            // Bars share a baseline below the score-label region. Keep the reference
                            // line on that same 0–10 scale across the entire scrollable plot.
                            Path { path in
                                let y = labelHeight + 4 + plotHeight * (1 - seasonAverage / 10)
                                let contentWidth = max(geometry.size.width,
                                    (width + gap) * Double(count) - gap)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: contentWidth, y: y))
                            }
                            .stroke(.secondary, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .frame(height: plotHeight + labelHeight * 2 + 12)
        }
    }

    private var chartTitle: some View {
        Text("Season ratings")
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("TMDB season ratings out of 10")
    }

    @ViewBuilder
    private var seasonAverageLabel: some View {
        if let seasonAverage {
            HStack(spacing: 5) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4))
                    path.addLine(to: CGPoint(x: 18, y: 4))
                }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
                .frame(width: 18, height: 8)
                Text("Season avg \(seasonAverage.formatted(.number.precision(.fractionLength(1))))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Average of rated seasons: \(seasonAverage.formatted(.number.precision(.fractionLength(1)))) out of 10. Dotted reference line.")
        }
    }

    private func rating(for season: Int) -> Double? {
        guard season <= availableSeasonCount, let score = ratings[season],
              score.isFinite, score > 0, score <= 10 else { return nil }
        return score
    }
}

/// A small, zero-based ratings chart using the season response already loaded by the page.
struct SeasonRatingsSnapshot: View {
    let episodes: [TMDBSeasonEpisode]
    let onSelect: (TMDBSeasonEpisode) -> Void

    @ScaledMetric(relativeTo: .caption) private var minimumBarWidth = 44.0
    @ScaledMetric(relativeTo: .caption) private var plotHeight = 88.0
    @ScaledMetric(relativeTo: .caption) private var labelHeight = 24.0

    private var ratedEpisodes: [TMDBSeasonEpisode] {
        episodes.filter { $0.snapshotRating != nil }
    }

    /// Mean of rated episode scores, not a vote-weighted season rating.
    private var average: Double? {
        let ratings = ratedEpisodes.compactMap(\.snapshotRating)
        guard !ratings.isEmpty else { return nil }
        return ratings.reduce(0, +) / Double(ratings.count)
    }

    var body: some View {
        if let average {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Episode ratings").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 12)
                        averageLabel(average)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Episode ratings").font(.subheadline.weight(.semibold))
                        averageLabel(average)
                    }
                }

                GeometryReader { geometry in
                    let spacing = 6.0
                    let width = max(minimumBarWidth,
                                    (geometry.size.width - spacing * Double(episodes.count - 1)) / Double(episodes.count))
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(episodes) { episode in
                                ratingBar(episode, width: width)
                            }
                        }
                        .background(alignment: .top) {
                            // The same 0–10 scale is used for every season and the mean line.
                            Path { path in
                                let y = plotHeight * (1 - average / 10)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: max(geometry.size.width,
                                    (width + spacing) * Double(episodes.count) - spacing), y: y))
                            }
                            .stroke(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .accessibilityHidden(true)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
                .frame(height: plotHeight + labelHeight + 8)

                Text("TMDB · Out of 10 · Tap a bar for episode details")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignTokens.Spacing.cardPadding)
            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        }
    }

    private func averageLabel(_ average: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            Text(average, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
            Text("episode avg").foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Average of \(ratedEpisodes.count) rated episodes: \(average.formatted(.number.precision(.fractionLength(1)))) out of 10")
    }

    private func ratingBar(_ episode: TMDBSeasonEpisode, width: Double) -> some View {
        let rating = episode.snapshotRating
        return Button {
            onSelect(episode)
        } label: {
            VStack(spacing: 4) {
                RatingChartBar(
                    rating: rating,
                    plotHeight: plotHeight,
                    cornerRadius: 5,
                    fillOpacity: rating == nil ? 0 : 0.22,
                    labelHeight: labelHeight
                ) {
                    if let rating {
                        Text(rating, format: .number.precision(.fractionLength(1)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("E\(episode.episodeNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: labelHeight)
            }
            .frame(width: width)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Episode \(episode.episodeNumber), \(episode.name ?? "Untitled")")
        .accessibilityValue(rating.map { "\($0.formatted(.number.precision(.fractionLength(1)))) out of 10" } ?? "Not rated")
        .accessibilityHint("Shows episode details")
    }
}

/// An entire season in one small strip. Labels appear only when each bar has room;
/// the full episode page retains individual values and larger touch targets.
struct CompactEpisodeRatings: View {
    let episodes: [TMDBSeasonEpisode]

    @ScaledMetric(relativeTo: .caption2) private var plotHeight = 32.0
    @ScaledMetric(relativeTo: .caption2) private var scoreWidth = 28.0
    @ScaledMetric(relativeTo: .caption2) private var scoreHeight = 16.0

    private var average: Double? {
        let ratings = episodes.compactMap(\.snapshotRating)
        guard !ratings.isEmpty else { return nil }
        return ratings.reduce(0, +) / Double(ratings.count)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let gap = min(episodes.count > 24 ? 1.0 : 3.0, geometry.size.width / Double(max(1, episodes.count)) * 0.2)
                let width = max(1, (geometry.size.width - gap * Double(max(0, episodes.count - 1))) / Double(max(1, episodes.count)))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(episodes) { episode in
                        let rating = episode.snapshotRating
                        RatingChartBar(
                            rating: rating,
                            plotHeight: plotHeight,
                            cornerRadius: 2,
                            fillOpacity: rating == nil ? 0.1 : 0.35,
                            labelHeight: scoreHeight
                        ) {
                            if width >= scoreWidth, let rating {
                                Text(rating, format: .number.precision(.fractionLength(1)))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .overlay {
                    if let average {
                        Path { path in
                            let y = plotHeight * (1 - average / 10)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: plotHeight)

            HStack {
                if let first = episodes.first {
                    Text("E\(first.episodeNumber)")
                }
                Spacer()
                if episodes.count > 1, let last = episodes.last {
                    Text("E\(last.episodeNumber)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(episodes.count) episode ratings")
        .accessibilityValue(average.map {
            "Episode average \($0.formatted(.number.precision(.fractionLength(1)))) out of 10"
        } ?? "Not rated")
    }
}

extension TMDBSeasonEpisode {
    var snapshotRating: Double? {
        guard let voteAverage, voteAverage.isFinite, (0...10).contains(voteAverage),
              (voteCount ?? 0) > 0 else { return nil }
        if let airDate, let date = AirDateFormat.date(from: airDate), date > .now {
            return nil
        }
        return voteAverage
    }
}
