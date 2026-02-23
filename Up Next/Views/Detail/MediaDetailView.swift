import SwiftData
import SwiftUI

struct MediaDetailView: View {
    @Binding var listItem: ListItem
    let dismiss: () -> Void
    let onRemove: () -> Void
    var onSeasonCountChanged: ((ListItem, Int?) -> Void)?
    var customListViewModel: CustomListViewModel?
    var onAdd: (() -> Void)?
    var existingIDs: Set<String> = []
    var onTVShowAdded: ((TVShow) -> Void)?
    var onMovieAdded: ((Movie) -> Void)?

    @Environment(ToastState.self) private var toast

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false
    @State private var showingTMDBPage = false
    @State private var showingAddToList = false
    @State private var similarItems: [SimilarMediaItem] = []
    @State private var recommendedItems: [SimilarMediaItem] = []
    @State private var trailerKey: String?
    @State private var showingTrailer = false
    @State private var selectedSimilarItem: ListItem?
    @State private var addedSimilarIDs: Set<String> = []
    @State private var collectionName: String?
    @State private var collectionParts: [TMDBCollectionPart] = []

    private let service = TMDBService.shared

    private var tmdbURL: URL? {
        guard let media = listItem.media else { return nil }
        let type = listItem.tvShow != nil ? "tv" : "movie"
        return URL(string: "https://www.themoviedb.org/\(type)/\(media.id)")
    }

    private var allNetworks: [Network] {
        listItem.media?.networks ?? []
    }

    private var needsFullDetails: Bool {
        guard let media = listItem.media, Int(media.id) != nil else { return false }

        if let tvShow = listItem.tvShow {
            if tvShow.numberOfSeasons == nil { return true }
            if tvShow.cast.isEmpty { return true }
            if tvShow.genres.isEmpty { return true }
            if tvShow.providerCategories.isEmpty { return true }
            return false
        }

        if let movie = listItem.movie {
            if movie.runtime == nil { return true }
            if movie.cast.isEmpty { return true }
            if movie.genres.isEmpty { return true }
            if movie.releaseDate == nil || movie.releaseDate?.isEmpty == true { return true }
            if movie.providerCategories.isEmpty { return true }
            return false
        }

        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HeaderImageView(imageURL: listItem.media?.thumbnailURL)

                    GlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(listItem.media?.title ?? "")
                                .font(.title)
                                .fontWeight(.bold)

                            MetadataRow(listItem: listItem)

                            GenreSection(genres: listItem.media?.genres ?? [])

                            DetailProviderRow(
                                networks: allNetworks,
                                providerCategories: listItem.media?.providerCategories ?? [:]
                            )

                            Divider().padding(.vertical, 4)

                            DescriptionSection(
                                isLoading: isLoadingDetails,
                                descriptionText: listItem.media?.descriptionText,
                                errorMessage: detailError)

                            Divider().padding(.vertical, 4)

                            CastSection(
                                cast: listItem.media?.cast ?? [],
                                castImagePaths: listItem.media?.castImagePaths ?? [],
                                castCharacters: listItem.media?.castCharacters ?? []
                            )

                            if onAdd == nil {
                                if listItem.tvShow != nil, let total = listItem.tvShow?.numberOfSeasons, total > 1 {
                                    Divider().padding(.vertical, 4)
                                    SeasonChecklistCard(listItem: $listItem)

                                    Divider().padding(.vertical, 4)
                                    DoneWatchingCard(listItem: $listItem)
                                }

                                let hasSeasonChecklist = listItem.tvShow != nil && (listItem.tvShow?.numberOfSeasons ?? 0) > 1
                                if !listItem.isDropped && !hasSeasonChecklist {
                                    Divider().padding(.vertical, 4)

                                    WatchedToggleCard(listItem: $listItem)
                                }

                                if listItem.isWatched {
                                    Divider().padding(.vertical, 4)

                                    UserRatingCard(listItem: $listItem)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }

                            Divider().padding(.vertical, 4)

                            HStack(spacing: 10) {
                                if let customListVM = customListViewModel, !customListVM.customLists.isEmpty {
                                    Button { showingAddToList = true } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "tray.full")
                                                .font(.body)
                                            Text("Lists")
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .sheet(isPresented: $showingAddToList) {
                                        AddToListSheet(
                                            viewModel: customListVM,
                                            movie: listItem.movie,
                                            tvShow: listItem.tvShow
                                        )
                                    }
                                }

                                if trailerKey != nil {
                                    Button { showingTrailer = true } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "play.fill")
                                                .font(.body)
                                            Text("Trailer")
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .sheet(isPresented: $showingTrailer) {
                                        if let url = URL(string: "https://www.youtube.com/watch?v=\(trailerKey ?? "")") {
                                            SafariView(url: url)
                                                .ignoresSafeArea()
                                        }
                                    }
                                }

                                if let tmdbURL {
                                    Button { showingTMDBPage = true } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "film")
                                                .font(.body)
                                            Text("TMDB")
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .sheet(isPresented: $showingTMDBPage) {
                                        SafariView(url: tmdbURL)
                                            .ignoresSafeArea()
                                    }
                                }
                            }

                            CollectionSection(
                                collectionName: collectionName,
                                parts: collectionParts,
                                currentMovieID: listItem.movie.map { Int($0.id) ?? 0 },
                                existingIDs: existingIDs.union(addedSimilarIDs),
                                onAdd: onTVShowAdded != nil || onMovieAdded != nil ? { addCollectionItem($0) } : nil,
                                onTap: { openCollectionDetail($0) }
                            )

                            SimilarSection(
                                title: "Similar",
                                items: similarItems,
                                existingIDs: existingIDs.union(addedSimilarIDs),
                                onAdd: onTVShowAdded != nil || onMovieAdded != nil ? { addSimilarItem($0) } : nil,
                                onTap: { openSimilarDetail($0) }
                            )
                            SimilarSection(
                                title: "Recommended",
                                items: recommendedItems,
                                existingIDs: existingIDs.union(addedSimilarIDs),
                                onAdd: onTVShowAdded != nil || onMovieAdded != nil ? { addSimilarItem($0) } : nil,
                                onTap: { openSimilarDetail($0) }
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    }
                    .padding(.horizontal, 12)
                    .offset(y: -40)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(AppBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let onAdd {
                        Button {
                            onAdd()
                            if let title = listItem.media?.title {
                                toast.show("\(title) has been added")
                            }
                            dismiss()
                        } label: {
                            Label("Add to Watchlist", systemImage: "plus")
                        }
                    } else {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .accessibilityLabel("Remove from list")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("Done")
                    }
                }
            }
            .task {
                await fetchFullDetails()
            }
            .alert("Remove from list?", isPresented: $isConfirmingRemoval) {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete this title from your watch list.")
            }
            .sheet(item: $selectedSimilarItem) { item in
                MediaDetailView(
                    listItem: similarDetailBinding(for: item),
                    dismiss: { selectedSimilarItem = nil },
                    onRemove: { selectedSimilarItem = nil },
                    onAdd: { addSimilarFromDetail(item) },
                    existingIDs: existingIDs.union(addedSimilarIDs),
                    onTVShowAdded: onTVShowAdded,
                    onMovieAdded: onMovieAdded
                )
            }
            .toastOverlay()
        }
    }

    private static func bestTrailerKey(from videos: TMDBVideosResponse?) -> String? {
        guard let results = videos?.results else { return nil }
        let youtubeVideos = results.filter { $0.site == "YouTube" }
        if let trailer = youtubeVideos.first(where: { $0.type == "Trailer" }) { return trailer.key }
        if let teaser = youtubeVideos.first(where: { $0.type == "Teaser" }) { return teaser.key }
        return youtubeVideos.first?.key
    }

    @MainActor
    private func fetchFullDetails() async {
        guard let media = listItem.media,
            let id = Int(media.id)
        else { return }

        let showLoading = needsFullDetails
        if showLoading {
            isLoadingDetails = true
            detailError = nil
        }

        do {
            if let tvShow = listItem.tvShow {
                let previousSeasonCount = tvShow.numberOfSeasons
                let detail = try await service.getTVShowDetails(id: id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow.update(from: await service.mapToTVShow(detail, providers: providers))

                if let newCount = tvShow.numberOfSeasons,
                   previousSeasonCount != nil,
                   newCount > (previousSeasonCount ?? 0) {
                    onSeasonCountChanged?(listItem, previousSeasonCount)
                }

                similarItems = (detail.similar?.results ?? []).prefix(10).map {
                    SimilarMediaItem(id: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
                }
                recommendedItems = (detail.recommendations?.results ?? []).prefix(10).map {
                    SimilarMediaItem(id: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
                }
                trailerKey = Self.bestTrailerKey(from: detail.videos)
            } else if let movie = listItem.movie {
                let detail = try await service.getMovieDetails(id: id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie.update(from: await service.mapToMovie(detail, providers: providers))

                similarItems = (detail.similar?.results ?? []).prefix(10).map {
                    SimilarMediaItem(id: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
                }
                recommendedItems = (detail.recommendations?.results ?? []).prefix(10).map {
                    SimilarMediaItem(id: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
                }
                trailerKey = Self.bestTrailerKey(from: detail.videos)

                if let collection = detail.belongsToCollection {
                    collectionName = collection.name
                    do {
                        let collectionDetail = try await service.getCollectionDetails(id: collection.id)
                        collectionParts = collectionDetail.parts.sorted {
                            ($0.releaseDate ?? "") < ($1.releaseDate ?? "")
                        }
                    } catch {
                        collectionParts = []
                    }
                }
            }
        } catch {
            if showLoading {
                detailError = error.localizedDescription
            }
        }

        isLoadingDetails = false
    }

    private func addSimilarItem(_ item: SimilarMediaItem) {
        let stringID = String(item.id)
        guard !existingIDs.contains(stringID), !addedSimilarIDs.contains(stringID) else { return }
        addedSimilarIDs.insert(stringID)
        toast.show("\(item.title) has been added")

        Task {
            if item.mediaType == .tvShow {
                let tvShow: TVShow
                do {
                    let d = try await service.getTVShowDetails(id: item.id)
                    let p = d.watchProviders?.results?[service.currentRegion]
                    tvShow = await service.mapToTVShow(d, providers: p)
                } catch {
                    tvShow = TVShow(id: stringID, title: item.title, thumbnailURL: service.imageURL(path: item.posterPath), voteAverage: item.voteAverage)
                }
                onTVShowAdded?(tvShow)
            } else {
                let movie: Movie
                do {
                    let d = try await service.getMovieDetails(id: item.id)
                    let p = d.watchProviders?.results?[service.currentRegion]
                    movie = await service.mapToMovie(d, providers: p)
                } catch {
                    movie = Movie(id: stringID, title: item.title, thumbnailURL: service.imageURL(path: item.posterPath), voteAverage: item.voteAverage)
                }
                onMovieAdded?(movie)
            }
        }
    }

    private func openSimilarDetail(_ item: SimilarMediaItem) {
        let posterURL = service.imageURL(path: item.posterPath)
        if item.mediaType == .tvShow {
            let tvShow = TVShow(id: String(item.id), title: item.title, thumbnailURL: posterURL, voteAverage: item.voteAverage)
            selectedSimilarItem = ListItem(tvShow: tvShow)
        } else {
            let movie = Movie(id: String(item.id), title: item.title, thumbnailURL: posterURL, voteAverage: item.voteAverage)
            selectedSimilarItem = ListItem(movie: movie)
        }
    }

    private func addCollectionItem(_ part: TMDBCollectionPart) {
        let stringID = String(part.id)
        guard !existingIDs.contains(stringID), !addedSimilarIDs.contains(stringID) else { return }
        addedSimilarIDs.insert(stringID)
        toast.show("\(part.title) has been added")

        Task {
            let movie: Movie
            do {
                let d = try await service.getMovieDetails(id: part.id)
                let p = d.watchProviders?.results?[service.currentRegion]
                movie = await service.mapToMovie(d, providers: p)
            } catch {
                movie = Movie(id: stringID, title: part.title, thumbnailURL: service.imageURL(path: part.posterPath), voteAverage: part.voteAverage)
            }
            onMovieAdded?(movie)
        }
    }

    private func openCollectionDetail(_ part: TMDBCollectionPart) {
        let posterURL = service.imageURL(path: part.posterPath)
        let movie = Movie(id: String(part.id), title: part.title, thumbnailURL: posterURL, voteAverage: part.voteAverage)
        selectedSimilarItem = ListItem(movie: movie)
    }

    private func addSimilarFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let stringID = media.id
        guard !existingIDs.contains(stringID), !addedSimilarIDs.contains(stringID) else { return }
        addedSimilarIDs.insert(stringID)
        toast.show("\(media.title) has been added")
        if let tvShow = item.tvShow {
            onTVShowAdded?(tvShow)
        } else if let movie = item.movie {
            onMovieAdded?(movie)
        }
    }

    private func similarDetailBinding(for item: ListItem) -> Binding<ListItem> {
        Binding(
            get: { selectedSimilarItem ?? item },
            set: { selectedSimilarItem = $0 }
        )
    }

}

private struct DetailProviderRow: View {
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

private struct FlowLayout: Layout {
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

private struct MetadataRow: View {
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

private struct NextAirDatePill: View {
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

private struct ContentRatingPill: View {
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

private struct RatingPill: View {
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

private struct WatchedToggleCard: View {
    @Binding var listItem: ListItem

    private var seasonSubtitle: String? {
        guard let tvShow = listItem.tvShow,
              let total = tvShow.numberOfSeasons, total > 0
        else { return nil }
        let count = listItem.watchedSeasons.count
        if listItem.isWatched {
            return "Watched"
        } else if count > 0 {
            return "\(count) of \(total) seasons"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listItem.isWatched ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(listItem.isWatched ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mark as Watched")
                    .font(.headline)
                if let subtitle = seasonSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if listItem.isWatched {
                    Text("Watched")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { listItem.isWatched },
                set: { newValue in
                    listItem.droppedAt = nil
                    if let tvShow = listItem.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                        if newValue {
                            listItem.watchedSeasons = Array(1...total)
                        } else {
                            listItem.watchedSeasons = []
                        }
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date() : nil
                    } else {
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date() : nil
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .glassEffect(.regular.tint(listItem.isWatched ? .green.opacity(0.1) : .clear), in: .rect(cornerRadius: 20))
    }
}

private struct UserRatingCard: View {
    @Binding var listItem: ListItem

    private func isSelected(_ value: Int) -> Bool {
        listItem.userRating == value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Rating")
                .font(.headline)

            HStack(spacing: 12) {
                ratingButton(value: -1, icon: "hand.thumbsdown.fill", tint: .red)
                ratingButton(value: 0, icon: "minus.circle.fill", tint: .gray)
                ratingButton(value: 1, icon: "hand.thumbsup.fill", tint: .green)
            }

            TextField("Add notes...", text: Binding(
                get: { listItem.userNotes ?? "" },
                set: { listItem.userNotes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .padding(12)
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: .rect(cornerRadius: 14))
        }
    }

    private func ratingButton(value: Int, icon: String, tint: Color) -> some View {
        let selected = isSelected(value)
        return Button {
            listItem.userRating = selected ? nil : value
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(selected ? tint : .secondary.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular.tint(selected ? tint.opacity(0.2) : .clear),
                    in: .rect(cornerRadius: 16)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SeasonChecklistCard: View {
    @Binding var listItem: ListItem

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var episodeCounts: [Int] {
        listItem.tvShow?.seasonEpisodeCounts ?? []
    }

    private var seasonDescriptions: [String] {
        listItem.tvShow?.seasonDescriptions ?? []
    }

    @State private var expandedSeasons: Set<Int> = []

    private let circleSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(1...max(totalSeasons, 1), id: \.self) { season in
                    seasonRow(season: season)
                }
            }
        }
    }

    private func toggleSeason(_ season: Int) {
        if listItem.watchedSeasons.contains(season) {
            listItem.watchedSeasons.removeAll { $0 == season }
        } else {
            listItem.watchedSeasons.append(season)
        }
        // If all seasons are now watched while dropped, clear the drop (legitimately complete)
        if listItem.isDropped, let total = listItem.tvShow?.numberOfSeasons, total > 0 {
            let allWatched = (1...total).allSatisfy { listItem.watchedSeasons.contains($0) }
            if allWatched { listItem.droppedAt = nil }
        }
        listItem.syncWatchedStateFromSeasons()
    }

    private func seasonRow(season: Int) -> some View {
        let isWatched = listItem.watchedSeasons.contains(season)
        let episodeCount = season <= episodeCounts.count ? episodeCounts[season - 1] : nil
        let description = season <= seasonDescriptions.count ? seasonDescriptions[season - 1] : nil
        let isLast = season == totalSeasons
        let isExpanded = expandedSeasons.contains(season)

        return HStack(alignment: .top, spacing: 12) {
            // Timeline: circle + connector line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(isWatched ? Color.green.opacity(0.15) : Color.white.opacity(0.05))
                    Circle()
                        .strokeBorder(isWatched ? Color.green.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1.5)
                    if isWatched {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }
                }
                .frame(width: circleSize, height: circleSize)

                if !isLast {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isWatched ? Color.green.opacity(0.3) : Color.white.opacity(0.06))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: circleSize)

            // Season info
            VStack(alignment: .leading, spacing: 2) {
                Text("Season \(season)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let count = episodeCount, count > 0 {
                    Text("\(count) episode\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(isExpanded ? nil : 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedSeasons.remove(season)
                                } else {
                                    expandedSeasons.insert(season)
                                }
                            }
                        }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(.bottom, isLast ? 0 : 12)
        .contentShape(Rectangle())
        .onTapGesture { toggleSeason(season) }
    }
}

private struct DoneWatchingCard: View {
    @Binding var listItem: ListItem

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var allSeasonsWatched: Bool {
        guard totalSeasons > 0 else { return false }
        return (1...totalSeasons).allSatisfy { listItem.watchedSeasons.contains($0) }
    }

    /// Show card when: not all seasons watched (partial/none), OR already dropped
    private var shouldShow: Bool {
        listItem.isDropped || !allSeasonsWatched
    }

    var body: some View {
        if shouldShow {
            if listItem.isDropped {
                Button {
                    listItem.resumeShow()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pick Back Up")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Move back to your watchlist")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            } else {
                Button {
                    listItem.dropShow()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Drop Show")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Move to your watched list")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }
}

struct HeaderImageView: View {
    let imageURL: URL?

    var body: some View {
        Group {
            if let imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 350)
                    case .success(let image):
                        ZStack(alignment: .bottom) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 350)
                                .clipped()

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.black.opacity(0.3), location: 0.4),
                                    .init(color: Color.black.opacity(0.8), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    case .failure:
                        Color.gray.frame(height: 350)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Color.gray.frame(height: 350)
            }
        }
    }
}

struct DescriptionSection: View {
    let isLoading: Bool
    let descriptionText: String?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading details...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let descriptionText, !descriptionText.isEmpty {
                Text(descriptionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GenreSection: View {
    let genres: [String]

    var body: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct CastSection: View {
    let cast: [String]
    let castImagePaths: [String]
    let castCharacters: [String]

    private let imageSize: CGFloat = 64
    private let itemWidth: CGFloat = 80

    var body: some View {
        if cast.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(cast.prefix(10).enumerated()), id: \.offset) { index, member in
                            castItem(index: index, name: member)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func castItem(index: Int, name: String) -> some View {
        VStack(spacing: 6) {
            castImage(index: index)
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())

            Text(name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            let character = index < castCharacters.count ? castCharacters[index] : ""
            if !character.isEmpty {
                Text(character)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: itemWidth)
    }

    @ViewBuilder
    private func castImage(index: Int) -> some View {
        let path = index < castImagePaths.count ? castImagePaths[index] : ""
        if let url = TMDBService.shared.imageURL(path: path.isEmpty ? nil : path, size: .w185) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    castPlaceholder
                }
            }
        } else {
            castPlaceholder
        }
    }

    private var castPlaceholder: some View {
        Image(systemName: "person.fill")
            .font(.title2)
            .foregroundStyle(.tertiary)
            .frame(width: imageSize, height: imageSize)
            .glassEffect(.regular, in: .circle)
    }
}

// MARK: - Collection

private struct CollectionSection: View {
    let collectionName: String?
    let parts: [TMDBCollectionPart]
    var currentMovieID: Int?
    var existingIDs: Set<String> = []
    var onAdd: ((TMDBCollectionPart) -> Void)?
    var onTap: ((TMDBCollectionPart) -> Void)?

    private let cardWidth: CGFloat = 120
    private let posterHeight: CGFloat = 170

    var body: some View {
        if let name = collectionName, !parts.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(parts) { part in
                            collectionCard(for: part)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isCurrent(_ part: TMDBCollectionPart) -> Bool {
        part.id == currentMovieID
    }

    private func isAdded(_ part: TMDBCollectionPart) -> Bool {
        existingIDs.contains(String(part.id))
    }

    private func collectionCard(for part: TMDBCollectionPart) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                posterImage(path: part.posterPath)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        if isCurrent(part) {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isCurrent(part) { onTap?(part) }
                    }

                if let onAdd, !isCurrent(part) {
                    let added = isAdded(part)
                    Button {
                        if !added { onAdd(part) }
                    } label: {
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(added ? .green : .white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(part.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isCurrent(part) ? .primary : .primary)
                .onTapGesture {
                    if !isCurrent(part) { onTap?(part) }
                }

            if let year = part.releaseYear {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func posterImage(path: String?) -> some View {
        if let url = TMDBService.shared.imageURL(path: path, size: .w342) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Similar / Recommended

struct SimilarMediaItem: Identifiable {
    let id: Int
    let title: String
    let posterPath: String?
    let voteAverage: Double?
    let mediaType: MediaType
}

private struct SimilarSection: View {
    let title: String
    let items: [SimilarMediaItem]
    var existingIDs: Set<String> = []
    var onAdd: ((SimilarMediaItem) -> Void)?
    var onTap: ((SimilarMediaItem) -> Void)?

    private let cardWidth: CGFloat = 120
    private let posterHeight: CGFloat = 170

    var body: some View {
        if !items.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            similarCard(for: item)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isAdded(_ item: SimilarMediaItem) -> Bool {
        existingIDs.contains(String(item.id))
    }

    private func similarCard(for item: SimilarMediaItem) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                posterImage(path: item.posterPath)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(.rect(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?(item) }

                if let onAdd {
                    let added = isAdded(item)
                    Button {
                        if !added { onAdd(item) }
                    } label: {
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(added ? .green : .white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .onTapGesture { onTap?(item) }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func posterImage(path: String?) -> some View {
        if let url = TMDBService.shared.imageURL(path: path, size: .w342) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Preview

private enum MediaDetailViewPreviewData {
    static let user = UserIdentity(id: "preview-user", displayName: "Preview User")
    static let list = MediaList(name: "My Watchlist", createdBy: user, createdAt: Date())

    static let netflix = Network(
        id: 8,
        name: "Netflix",
        logoPath: "/pbpMk2JmcoNnQwx5JGpXngfoWtp.png",
        originCountry: "US"
    )

    static let hboMax = Network(
        id: 1899,
        name: "HBO Max",
        logoPath: "/6Q3ZYUNA9Hsgj6iWnVsw2gR5V77.png",
        originCountry: "US"
    )

    static func movieItem() -> ListItem {
        let movie = Movie(
            id: "603692",
            title: "John Wick: Chapter 4",
            thumbnailURL: URL(
                string: "https://image.tmdb.org/t/p/w500/vZloFAK7NmvMGKE7VkF5UHaz0I.jpg"),
            networks: [netflix],
            descriptionText:
                "With the price on his head ever increasing, John Wick uncovers a path to defeating the High Table.",
            cast: ["Keanu Reeves", "Donnie Yen", "Bill Skarsgard", "Ian McShane"],
            providerCategories: [8: "stream"],
            releaseDate: "2023-03-24",
            runtime: 169
        )

        return ListItem(
            movie: movie,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: true,
            watchedAt: Date(),
            order: 0,
            userRating: 1,
            userNotes: "Incredible action sequences. Best one in the series."
        )
    }

    static func tvShowItem() -> ListItem {
        let show = TVShow(
            id: "1399",
            title: "Game of Thrones",
            thumbnailURL: URL(
                string: "https://image.tmdb.org/t/p/w500/u3bZgnGQ9T01sWNhyveQz0wH0Hl.jpg"),
            networks: [hboMax],
            descriptionText:
                "Nine noble families wage war against each other to gain control over the mythical land of Westeros.",
            cast: ["Emilia Clarke", "Kit Harington", "Peter Dinklage", "Lena Headey"],
            providerCategories: [1899: "stream"],
            numberOfSeasons: 8,
            numberOfEpisodes: 73
        )

        return ListItem(
            tvShow: show,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: true,
            watchedAt: Date(),
            order: 1,
            userRating: 0,
            userNotes: "Great first 4 seasons, fell off hard at the end."
        )
    }
}

private struct MediaDetailPreviewContainer: View {
    @State var listItem: ListItem

    var body: some View {
        MediaDetailView(
            listItem: $listItem,
            dismiss: {},
            onRemove: {}
        )
    }
}

#Preview("Movie") {
    MediaDetailPreviewContainer(listItem: MediaDetailViewPreviewData.movieItem())
}

#Preview("TV Show") {
    MediaDetailPreviewContainer(listItem: MediaDetailViewPreviewData.tvShowItem())
}
