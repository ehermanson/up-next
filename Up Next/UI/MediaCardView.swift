// SwiftUI view displaying a card for a media item (movie or TV show)
import SwiftData
import SwiftUI

struct MediaCardView: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let networks: [Network]
    let providerCategories: [Int: String]
    let isWatched: Bool
    var isCompact: Bool = false
    var voteAverage: Double?
    var genres: [String] = []
    var userRating: Int?
    var seasonProgress: (watchedSeasons: [Int], total: Int)? = nil
    var nextAirDate: String? = nil
    /// "S3E2" for the next episode. When present the chip reads "S3E2 · Jun 15" — the episode
    /// pointer already implies "next", so the prefix is dropped.
    var nextEpisodeCode: String? = nil

    private let settings = ProviderSettings.shared

    private var nextAirDateLabel: String? {
        guard let nextAirDate else { return nil }
        if let nextEpisodeCode, let day = AirDateFormat.shortLabel(from: nextAirDate) {
            return "\(nextEpisodeCode) \u{00B7} \(day)"
        }
        return AirDateFormat.nextLabel(from: nextAirDate)
    }

    /// Streaming networks that match user's selected providers
    private var selectedStreamingNetworks: [Network] {
        networks.filter { network in
            let category = providerCategories[network.id]
            let isStreaming = category == "stream" || category == "ads"
            return isStreaming && settings.isSelected(network.id)
        }
    }

    /// Count of additional networks (rent/buy + non-selected streaming)
    private var additionalNetworkCount: Int {
        networks.count - selectedStreamingNetworks.count
    }

    /// Networks to display as logos (just selected streaming services)
    private var visibleNetworks: [Network] {
        // If no providers selected, show all networks normally
        if !settings.hasSelectedProviders {
            return networks
        }
        return selectedStreamingNetworks
    }

    private var posterSize: CGSize {
        isCompact ? CGSize(width: 60, height: 90) : CGSize(width: 82, height: 123)
    }

    private var cardCornerRadius: CGFloat {
        isCompact ? DesignTokens.Radius.cardCompact : DesignTokens.Radius.card
    }

    private var posterCornerRadius: CGFloat {
        isCompact ? DesignTokens.Radius.posterSmall : DesignTokens.Radius.poster
    }

    /// Spoken description of the watched badge, including the thumbs rating when present.
    private var watchedBadgeLabel: String {
        switch userRating {
        case 1: return "Watched, liked"
        case 0: return "Watched, no opinion"
        case -1: return "Watched, disliked"
        default: return "Watched"
        }
    }

    var body: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            poster

            VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
                HStack {
                    Text(title)
                        .font(isCompact ? .subheadline : .headline)
                        .lineLimit(isCompact ? 1 : 2)
                    Spacer()
                    if isWatched && !isCompact {
                        watchedBadge
                    }
                }
                if !isCompact {
                    HStack(spacing: 6) {
                        if let subtitle = subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let vote = voteAverage, vote > 0 {
                            StarRatingLabel(vote: vote)
                        }
                    }
                    if !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !isCompact {
                    NetworkLogosView(
                        networks: visibleNetworks,
                        maxVisible: 4,
                        logoSize: 28,
                        additionalCount: settings.hasSelectedProviders ? additionalNetworkCount : 0
                    )

                    if let progress = seasonProgress, progress.total > 0 {
                        SeasonProgressBar(watchedSeasons: progress.watchedSeasons, total: progress.total)
                    }
                }
            }
        }
        .padding(isCompact ? 8 : 10)
        .overlay(alignment: .bottomTrailing) {
            if let label = nextAirDateLabel, !isCompact {
                Chip(icon: "calendar", text: label)
                    .padding(6)
            }
        }
        .cardSurface(cornerRadius: cardCornerRadius)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var poster: some View {
        Group {
            if let imageURL = imageURL {
                CachedAsyncImage(url: imageURL) { phase in
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
        .frame(width: posterSize.width, height: posterSize.height)
        .clipShape(.rect(cornerRadius: posterCornerRadius))
        .accessibilityHidden(true)
    }

    private var watchedBadge: some View {
        Group {
            if let userRating {
                Image(systemName: userRating == 1 ? "hand.thumbsup.fill"
                      : userRating == 0 ? "minus.circle.fill"
                      : "hand.thumbsdown.fill")
                    .font(.caption)
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
        }
        .foregroundStyle(.secondary)
        .padding(6)
        .background(.fill.tertiary, in: .circle)
        .accessibilityLabel(watchedBadgeLabel)
    }
}

private struct SeasonProgressBar: View {
    let watchedSeasons: [Int]
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...total, id: \.self) { season in
                let isWatched = watchedSeasons.contains(season)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isWatched ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary))
                    .frame(width: 12, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(watchedSeasons.count) of \(total) seasons watched")
    }
}

// MARK: - Previews

private let previewNetworks = [
    Network(
        id: 8,
        name: "Netflix",
        logoPath: "/pbpMk2JmcoNnQwx5JGpXngfoWtp.png",
        originCountry: "US"
    ),
    Network(
        id: 1899,
        name: "HBO Max",
        logoPath: "/6Q3ZYUNA9Hsgj6iWnVsw2gR5V77.png",
        originCountry: "US"
    ),
]

#Preview("Unwatched TV Show") {
    ZStack {
        AppBackground()
        MediaCardView(
            title: "Severance",
            subtitle: "Season 2",
            imageURL: nil,
            networks: previewNetworks,
            providerCategories: [8: "stream"],
            isWatched: false,
            voteAverage: 8.3,
            genres: ["Drama", "Sci-Fi", "Thriller"],
            seasonProgress: (watchedSeasons: [1, 2], total: 5),
            nextAirDate: "2026-03-15",
            nextEpisodeCode: "S3E2"
        )
        .padding()
    }
}

#Preview("Unwatched Movie") {
    ZStack {
        AppBackground()
        MediaCardView(
            title: "Dune: Part Two",
            subtitle: "2024 · 166 min",
            imageURL: nil,
            networks: previewNetworks,
            providerCategories: [8: "stream", 1899: "stream"],
            isWatched: false,
            voteAverage: 8.1,
            genres: ["Sci-Fi", "Adventure"]
        )
        .padding()
    }
}

#Preview("Compact Card") {
    ZStack {
        AppBackground()
        MediaCardView(
            title: "The Bear",
            subtitle: "Season 3",
            imageURL: nil,
            networks: [],
            providerCategories: [:],
            isWatched: false,
            isCompact: true
        )
        .padding()
    }
}

#Preview("Watched with Rating") {
    ZStack {
        AppBackground()
        MediaCardView(
            title: "Example Movie Title",
            subtitle: "2022 · 148 min",
            imageURL: nil,
            networks: previewNetworks,
            providerCategories: [8: "stream", 1899: "stream"],
            isWatched: true,
            voteAverage: 7.8,
            genres: ["Action", "Adventure", "Thriller"],
            userRating: 1
        )
        .padding()
    }
}
