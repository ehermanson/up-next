import SwiftUI

struct DetailProviderRow: View {
    let networks: [Network]
    let providerCategories: [Int: String]
    @State private var tooltipNetworkID: Int?

    private let logoSize: CGFloat = 44

    private var hasCategories: Bool {
        !providerCategories.isEmpty
    }

    private var streamNetworks: [Network] {
        networks.filter { providerCategories[$0.id] == "stream" }
    }

    private var adsNetworks: [Network] {
        networks.filter { providerCategories[$0.id] == "ads" }
    }

    private var rentOrBuyNetworks: [Network] {
        networks.filter { providerCategories[$0.id] == "rent" || providerCategories[$0.id] == "buy" }
    }

    var body: some View {
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if hasCategories {
                    providerSection("Stream", networks: streamNetworks)
                    providerSection("Free with Ads", networks: adsNetworks)
                    providerSection("Rent or Buy", networks: rentOrBuyNetworks)
                } else {
                    providerLogoRow(networks: networks)
                }
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ title: String, networks: [Network]) -> some View {
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                providerLogoRow(networks: networks)
            }
        }
    }

    private func providerLogoRow(networks: [Network]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(networks, id: \.id) { network in
                    providerLogo(for: network)
                        .onTapGesture {
                            tooltipNetworkID = tooltipNetworkID == network.id ? nil : network.id
                        }
                        .popover(isPresented: Binding(
                            get: { tooltipNetworkID == network.id },
                            set: { if !$0 { tooltipNetworkID = nil } }
                        )) {
                            Text(network.name)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .presentationCompactAdaptation(.popover)
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func providerLogo(for network: Network) -> some View {
        ProviderLogoView(network: network, size: logoSize)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, position) in arrange(in: bounds.width, subviews: subviews).positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

struct MetadataRow: View {
    let listItem: ListItem

    private var voteAverage: Double? {
        listItem.tvShow?.voteAverage ?? listItem.movie?.voteAverage
    }

    private var contentRating: String? {
        listItem.tvShow?.contentRating ?? listItem.movie?.contentRating
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            if let rating = contentRating, !rating.isEmpty {
                ContentRatingPill(text: rating)
            }
            if let tvShow = listItem.tvShow {
                if let summary = tvShow.seasonsEpisodesSummary {
                    MetadataPill(text: summary)
                }
                if let runtime = tvShow.episodeRunTime {
                    MetadataPill(text: "\(runtime) min/ep")
                }
                if let airDate = tvShow.nextEpisodeAirDate, let formatted = Self.formatAirDate(airDate) {
                    NextAirDatePill(text: formatted)
                }
            } else if let movie = listItem.movie {
                if let year = movie.releaseYear {
                    MetadataPill(text: year)
                }
                if let runtime = movie.runtime {
                    MetadataPill(text: "\(runtime) min")
                }
            }
            if let vote = voteAverage, vote > 0 {
                RatingPill(vote: vote)
            }
        }
    }
}

extension MetadataRow {
    private enum AirDateFormatter {
        static let input: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        static let display: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f
        }()
    }

    static func formatAirDate(_ dateString: String) -> String? {
        guard let date = AirDateFormatter.input.date(from: dateString) else { return nil }
        return "Next: \(AirDateFormatter.display.string(from: date))"
    }
}

struct NextAirDatePill: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ContentRatingPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(.white.opacity(0.1)), in: .rect(cornerRadius: 6))
    }
}

struct MetadataPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

struct RatingPill: View {
    let vote: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
            Text(String(format: "%.1f", vote))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}
