import SwiftUI

/// Read-only episode list for one season, fetched from `/tv/{id}/season/{n}` on demand.
/// Nothing here is persisted — there is no episode-level watched state, only a look at
/// number, title, description, rating, air date, runtime and still image.
struct SeasonEpisodesView: View {
    let tvID: Int
    let showTitle: String
    let season: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var seasonDetail: TMDBSeasonDetail?
    @State private var isLoading = false
    @State private var loadError: String?

    private let service = TMDBService.shared

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.rowGap) {
                    header

                    if isLoading {
                        ForEach(0..<6, id: \.self) { _ in placeholderRow }
                    } else if let loadError {
                        EmptyStateView(
                            icon: "wifi.exclamationmark",
                            title: "Couldn't load episodes",
                            subtitle: loadError
                        ) {
                            Button("Try Again") {
                                Task { await loadSeason() }
                            }
                            .buttonStyle(.glassProminent)
                        }
                        .padding(.top, 40)
                    } else if let episodes = seasonDetail?.episodes, !episodes.isEmpty {
                        SeasonRatingsSnapshot(episodes: episodes) { episode in
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                scrollProxy.scrollTo(episode.id, anchor: .top)
                            }
                        }
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                                .id(episode.id)
                        }
                    } else {
                        EmptyStateView(icon: "list.number", title: "No episodes listed yet")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
                .padding(.vertical, DesignTokens.Spacing.section)
                // Keeps the column readable on the iPad page sheet, matching `MediaDetailView`.
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background { AppBackground() }
        .navigationTitle("Season \(season)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: season) {
            await loadSeason()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let overview = seasonDetail?.overview, !overview.isEmpty {
                ClampedDescriptionText(text: overview, lineLimit: 3)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Rows

    private func episodeRow(_ episode: TMDBSeasonEpisode) -> some View {
        let unaired = isUpcoming(episode)
        return HStack(alignment: .top, spacing: 12) {
            stillImage(episode)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Chip(text: "E\(episode.episodeNumber)")
                    Text(episode.name ?? "Episode \(episode.episodeNumber)")
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(unaired ? .secondary : .primary)
                }

                if metaText(for: episode) != nil || hasVote(episode) {
                    HStack(spacing: 6) {
                        if let metaText = metaText(for: episode) {
                            Text(metaText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if hasVote(episode), let vote = episode.voteAverage {
                            StarRatingLabel(vote: vote)
                        }
                    }
                }

                if let overview = episode.overview, !overview.isEmpty {
                    ClampedDescriptionText(text: overview, lineLimit: 3, font: .subheadline)
                }
            }
        }
        .padding(DesignTokens.Spacing.cardPadding)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private func stillImage(_ episode: TMDBSeasonEpisode) -> some View {
        Group {
            if let url = service.imageURL(path: episode.stillPath, size: .w300) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(.fill.tertiary)
                    }
                }
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.poster))
        // Decorative: the row's text already carries the episode's identity.
        .accessibilityHidden(true)
    }

    private var placeholderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.poster)
                .fill(.fill.tertiary)
                .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(.fill.tertiary).frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(.fill.tertiary).frame(width: 100, height: 10)
                RoundedRectangle(cornerRadius: 4).fill(.fill.tertiary).frame(height: 12)
            }
        }
        .padding(DesignTokens.Spacing.cardPadding)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .redacted(reason: .placeholder)
    }

    // MARK: - Helpers

    private func hasVote(_ episode: TMDBSeasonEpisode) -> Bool {
        (episode.voteCount ?? 0) > 0 && episode.voteAverage != nil
    }

    private func isUpcoming(_ episode: TMDBSeasonEpisode) -> Bool {
        guard let airDate = episode.airDate, let date = AirDateFormat.date(from: airDate) else { return false }
        return date > .now
    }

    /// "Jun 15 · 48 min", "Airs Jun 15", or nil when TMDB has neither.
    private func metaText(for episode: TMDBSeasonEpisode) -> String? {
        var parts: [String] = []
        if let airDate = episode.airDate, !airDate.isEmpty, let label = AirDateFormat.shortLabel(from: airDate) {
            parts.append(isUpcoming(episode) ? "Airs \(label)" : label)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func loadSeason() async {
        isLoading = true
        loadError = nil
        do {
            seasonDetail = try await service.getSeasonDetails(tvID: tvID, season: season)
        } catch {
            loadError = "Check your connection and try again."
        }
        isLoading = false
    }
}
