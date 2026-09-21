import CoreData
import SwiftUI

struct MediaDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var listItem: ListItem
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
    /// Copy for the pill menu's destructive row. Defaults to the watchlist's wording; collections
    /// override it with collection-scoped wording.
    var removeLabel: String?
    @Environment(ToastState.self) private var toast

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false
    /// Set by the primary Add pill so the sheet can flip its "Add to Up Next" button to a
    /// "✓ On Up Next" status chip without waiting for the store to round-trip. Cleared when
    /// the sheet reopens on a new title.
    @State private var justAddedLocally = false
    /// TMDB's recommendations and similar-titles feeds merged into one ranked, deduped list —
    /// see `mergedMoreLikeThis`.
    @State private var moreLikeThisItems: [SimilarMediaItem] = []
    @State private var trailerKey: String?
    @State private var selectedSimilarItem: ListItem?
    /// The tapped poster card's zoom-transition source id, captured alongside `selectedSimilarItem`
    /// — `moreLikeThisItems`/`collectionParts` can carry the same title in both rows, so the id also
    /// carries which row it came from (see `CollectionSection`/`SimilarSection`).
    @State private var selectedSimilarSourceID: String = ""
    @State private var addedSimilarIDs: Set<String> = []
    /// The "More Like This" card mid-collapse. It stays in `visibleMoreLikeThis` (so it keeps its
    /// slot) while its own frame/opacity animate to zero, then moves into `addedSimilarIDs` on
    /// completion — animating a stable view's own geometry works where a `ForEach` removal transition
    /// inside a horizontal `ScrollView` does not.
    @State private var collapsingSimilarID: String?
    /// Namespace for the nested "similar title" detail sheet's zoom transition — separate from any
    /// namespace the presenter handed this sheet, since this one is scoped to this view's own
    /// poster carousels.
    @Namespace private var similarNamespace
    /// TMDB's movie collection (e.g. "The Dark Knight Collection") — unrelated to the user's
    /// Collections tab; named apart from the `collectionName` input above.
    @State private var tmdbCollectionName: String?
    @State private var collectionParts: [TMDBCollectionPart] = []
    /// Dominant color of the header artwork, reported up by `HeaderImageView` so the sheet
    /// background can wash the same tint over the top — see `HeaderImageView.onTintChange`.
    @State private var heroTint: DominantTint?
    /// Display-only season scores from the existing show detail response.
    @State private var seasonRatings: [Int: Double] = [:]
    /// When this device last changed watched state from this sheet. `SeasonChecklistCard` uses it
    /// to tell a local toggle from a partner's edit arriving while the sheet is open.
    @State private var lastLocalWatchedEdit: Date?

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
        // Everything already in the library plus everything added during this session — computed
        // once, then handed to every carousel and the nested sheet.
        let knownIDs = existingIDs.union(addedSimilarIDs)

        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HeaderImageView(
                        backdropPath: backdropPath,
                        posterURL: listItem.media?.thumbnailURL,
                        title: listItem.media?.title ?? "",
                        onTintChange: { heroTint = $0 }
                    )

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                        // Metadata chips and genre chips read as one badge block, so they share the
                        // FlowLayout's 8pt row rhythm — the 20pt section gap only sets them apart
                        // from the provider row below, not from each other.
                        VStack(alignment: .leading, spacing: 8) {
                            if let tvShow = listItem.tvShow {
                                MetadataRow(media: tvShow)
                            } else if let movie = listItem.movie {
                                MetadataRow(media: movie)
                            }

                            GenreSection(genres: listItem.media?.genres ?? [])
                        }

                        DetailProviderRow(
                            networks: allNetworks,
                            providerCategories: listItem.media?.providerCategories ?? [:]
                        )
                        AddedByCaption(listItem: listItem)

                        PrimaryAddPill(
                            listItem: listItem,
                            customListViewModel: customListViewModel,
                            existingIDs: existingIDs,
                            addTargetName: addTargetName,
                            collectionName: collectionName,
                            isCollectionEntry: collectionWatched != nil,
                            removeLabel: removeLabel,
                            onAdd: onAdd,
                            justAddedLocally: $justAddedLocally,
                            isConfirmingRemoval: $isConfirmingRemoval,
                            lastLocalWatchedEdit: $lastLocalWatchedEdit
                        )

                        DescriptionSection(
                            isLoading: isLoadingDetails,
                            descriptionText: listItem.media?.descriptionText,
                            errorMessage: detailError,
                            onRetry: { Task { await fetchFullDetails() } })

                        CastSection(
                            cast: listItem.media?.cast ?? [],
                            castImagePaths: listItem.media?.castImagePaths ?? [],
                            castCharacters: listItem.media?.castCharacters ?? []
                        )

                        TrailerButton(trailerKey: trailerKey)

                        // State-transition controls live in `PrimaryAddPill`'s menu — those
                        // "Move to Up Next" / "Mark as Watched" / etc. cards were duplicating what
                        // the pill's own status label reports. Cards below are content-granular
                        // (per-season checklist, notes/rating, episode nav), not state-toggles.
                        if let collectionWatched {
                            CollectionWatchedCard(
                                collectionName: collectionName,
                                isWatched: collectionWatched
                            )
                            seasonContent(allowsWatchedChanges: false)
                        } else if onAdd == nil {
                            seasonContent(allowsWatchedChanges: true)

                            // Notes are useful before a title is watched; thumbs are a verdict,
                            // so they only appear once it is.
                            UserRatingCard(listItem: listItem, showsRating: listItem.isWatched)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            seasonContent(allowsWatchedChanges: false)
                        }

                        CollectionSection(
                            collectionName: tmdbCollectionName,
                            parts: collectionParts,
                            currentMovieID: listItem.movie.map { Int($0.id) ?? 0 },
                            existingIDs: knownIDs,
                            onAdd: canAddToLibrary ? { addCollectionItem($0) } : nil,
                            onTap: { openCollectionDetail($0) },
                            transitionNamespace: similarNamespace,
                            transitionIDPrefix: "collection"
                        )

                        SimilarSection(
                            title: "More Like This",
                            items: visibleMoreLikeThis,
                            collapsingKey: collapsingSimilarID,
                            existingIDs: knownIDs,
                            onAdd: canAddToLibrary ? { addSimilarItem($0) } : nil,
                            onTap: { openSimilarDetail($0) },
                            transitionNamespace: similarNamespace,
                            transitionIDPrefix: "similar"
                        )

                        if let tmdbURL {
                            TMDBFooterLink(url: tmdbURL)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    // Keeps the text column readable when the view is wider than a phone — the
                    // iPad page sheet. Never reached on iPhone.
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .background {
                // Per-title wash over the top of the sheet, echoing the header artwork's
                // dominant color (Apple Music album-view style). The rest of the design system
                // stays purple — this is scoped to this one sheet. Layered *over* `AppBackground`
                // (backgrounds stack outward, so this one must come first) — the mesh is opaque.
                ZStack(alignment: .top) {
                    AppBackground()
                    if let heroTint {
                        LinearGradient(
                            colors: [
                                heroTint.color(for: colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.7),
                                .clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                        .frame(maxWidth: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        // The header artwork eases its own fade to the same tint; without a
                        // matching transition this wash would snap in underneath it.
                        .transition(.opacity)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await fetchFullDetails()
            }
            .alert(removalAlertTitle, isPresented: $isConfirmingRemoval) {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removalAlertMessage)
            }
            .sheet(item: $selectedSimilarItem) { item in
                MediaDetailView(
                    listItem: item,
                    dismiss: { selectedSimilarItem = nil },
                    onRemove: { selectedSimilarItem = nil },
                    onAdd: canAddToLibrary ? { addSimilarFromDetail(item) } : nil,
                    existingIDs: knownIDs,
                    onTVShowAdded: onTVShowAdded,
                    onMovieAdded: onMovieAdded,
                    addTargetName: addTargetName
                )
                .navigationTransition(.zoom(sourceID: selectedSimilarSourceID, in: similarNamespace))
            }
            .toastOverlay()
        }
    }

    @ViewBuilder
    private func seasonContent(allowsWatchedChanges: Bool) -> some View {
        if let tvShow = listItem.tvShow {
            DetailSeasonsSection(
                listItem: listItem,
                tvShow: tvShow,
                ratings: seasonRatings,
                allowsWatchedChanges: allowsWatchedChanges,
                lastLocalWatchedEdit: $lastLocalWatchedEdit
            )
        }
    }

    // MARK: - Removal

    /// The confirmation names the same place the menu row does, so the two never disagree about
    /// what "remove" means here.
    private var removalAlertTitle: String {
        if let collectionName { return "Remove from \(collectionName)?" }
        return "Remove from Up Next?"
    }

    private var removalAlertMessage: String {
        if collectionName != nil { return "It stays in Up Next if it's there." }
        return "This removes it from your Up Next. Notes and ratings go with it."
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
                guard !Task.isCancelled else { return }
                seasonRatings = (detail.seasons ?? []).reduce(into: [:]) { ratings, season in
                    guard season.seasonNumber > 0, let rating = season.voteAverage,
                          rating.isFinite, rating > 0, rating <= 10 else { return }
                    ratings[season.seasonNumber] = rating
                }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                let mapped = await service.mapToTVShow(detail, providers: providers)
                guard !Task.isCancelled else { return }
                // A deferred delete may have committed while the fetch was in flight; writing to a
                // deleted or detached row would fault.
                guard isUsable(tvShow) else { return }
                tvShow.update(from: mapped)

                // Always re-derive, not just when the season count grew: an announced season
                // becoming watchable changes availability without changing the count, and the
                // handler is a cheap, idempotent re-sync.
                onSeasonCountChanged?(listItem, previousSeasonCount)

                let similar = (detail.similar?.results ?? []).map {
                    SimilarMediaItem(tmdbID: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
                }
                let recommended = (detail.recommendations?.results ?? []).map {
                    SimilarMediaItem(tmdbID: $0.id, title: $0.name, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .tvShow)
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
                guard !Task.isCancelled else { return }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                let mapped = await service.mapToMovie(detail, providers: providers)
                guard !Task.isCancelled else { return }
                guard isUsable(movie) else { return }
                movie.update(from: mapped)

                let similar = (detail.similar?.results ?? []).map {
                    SimilarMediaItem(tmdbID: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
                }
                let recommended = (detail.recommendations?.results ?? []).map {
                    SimilarMediaItem(tmdbID: $0.id, title: $0.title, posterPath: $0.posterPath, voteAverage: $0.voteAverage, mediaType: .movie)
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
                        guard !Task.isCancelled else { return }
                        collectionParts = collectionDetail.parts.sorted {
                            ($0.releaseDate ?? "") < ($1.releaseDate ?? "")
                        }
                    } catch {
                        collectionParts = []
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            if showLoading {
                detailError = error.localizedDescription
            }
        }

        isLoadingDetails = false
    }

    /// A media row is safe to write to only while it's still attached and undeleted — the sheet
    /// can outlive a deferred removal committing underneath it.
    private func isUsable(_ object: NSManagedObject) -> Bool {
        object.managedObjectContext != nil && !object.isDeleted
    }

    // MARK: - Similar / Collection Actions

    /// Whether this sheet was given a way to add titles to the watchlist. Without it, a "+"
    /// would toast "added" and go nowhere.
    private var canAddToLibrary: Bool {
        onTVShowAdded != nil || onMovieAdded != nil
    }

    private func addedMessage(for title: String) -> String {
        addedToastMessage(title, target: addTargetName)
    }

    /// The "More Like This" cards actually shown: the merged pool minus anything added this session,
    /// capped at 12. Adding a title drops it and slides the next pool entry up into its place, rather
    /// than leaving a checked-off card sitting in the row.
    private var visibleMoreLikeThis: [SimilarMediaItem] {
        moreLikeThisItems
            .filter { !addedSimilarIDs.contains($0.transitionKey) }
            .prefix(12)
            .map { $0 }
    }

    private func addSimilarItem(_ item: SimilarMediaItem) {
        let stringID = String(item.tmdbID)
        let key = item.transitionKey
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key), collapsingSimilarID != key else { return }
        toast.show(addedMessage(for: item.title))
        if reduceMotion {
            addedSimilarIDs.insert(key)
        } else {
            // Collapse the tapped card in place, then drop it (and slide the reserve up) once the
            // shrink finishes — see `collapsingSimilarID`.
            withAnimation(Motion.pop) {
                collapsingSimilarID = key
            } completion: {
                withAnimation(Motion.pop) {
                    addedSimilarIDs.insert(key)
                    collapsingSimilarID = nil
                }
            }
        }

        Task {
            if item.mediaType == .tvShow {
                let tvShow: TVShow
                do {
                    let d = try await service.getTVShowDetails(id: item.tmdbID)
                    let p = d.watchProviders?.results?[service.currentRegion]
                    tvShow = await service.mapToTVShow(d, providers: p)
                } catch {
                    tvShow = TVShow(id: stringID, title: item.title, thumbnailURL: service.imageURL(path: item.posterPath), voteAverage: item.voteAverage)
                }
                onTVShowAdded?(tvShow)
            } else {
                let movie: Movie
                do {
                    let d = try await service.getMovieDetails(id: item.tmdbID)
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
        selectedSimilarSourceID = "similar:" + item.transitionKey
        let posterURL = service.imageURL(path: item.posterPath)
        if item.mediaType == .tvShow {
            let tvShow = TVShow(id: String(item.tmdbID), title: item.title, thumbnailURL: posterURL, voteAverage: item.voteAverage)
            selectedSimilarItem = ListItem(tvShow: tvShow)
        } else {
            let movie = Movie(id: String(item.tmdbID), title: item.title, thumbnailURL: posterURL, voteAverage: item.voteAverage)
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
        selectedSimilarSourceID = "collection:" + MediaIDKey.make(.movie, part.id)
        let posterURL = service.imageURL(path: part.posterPath)
        let movie = Movie(id: String(part.id), title: part.title, thumbnailURL: posterURL, voteAverage: part.voteAverage)
        selectedSimilarItem = ListItem(movie: movie)
    }

    private func addSimilarFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let key = MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key) else { return }
        // Added from the nested detail sheet (which covers the row), so no in-place collapse to run —
        // the card is simply gone when the sheet dismisses.
        addedSimilarIDs.insert(key)
        // No toast here — the child sheet's primary Add pill (`performPrimaryAdd`) already fires
        // one, and this method is only reached from that pill's `onAdd`.
        if let tvShow = item.tvShow {
            onTVShowAdded?(tvShow)
        } else if let movie = item.movie {
            onMovieAdded?(movie)
        }
    }

}
