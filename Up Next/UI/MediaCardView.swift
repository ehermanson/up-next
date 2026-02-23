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
    let watchedToggleAction: (Bool) -> Void
    var isCompact: Bool = false
    var voteAverage: Double?
    var genres: [String] = []
    var userRating: Int?
    var seasonProgress: (watchedSeasons: [Int], total: Int)? = nil
    var nextAirDate: String? = nil

    private let settings = ProviderSettings.shared

    private static let airDateInput: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var formattedAirDate: String? {
        guard let raw = nextAirDate,
              let date = Self.airDateInput.date(from: raw) else { return nil }
        return Self.airDateDisplay.string(from: date)
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
        isCompact ? 16 : 20
    }

    var body: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            if let imageURL = imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(width: posterSize.width, height: posterSize.height)
                .clipShape(.rect(cornerRadius: isCompact ? 8 : 10))
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: posterSize.width, height: posterSize.height)
                    .clipShape(.rect(cornerRadius: isCompact ? 8 : 10))
            }

            VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
                HStack {
                    Text(title)
                        .font(isCompact ? .subheadline : .headline)
                        .fontDesign(.rounded)
                        .lineLimit(isCompact ? 1 : 2)
                    Spacer()
                    if isWatched && !isCompact {
                        Group {
                            if let userRating {
                                Image(systemName: userRating == 1 ? "hand.thumbsup.fill"
                                      : userRating == 0 ? "minus.circle.fill"
                                      : "hand.thumbsdown.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityLabel("Watched")
                    }
                }
                if !isCompact {
                    HStack(spacing: 6) {
                        if let subtitle = subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .fontDesign(.rounded)
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
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .fontDesign(.rounded)
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
            if let formatted = formattedAirDate, !isCompact {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                    Text("Next: \(formatted)")
                }
                .font(.caption2)
                .fontDesign(.rounded)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(6)
            }
        }
        .glassEffect(.regular.tint(.white.opacity(0.03)).interactive(), in: .rect(cornerRadius: cardCornerRadius))
    }
}

private struct SeasonProgressBar: View {
    let watchedSeasons: [Int]
    let total: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...total, id: \.self) { season in
                if season > 1 {
                    let prevWatched = watchedSeasons.contains(season - 1)
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(prevWatched ? Color.green.opacity(0.35) : Color.white.opacity(0.06))
                        .frame(width: 6, height: 1.5)
                }

                let isWatched = watchedSeasons.contains(season)
                Circle()
                    .fill(isWatched ? Color.green.opacity(0.6) : Color.white.opacity(0.06))
                    .stroke(isWatched ? Color.green.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1)
                    .frame(width: 6, height: 6)
            }
        }
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
    MediaCardView(
        title: "Severance",
        subtitle: "Season 2",
        imageURL: nil,
        networks: previewNetworks,
        providerCategories: [8: "stream"],
        isWatched: false,
        watchedToggleAction: { _ in },
        voteAverage: 8.3,
        genres: ["Drama", "Sci-Fi", "Thriller"],
        seasonProgress: (watchedSeasons: [1], total: 2),
        nextAirDate: "2026-03-15"
    )
    .padding()
}

#Preview("Unwatched Movie") {
    MediaCardView(
        title: "Dune: Part Two",
        subtitle: "2024 · 166 min",
        imageURL: nil,
        networks: previewNetworks,
        providerCategories: [8: "stream", 1899: "stream"],
        isWatched: false,
        watchedToggleAction: { _ in },
        voteAverage: 8.1,
        genres: ["Sci-Fi", "Adventure"]
    )
    .padding()
}

#Preview("Compact Card") {
    MediaCardView(
        title: "The Bear",
        subtitle: "Season 3",
        imageURL: nil,
        networks: [],
        providerCategories: [:],
        isWatched: false,
        watchedToggleAction: { _ in },
        isCompact: true
    )
    .padding()
}

#Preview("Watched with Rating") {
    MediaCardView(
        title: "Example Movie Title",
        subtitle: "2022 · 148 min",
        imageURL: nil,
        networks: previewNetworks,
        providerCategories: [8: "stream", 1899: "stream"],
        isWatched: true,
        watchedToggleAction: { _ in },
        voteAverage: 7.8,
        genres: ["Action", "Adventure", "Thriller"],
        userRating: 1
    )
    .padding()
}
