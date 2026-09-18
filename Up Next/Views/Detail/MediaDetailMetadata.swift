import CoreData
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
    /// Copy values at the call site: search uses unattached Core Data objects, whose mutations
    /// don't reliably invalidate a child view observing the same object reference.
    let contentRating: String?
    let seasonsEpisodesSummary: String?
    let runtime: String?
    let releaseYear: String?
    let nextEpisodeText: String?
    let nextEpisodeAccessibilityText: String?
    let status: String?
    let voteAverage: Double?

    init(media: NSManagedObject) {
        if let tvShow = media as? TVShow {
            contentRating = tvShow.contentRating
            seasonsEpisodesSummary = tvShow.seasonsEpisodesSummary
            runtime = tvShow.episodeRunTime.map { "\($0) min/ep" }
            releaseYear = nil
            nextEpisodeText = Self.nextEpisodeChipText(for: tvShow)
            nextEpisodeAccessibilityText = tvShow.nextEpisodeAirDate.map {
                Self.nextEpisodeAccessibilityLabel(for: tvShow, airDate: $0)
            }
            let showStatus = tvShow.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            if showStatus == "Ended" || showStatus == "Canceled" || showStatus == "Cancelled" {
                status = showStatus
            } else if showStatus == "Returning Series", tvShow.nextEpisodeAirDate == nil {
                status = "Returning"
            } else {
                status = nil
            }
            voteAverage = tvShow.voteAverage
        } else {
            let movie = media as? Movie
            contentRating = movie?.contentRating
            seasonsEpisodesSummary = nil
            runtime = movie?.runtime.map { "\($0) min" }
            releaseYear = movie?.releaseYear
            nextEpisodeText = nil
            nextEpisodeAccessibilityText = nil
            status = nil
            voteAverage = movie?.voteAverage
        }
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            if let rating = contentRating, !rating.isEmpty {
                Chip(text: rating)
            }
            if let summary = seasonsEpisodesSummary {
                Chip(text: summary)
            }
            if let releaseYear {
                Chip(text: releaseYear)
            }
            if let runtime {
                Chip(text: runtime)
            }
            if let nextEpisodeText {
                Chip(icon: "calendar", iconColor: .blue, text: nextEpisodeText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(nextEpisodeAccessibilityText ?? nextEpisodeText)
            }
            if let status {
                Chip(icon: status == "Returning" ? "clock" : "flag.checkered", text: status)
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

/// "Added by Sarah · Sep 12" (or "Added by you · Sep 12") under the provider row — read-only
/// CloudKit record metadata (`PersistenceController.attribution(for:)`), no Core Data attribute.
/// Only for a real library row (`listItem.list != nil`; Discover/collection sheets bind a
/// transient wrapper) and only once a share is actually live, else nothing renders. `record(for:)`
/// is slow-ish, so it's fetched once in `.task` rather than on every render.
struct AddedByCaption: View {
    @ObservedObject var listItem: ListItem

    @State private var attribution: (name: String, date: Date?)?

    var body: some View {
        Group {
            if listItem.list != nil, let attribution {
                Label(caption(for: attribution), systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: listItem.objectID) {
            guard listItem.list != nil else { return }
            attribution = PersistenceController.shared.attribution(for: listItem)
        }
    }

    private func caption(for attribution: (name: String, date: Date?)) -> String {
        guard let date = attribution.date else { return "Added by \(attribution.name)" }
        return "Added by \(attribution.name) \u{00B7} \(formattedDate(date))"
    }

    private func formattedDate(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
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

