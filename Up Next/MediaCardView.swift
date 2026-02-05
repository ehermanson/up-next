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

    /// True when user has providers selected but no streaming services match
    private var showNotStreamingBadge: Bool {
        settings.hasSelectedProviders && selectedStreamingNetworks.isEmpty && !networks.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let imageURL = imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(width: 70, height: 100)
                .clipShape(.rect(cornerRadius: 14))
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 100)
                    .clipShape(.rect(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .lineLimit(2)
                    Spacer()
                    if isWatched {
                        Text("Watched")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
                            .accessibilityLabel("Watched")
                    }
                }
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showNotStreamingBadge {
                    Text("Not on your services")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    NetworkLogosView(
                        networks: visibleNetworks,
                        maxVisible: 4,
                        logoSize: 28,
                        additionalCount: settings.hasSelectedProviders ? additionalNetworkCount : 0
                    )
                }
            }
        }
        .padding(.all, 14)
        .glassEffect(.regular.tint(.white.opacity(0.03)).interactive(), in: .rect(cornerRadius: 20))
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
        subtitle: "2022 \u{00b7} Action, Adventure",
        imageURL: nil,
        networks: sampleNetworks,
        providerCategories: [8: "stream", 1899: "stream"],
        isWatched: true,
        watchedToggleAction: { _ in }
    )
}
