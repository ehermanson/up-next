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

                            actionButtonRow

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
                    .offset(y: -50)
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

    // MARK: - Action Buttons

    private var actionButtonRow: some View {
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
    }

    // MARK: - Data Fetching

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

    // MARK: - Similar / Collection Actions

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

// MARK: - Shared Detail Components

struct HeaderImageView: View {
    let imageURL: URL?

    private let headerHeight: CGFloat = 420

    var body: some View {
        Group {
            if let imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: headerHeight)
                    case .success(let image):
                        GeometryReader { geo in
                            let minY = geo.frame(in: .scrollView).minY
                            let overscroll = max(minY, 0)
                            let scrollOffset = max(-minY, 0)
                            let yOffset = -scrollOffset * 0.3 - overscroll

                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(
                                    width: geo.size.width,
                                    height: headerHeight + overscroll,
                                    alignment: .top
                                )
                                .offset(y: yOffset)
                        }
                        .frame(height: headerHeight)
                        .overlay(alignment: .bottom) {
                            let bgColor = Color(red: 0.10, green: 0.06, blue: 0.22)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: bgColor.opacity(0.5), location: 0.25),
                                    .init(color: bgColor.opacity(0.85), location: 0.6),
                                    .init(color: bgColor, location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 500)
                            .offset(y: 200)
                        }
                    case .failure:
                        Color.gray.frame(height: headerHeight)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Color.gray.frame(height: headerHeight)
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

// MARK: - Preview

private enum MediaDetailViewPreviewData {
    static let user = UserIdentity(id: "preview-user", displayName: "Preview User")
    static let list = MediaList(name: "My Watchlist", createdBy: user, createdAt: Date.now)

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
            addedAt: Date.now,
            isWatched: true,
            watchedAt: Date.now,
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
            addedAt: Date.now,
            isWatched: true,
            watchedAt: Date.now,
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
