import CoreData
import SwiftUI

struct DetailProviderRow: View {
    let networks: [Network]
    let providerCategories: [Int: String]
    @State private var tooltipNetworkID: Int?
    /// Which row's "+N" popover is open (keyed by the row's caption).
    @State private var overflowRowID: String?

    private let logoSize: CGFloat = 44
    /// Logos shown inline per row before the rest fold into the "+N" tile.
    private static let inlineLimit = 5
    private let settings = ProviderSettings.shared

    private var hasCategories: Bool {
        !providerCategories.isEmpty
    }

    /// `networks` in a stable display order. `networks` comes from an unordered Core Data
    /// relationship, so the per-category groups below filter this instead of `networks`
    /// directly — otherwise the logos would reshuffle on every render.
    private var sortedNetworks: [Network] {
        displayOrderedNetworks(networks, categories: providerCategories)
    }

    private func networks(in categories: Set<String>) -> [Network] {
        sortedNetworks.filter { categories.contains(providerCategories[$0.id] ?? "") }
    }

    private var streamNetworks: [Network] { networks(in: ["stream"]) }
    private var adsNetworks: [Network] { networks(in: ["ads"]) }
    private var rentOrBuyNetworks: [Network] { networks(in: ["rent", "buy"]) }
    /// Originating channels (USA, Spike) — where the show aired, not where to watch it. Never
    /// inline next to real providers; they ride along in the Stream row's "+N" popover, and only
    /// get their own row when the title streams nowhere.
    private var originatingNetworks: [Network] { networks(in: ["network"]) }

    /// The user's own services among the subscription providers. When any match, the Stream row
    /// shows just those and folds everything else behind "+N" — the row is meant to answer
    /// "can I watch this?", not list every service on earth.
    private var pinnedNetworks: [Network] {
        guard settings.hasSelectedProviders else { return [] }
        let selected = settings.selectedProviderIDs
        return (streamNetworks + adsNetworks).filter { selected.contains($0.id) }
    }

    private struct FoldedGroup: Identifiable {
        let title: String
        let networks: [Network]
        var id: String { title }
    }

    private struct Row: Identifiable {
        /// Caption above the logos; empty for the uncategorised fallback.
        let id: String
        let inline: [Network]
        let folded: [FoldedGroup]

        var foldedCount: Int { folded.reduce(0) { $0 + $1.networks.count } }
    }

    private var rows: [Row] {
        guard hasCategories else { return [row("", sortedNetworks)] }
        var rows: [Row] = []
        let pinned = pinnedNetworks
        if !pinned.isEmpty {
            let pinnedIDs = Set(pinned.map(\.id))
            var folded: [FoldedGroup] = []
            let otherStream = streamNetworks.filter { !pinnedIDs.contains($0.id) }
            let otherAds = adsNetworks.filter { !pinnedIDs.contains($0.id) }
            if !otherStream.isEmpty { folded.append(FoldedGroup(title: "Stream", networks: otherStream)) }
            if !otherAds.isEmpty { folded.append(FoldedGroup(title: "Free with Ads", networks: otherAds)) }
            if !originatingNetworks.isEmpty { folded.append(FoldedGroup(title: "Network", networks: originatingNetworks)) }
            rows.append(Row(id: "Stream", inline: pinned, folded: folded))
        } else {
            let network = FoldedGroup(title: "Network", networks: originatingNetworks)
            if !streamNetworks.isEmpty {
                rows.append(row("Stream", streamNetworks, extra: network))
                if !adsNetworks.isEmpty { rows.append(row("Free with Ads", adsNetworks)) }
            } else if !adsNetworks.isEmpty {
                rows.append(row("Free with Ads", adsNetworks, extra: network))
            } else if !originatingNetworks.isEmpty {
                rows.append(row("Network", originatingNetworks))
            }
        }
        if !rentOrBuyNetworks.isEmpty { rows.append(row("Rent or Buy", rentOrBuyNetworks)) }
        return rows
    }

    private func row(_ caption: String, _ networks: [Network], extra: FoldedGroup? = nil) -> Row {
        var folded: [FoldedGroup] = []
        let rest = Array(networks.dropFirst(Self.inlineLimit))
        if !rest.isEmpty { folded.append(FoldedGroup(title: caption, networks: rest)) }
        if let extra, !extra.networks.isEmpty { folded.append(extra) }
        return Row(id: caption, inline: Array(networks.prefix(Self.inlineLimit)), folded: folded)
    }

    /// "Stream" only means something next to "Free with Ads" / "Rent or Buy" — a lone Netflix
    /// logo already says it's on Netflix. Those two keep their caption even alone; *that* is the
    /// information (it's free / it costs money).
    private func showsCaption(for row: Row, in rows: [Row]) -> Bool {
        guard !row.id.isEmpty else { return false }
        if row.id == "Stream", rows.count == 1 { return false }
        return true
    }

    var body: some View {
        if !networks.isEmpty {
            let rows = rows
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        if showsCaption(for: row, in: rows) {
                            Text(row.id)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                        providerLogoRow(row)
                    }
                }
            }
        }
    }

    private func providerLogoRow(_ row: Row) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(row.inline, id: \.id) { network in
                    Button {
                        tooltipNetworkID = tooltipNetworkID == network.id ? nil : network.id
                    } label: {
                        ProviderLogoView(network: network, size: logoSize)
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

                if row.foldedCount > 0 {
                    Button {
                        overflowRowID = overflowRowID == row.id ? nil : row.id
                    } label: {
                        Text("+\(row.foldedCount)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                            .frame(width: logoSize, height: logoSize)
                            .cellSurface(cornerRadius: logoSize * 0.22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.foldedCount) more")
                    .popover(isPresented: Binding(
                        get: { overflowRowID == row.id },
                        set: { if !$0 { overflowRowID = nil } }
                    )) {
                        FoldedProvidersList(groups: row.folded)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// The "+N" popover: every folded provider with its name, grouped by how it's available.
    private struct FoldedProvidersList: View {
        let groups: [FoldedGroup]

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        ForEach(group.networks, id: \.id) { network in
                            HStack(spacing: 10) {
                                ProviderLogoView(network: network, size: 28)
                                Text(network.name)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 200, alignment: .leading)
        }
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
                Chip(icon: "calendar", iconColor: Color.accentColor, text: nextEpisodeText)
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
        // `attribution(for:)` is a main-actor CloudKit record read, so it only runs for a real
        // library row and at utility priority — the sheet's first render never waits on it.
        .task(id: listItem.objectID, priority: .utility) {
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

