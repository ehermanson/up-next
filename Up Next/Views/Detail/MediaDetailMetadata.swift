import SwiftUI

struct DetailProviderRow: View {
    let networks: [Network]
    let providerCategories: [Int: String]
    @State private var tooltipNetworkID: Int?

    private let logoSize: CGFloat = 44

    private var hasCategories: Bool {
        !providerCategories.isEmpty
    }

    /// `networks` in a stable display order. `networks` comes from an unordered SwiftData
    /// relationship, so the per-category sections below filter this instead of `networks`
    /// directly — otherwise the logos would reshuffle on every render.
    private var sortedNetworks: [Network] {
        displayOrderedNetworks(networks, categories: providerCategories)
    }

    private var streamNetworks: [Network] {
        sortedNetworks.filter { providerCategories[$0.id] == "stream" }
    }

    private var adsNetworks: [Network] {
        sortedNetworks.filter { providerCategories[$0.id] == "ads" }
    }

    private var rentOrBuyNetworks: [Network] {
        sortedNetworks.filter { providerCategories[$0.id] == "rent" || providerCategories[$0.id] == "buy" }
    }

    var body: some View {
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if hasCategories {
                    providerSection("Stream", networks: streamNetworks)
                    providerSection("Free with Ads", networks: adsNetworks)
                    providerSection("Rent or Buy", networks: rentOrBuyNetworks)
                } else {
                    providerLogoRow(networks: sortedNetworks)
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
                    Button {
                        tooltipNetworkID = tooltipNetworkID == network.id ? nil : network.id
                    } label: {
                        providerLogo(for: network)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(network.name)
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
    @ObservedObject var listItem: ListItem

    private var voteAverage: Double? {
        listItem.tvShow?.voteAverage ?? listItem.movie?.voteAverage
    }

    private var contentRating: String? {
        listItem.tvShow?.contentRating ?? listItem.movie?.contentRating
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            if let rating = contentRating, !rating.isEmpty {
                Chip(text: rating)
            }
            if let tvShow = listItem.tvShow {
                if let summary = tvShow.seasonsEpisodesSummary {
                    Chip(text: summary)
                }
                if let runtime = tvShow.episodeRunTime {
                    Chip(text: "\(runtime) min/ep")
                }
                if let airDate = tvShow.nextEpisodeAirDate, let formatted = Self.nextEpisodeChipText(for: tvShow) {
                    Chip(icon: "calendar", iconColor: .blue, text: formatted)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.nextEpisodeAccessibilityLabel(for: tvShow, airDate: airDate))
                }
                // Only two statuses are worth a chip: a finished show, or one that's confirmed
                // to return but has no scheduled episode yet (the calendar chip covers the rest).
                if let status = tvShow.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !status.isEmpty {
                    if status == "Ended" || status == "Canceled" || status == "Cancelled" {
                        Chip(icon: "flag.checkered", text: status)
                    } else if status == "Returning Series", tvShow.nextEpisodeAirDate == nil {
                        Chip(icon: "clock", text: "Returning")
                    }
                }
            } else if let movie = listItem.movie {
                if let year = movie.releaseYear {
                    Chip(text: year)
                }
                if let runtime = movie.runtime {
                    Chip(text: "\(runtime) min")
                }
            }
            if let vote = voteAverage, vote > 0 {
                Chip(
                    icon: "star.fill",
                    iconColor: .yellow,
                    text: vote.formatted(.number.precision(.fractionLength(1)))
                )
            }
        }
    }
}

extension MetadataRow {
    /// "S3E2 · Jun 15" when TMDB gave us the episode pointer, otherwise "Next: Jun 15".
    static func nextEpisodeChipText(for tvShow: TVShow) -> String? {
        guard let airDate = tvShow.nextEpisodeAirDate,
              let day = AirDateFormat.shortLabel(from: airDate)
        else { return nil }
        guard let code = episodeCode(season: tvShow.nextEpisodeSeason, episode: tvShow.nextEpisodeNumber) else {
            return "Next: \(day)"
        }
        return "\(code) \u{00B7} \(day)"
    }

    /// Chips stay single-line, so the episode title (when it isn't a placeholder) is spoken
    /// rather than shown.
    static func nextEpisodeAccessibilityLabel(for tvShow: TVShow, airDate: String) -> String {
        var parts = ["Next episode"]
        if let season = tvShow.nextEpisodeSeason, let episode = tvShow.nextEpisodeNumber {
            parts.append("Season \(season) Episode \(episode)")
        }
        let name = tvShow.nextEpisodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, !isGenericEpisodeName(name) {
            parts.append(name)
        }
        if let day = AirDateFormat.shortLabel(from: airDate) {
            parts.append(day)
        }
        return parts.joined(separator: ", ")
    }
}

