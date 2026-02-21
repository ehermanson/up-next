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

    private let settings = ProviderSettings.shared

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

    private var imageSize: CGSize {
        isCompact ? CGSize(width: 54, height: 78) : CGSize(width: 70, height: 100)
    }

    private var cardCornerRadius: CGFloat {
        isCompact ? 16 : 20
    }

    private var leadingClipShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cardCornerRadius,
            bottomLeadingRadius: cardCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
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
                .frame(width: imageSize.width)
                .frame(minHeight: imageSize.height, maxHeight: .infinity)
                .clipShape(leadingClipShape)
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: imageSize.width)
                    .frame(minHeight: imageSize.height, maxHeight: .infinity)
                    .clipShape(leadingClipShape)
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
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(isCompact ? .caption : .subheadline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !isCompact {
                    HStack(spacing: 6) {
                        if !genres.isEmpty {
                            Text(genres.prefix(3).joined(separator: ", "))
                                .font(.caption)
                                .fontDesign(.rounded)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let vote = voteAverage, vote > 0 {
                            StarRatingLabel(vote: vote)
                        }
                    }
                }
                if !isCompact {
                    NetworkLogosView(
                        networks: visibleNetworks,
                        maxVisible: 4,
                        logoSize: 28,
                        additionalCount: settings.hasSelectedProviders ? additionalNetworkCount : 0
                    )
                }
            }
            .padding(.vertical, isCompact ? 10 : 12)
            .padding(.trailing, isCompact ? 10 : 12)
        }
        .glassEffect(.regular.tint(.white.opacity(0.03)).interactive(), in: .rect(cornerRadius: cardCornerRadius))
    }
}

#Preview {
    let sampleNetworks = [
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
    MediaCardView(
        title: "Example Movie Title",
        subtitle: "2022 \u{00b7} 148 min",
        imageURL: nil,
        networks: sampleNetworks,
        providerCategories: [8: "stream", 1899: "stream"],
        isWatched: true,
        watchedToggleAction: { _ in },
        voteAverage: 7.8,
        genres: ["Action", "Adventure", "Thriller"],
        userRating: 1
    )
}
