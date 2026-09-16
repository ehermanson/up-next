import SwiftData
import SwiftUI

struct MediaDetailView: View {
    @Binding var listItem: ListItem
    let dismiss: () -> Void
    let onRemove: () -> Void
    var onSeasonCountChanged: ((ListItem, Int?) -> Void)?
    var customListViewModel: CustomListViewModel?
    var onAdd: (() -> Void)?
    /// Type-namespaced IDs of titles already in the library (see `MediaIDKey`).
    var existingIDs: Set<String> = []
    var onTVShowAdded: ((TVShow) -> Void)?
    var onMovieAdded: ((Movie) -> Void)?
    /// Where `onTVShowAdded`/`onMovieAdded` put things when it isn't the watchlist — a collection
    /// name. Drives the Add button label and the "added" toasts.
    var addTargetName: String? = nil
    /// Set when the sheet is opened from a collection. Collections keep their own watched state, so
    /// this replaces the watchlist cards (seasons, watched toggle, rating) with a single card that
    /// only flips the collection entry — nothing in the Movies / TV Shows tabs changes.
    var collectionWatched: Binding<Bool>?
    /// Name of the collection the sheet was opened from, for the card's title.
    var collectionName: String?
    /// Copy for the leading destructive button and its confirmation. Defaults to the watchlist's
    /// "delete this title" wording; collections override it with collection-scoped wording.
    var removeLabel: String?
    var removeMessage: String?
    /// True when the view is pinned in a `NavigationSplitView` detail column (regular width)
    /// rather than presented as a sheet. There's nothing to dismiss, so "Done" is hidden;
    /// `dismiss` still runs after add/remove so the presenter can clear its selection.
    var presentedInColumn: Bool = false

    @Environment(ToastState.self) private var toast

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false
    @State private var showingTMDBPage = false
    @State private var showingAddToList = false
    /// TMDB's recommendations and similar-titles feeds merged into one ranked, deduped list —
    /// see `mergedMoreLikeThis`.
    @State private var moreLikeThisItems: [SimilarMediaItem] = []
    @State private var trailerKey: String?
    @State private var showingTrailer = false
    @State private var selectedSimilarItem: ListItem?
    @State private var addedSimilarIDs: Set<String> = []
    /// TMDB's movie collection (e.g. "The Dark Knight Collection") — unrelated to the user's
    /// Collections tab; named apart from the `collectionName` input above.
    @State private var tmdbCollectionName: String?
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

    private var backdropPath: String? {
        listItem.tvShow?.backdropPath ?? listItem.movie?.backdropPath
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
                    HeaderImageView(
                        backdropPath: backdropPath,
                        posterURL: listItem.media?.thumbnailURL,
                        title: listItem.media?.title ?? ""
                    )

                    VStack(alignment: .leading, spacing: 14) {
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

                        if let collectionWatched {
                            Divider().padding(.vertical, 4)

                            CollectionWatchedCard(
                                collectionName: collectionName,
                                isWatched: collectionWatched
                            )
                        } else if onAdd == nil {
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
                            collectionName: tmdbCollectionName,
                            parts: collectionParts,
                            currentMovieID: listItem.movie.map { Int($0.id) ?? 0 },
                            existingIDs: existingIDs.union(addedSimilarIDs),
                            onAdd: canAddToLibrary ? { addCollectionItem($0) } : nil,
                            onTap: { openCollectionDetail($0) }
                        )

                        SimilarSection(
                            title: "More Like This",
                            items: moreLikeThisItems,
                            existingIDs: existingIDs.union(addedSimilarIDs),
                            onAdd: canAddToLibrary ? { addSimilarItem($0) } : nil,
                            onTap: { openSimilarDetail($0) }
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    // Keeps the text column readable when the view is wider than a phone — an
                    // iPad form sheet or a pinned split-view detail column. Never reached on iPhone.
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(AppBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            // Pinned in a detail column there's nothing left for the bar to hold — Done is
            // meaningless and Add/Remove move into `actionButtonRow`. Dropping the bar entirely
            // lets the column line up with the sidebar's large title instead of floating a lone
            // glass button over the backdrop.
            .toolbar(presentedInColumn ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !presentedInColumn {
                    ToolbarItem(placement: .topBarLeading) {
                        if let onAdd {
                            Button {
                                onAdd()
                                if let title = listItem.media?.title {
                                    toast.show(addedMessage(for: title))
                                }
                                dismiss()
                            } label: {
                                Label(addTargetName.map { "Add to \($0)" } ?? "Add to Watchlist", systemImage: "plus")
                            }
                        } else {
                            Button(role: .destructive) {
                                isConfirmingRemoval = true
                            } label: {
                                Label(removeLabel ?? "Remove", systemImage: "trash")
                            }
                            .accessibilityLabel(removeLabel ?? "Remove from watchlist")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                await fetchFullDetails()
            }
            .alert(removeLabel.map { "\($0)?" } ?? "Remove from watchlist?", isPresented: $isConfirmingRemoval) {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removeMessage ?? "This will delete this title from your watch list.")
            }
            .sheet(item: $selectedSimilarItem) { item in
                MediaDetailView(
                    listItem: similarDetailBinding(for: item),
                    dismiss: { selectedSimilarItem = nil },
                    onRemove: { selectedSimilarItem = nil },
                    onAdd: canAddToLibrary ? { addSimilarFromDetail(item) } : nil,
                    existingIDs: existingIDs.union(addedSimilarIDs),
                    onTVShowAdded: onTVShowAdded,
                    onMovieAdded: onMovieAdded,
                    addTargetName: addTargetName
                )
            }
            .toastOverlay()
        }
    }

    // MARK: - Action Buttons

    /// The sheet's floating control layer — the one place glass belongs in this view.
    private var actionButtonRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if let customListVM = customListViewModel {
                    Button { showingAddToList = true } label: {
                        Label("Collections", systemImage: "tray.full")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
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
                        Label("Trailer", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .sheet(isPresented: $showingTrailer) {
                        if let url = URL(string: "https://www.youtube.com/watch?v=\(trailerKey ?? "")") {
                            SafariView(url: url)
                                .ignoresSafeArea()
                        }
                    }
                }

                if let tmdbURL {
                    Button { showingTMDBPage = true } label: {
                        Label("TMDB", systemImage: "film")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .sheet(isPresented: $showingTMDBPage) {
                        SafariView(url: tmdbURL)
                            .ignoresSafeArea()
                    }
                }

                // In a detail column there's no navigation bar to hang Add/Remove off, so the
                // primary action joins the floating row instead.
                if presentedInColumn {
                    if let onAdd {
                        Button {
                            onAdd()
                            if let title = listItem.media?.title {
                                toast.show(addedMessage(for: title))
                            }
                            dismiss()
                        } label: {
                            Label(addTargetName.map { "Add to \($0)" } ?? "Add to Watchlist", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label(removeLabel ?? "Remove", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(.red)
                        .accessibilityLabel(removeLabel ?? "Remove from watchlist")
                    }
                }
            }
            .labelStyle(StackedLabelStyle())
            .controlSize(.large)
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

                let similar = (detail.similar?.results ?? []).map {
                    SimilarMediaItem(id: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
                }
                let recommended = (detail.recommendations?.results ?? []).map {
                    SimilarMediaItem(id: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
                }
                moreLikeThisItems = Self.mergedMoreLikeThis(
                    recommended: recommended,
                    similar: similar,
                    currentKey: MediaIDKey.make(.tvShow, id),
                    existingIDs: existingIDs
                )
                trailerKey = Self.bestTrailerKey(from: detail.videos)
            } else if let movie = listItem.movie {
                let detail = try await service.getMovieDetails(id: id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie.update(from: await service.mapToMovie(detail, providers: providers))

                let similar = (detail.similar?.results ?? []).map {
                    SimilarMediaItem(id: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
                }
                let recommended = (detail.recommendations?.results ?? []).map {
                    SimilarMediaItem(id: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
                }
                moreLikeThisItems = Self.mergedMoreLikeThis(
                    recommended: recommended,
                    similar: similar,
                    currentKey: MediaIDKey.make(.movie, id),
                    existingIDs: existingIDs
                )
                trailerKey = Self.bestTrailerKey(from: detail.videos)

                if let collection = detail.belongsToCollection {
                    tmdbCollectionName = collection.name
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

    /// Whether this sheet was given a way to add titles to the watchlist. Without it, a "+"
    /// would toast "added" and go nowhere.
    private var canAddToLibrary: Bool {
        onTVShowAdded != nil || onMovieAdded != nil
    }

    private func addedMessage(for title: String) -> String {
        if let addTargetName { return "\(title) added to \(addTargetName)" }
        return "\(title) has been added"
    }

    private func addSimilarItem(_ item: SimilarMediaItem) {
        let stringID = String(item.id)
        let key = MediaIDKey.make(item.mediaType, stringID)
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key) else { return }
        addedSimilarIDs.insert(key)
        toast.show(addedMessage(for: item.title))

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
        // Collection parts are always movies.
        let key = MediaIDKey.make(.movie, stringID)
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key) else { return }
        addedSimilarIDs.insert(key)
        toast.show(addedMessage(for: part.title))

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
        let key = MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key) else { return }
        addedSimilarIDs.insert(key)
        toast.show(addedMessage(for: media.title))
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

// MARK: - Collection Watched

/// Watched state for a title opened from a collection. Collections are seasonal / thematic pools
/// with their own watched state, so this toggle stays entirely inside the collection.
private struct CollectionWatchedCard: View {
    let collectionName: String?
    @Binding var isWatched: Bool

    /// Spoken form carries the collection name; the visible title stays short so it never wraps.
    private var accessibilityTitle: String {
        guard let collectionName, !collectionName.isEmpty else { return "Watched in this collection" }
        return "Watched in \(collectionName)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isWatched ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Watched")
                    .font(.headline)
                Text("In this collection only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Toggle(accessibilityTitle, isOn: $isWatched)
                .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .sensoryFeedback(.selection, trigger: isWatched)
    }
}

/// Icon over a one-line caption — keeps three glass buttons on one row at any label length.
private struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.body)
            configuration.title
                .font(.caption2)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Shared Detail Components

/// Detail-sheet header. With a TMDB backdrop it renders full-bleed 16:9 artwork with the poster
/// floating over its bottom-leading edge; without one it falls back to the poster as the header.
struct HeaderImageView: View {
    let backdropPath: String?
    let posterURL: URL?
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Width of the view itself — only consulted at regular width, to scale the backdrop.
    @State private var availableWidth: CGFloat = 0

    private let compactBackdropHeight: CGFloat = 260
    /// Ceiling for the backdrop at regular width. Letting 16:9 run free in a 1000pt-wide detail
    /// column would hand back a 560pt hero and push everything else below the fold.
    private let maxBackdropHeight: CGFloat = 420
    private let posterWidth: CGFloat = 100
    private let posterHeight: CGFloat = 150
    /// How far the floating poster hangs below the backdrop.
    private let posterOverhang: CGFloat = 60
    private let posterHeaderHeight: CGFloat = 420

    /// Fixed on iPhone; on wider layouts the artwork grows toward 16:9 but stops at the cap.
    private var backdropHeight: CGFloat {
        guard horizontalSizeClass == .regular, availableWidth > 0 else { return compactBackdropHeight }
        return min(availableWidth * 9 / 16, maxBackdropHeight)
    }

    private var backdropURL: URL? {
        TMDBService.shared.imageURL(path: backdropPath, size: .w780)
    }

    var body: some View {
        Group {
            if let backdropURL {
                backdropHeader(url: backdropURL)
            } else {
                posterHeader
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    // MARK: - Backdrop layout

    private func backdropHeader(url: URL) -> some View {
        ZStack(alignment: .topLeading) {
            parallaxImage(url: url, height: backdropHeight)
                .overlay(alignment: .bottom) { bottomFade(height: 170) }

            VStack(alignment: .leading, spacing: 0) {
                // Reserve the backdrop's height minus the overlap, so the poster row lands
                // across the header's bottom edge without an offset hack.
                Color.clear
                    .frame(height: backdropHeight - posterOverhang)

                HStack(alignment: .bottom, spacing: 14) {
                    posterThumbnail

                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(3)
                        .padding(.bottom, 6)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Poster-only fallback

    private var posterHeader: some View {
        Group {
            if let posterURL {
                parallaxImage(url: posterURL, height: posterHeaderHeight)
            } else {
                imagePlaceholder
                    .frame(height: posterHeaderHeight)
            }
        }
        .overlay(alignment: .bottom) { bottomFade(height: 260) }
        .overlay(alignment: .bottomLeading) {
            Text(title)
                .font(.title)
                .fontWeight(.bold)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func parallaxImage(url: URL, height: CGFloat) -> some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            case .success(let image):
                if reduceMotion {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipped()
                } else {
                    GeometryReader { geo in
                        let minY = geo.frame(in: .scrollView).minY
                        let overscroll = max(minY, 0)
                        let scrollOffset = max(-minY, 0)

                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(
                                width: geo.size.width,
                                height: height + overscroll,
                                alignment: .top
                            )
                            .clipped()
                            .offset(y: -scrollOffset * 0.3 - overscroll)
                    }
                    .frame(height: height)
                }
            case .failure:
                imagePlaceholder
                    .frame(height: height)
            @unknown default:
                EmptyView()
            }
        }
    }

    private var posterThumbnail: some View {
        Group {
            if let posterURL {
                CachedAsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.poster))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }

    /// Fades the artwork into the app background so the header has no hard edge.
    private func bottomFade(height: CGFloat) -> some View {
        let base = DesignTokens.Colors.backgroundBase
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0.0),
                .init(color: base.opacity(0.45), location: 0.4),
                .init(color: base.opacity(0.88), location: 0.75),
                .init(color: base, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
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
                        Chip(text: genre)
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
            .background(.fill.tertiary, in: .circle)
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
            backdropPath: "/h8gHn0OzBoaefsYseUByqsmEDMY.jpg",
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
