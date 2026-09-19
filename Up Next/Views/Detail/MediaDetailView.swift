import SwiftUI

struct MediaDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    /// Copy for the leading destructive button and its confirmation. Defaults to the watchlist's
    /// "delete this title" wording; collections override it with collection-scoped wording.
    var removeLabel: String?
    var removeMessage: String?

    @Environment(ToastState.self) private var toast

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false
    @State private var showingTMDBPage = false
    /// Set by the primary Add pill so the sheet can flip its "Add to Up Next" button to a
    /// "✓ On Up Next" status chip without waiting for the store to round-trip. Cleared when
    /// the sheet reopens on a new title.
    @State private var justAddedLocally = false
    /// TMDB's recommendations and similar-titles feeds merged into one ranked, deduped list —
    /// see `mergedMoreLikeThis`.
    @State private var moreLikeThisItems: [SimilarMediaItem] = []
    @State private var trailerKey: String?
    @State private var showingTrailer = false
    @State private var selectedSimilarItem: ListItem?
    /// The tapped poster card's zoom-transition source id, captured alongside `selectedSimilarItem`
    /// — `moreLikeThisItems`/`collectionParts` can carry the same title in both rows, so the id also
    /// carries which row it came from (see `CollectionSection`/`SimilarSection`).
    @State private var selectedSimilarSourceID: String = ""
    @State private var addedSimilarIDs: Set<String> = []
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

    /// nil when the show's id isn't a TMDB int (shouldn't happen for a persisted row) — every
    /// `EpisodesLinkCard` placement just doesn't render.
    private var tvShowID: Int? {
        listItem.tvShow.flatMap { Int($0.id) }
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

                        primaryAddPill

                        DescriptionSection(
                            isLoading: isLoadingDetails,
                            descriptionText: listItem.media?.descriptionText,
                            errorMessage: detailError)

                        CastSection(
                            cast: listItem.media?.cast ?? [],
                            castImagePaths: listItem.media?.castImagePaths ?? [],
                            castCharacters: listItem.media?.castCharacters ?? []
                        )

                        trailerButton

                        // State-transition controls live in `primaryAddPill`'s menu now — those
                        // "Move to Up Next" / "Mark as Watched" / etc. cards were duplicating what
                        // the pill's own status label reports. Cards below are content-granular
                        // (per-season checklist, thumbs rating, episode nav), not state-toggles.
                        if let collectionWatched {
                            CollectionWatchedCard(
                                collectionName: collectionName,
                                isWatched: collectionWatched
                            )
                            seasonContent(allowsWatchedChanges: false)
                        } else if onAdd == nil {
                            seasonContent(allowsWatchedChanges: true)

                            if listItem.isWatched {
                                UserRatingCard(listItem: listItem)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        } else {
                            seasonContent(allowsWatchedChanges: false)
                        }

                        CollectionSection(
                            collectionName: tmdbCollectionName,
                            parts: collectionParts,
                            currentMovieID: listItem.movie.map { Int($0.id) ?? 0 },
                            existingIDs: existingIDs.union(addedSimilarIDs),
                            onAdd: canAddToLibrary ? { addCollectionItem($0) } : nil,
                            onTap: { openCollectionDetail($0) },
                            transitionNamespace: similarNamespace,
                            transitionIDPrefix: "collection"
                        )

                        SimilarSection(
                            title: "More Like This",
                            items: moreLikeThisItems,
                            existingIDs: existingIDs.union(addedSimilarIDs),
                            onAdd: canAddToLibrary ? { addSimilarItem($0) } : nil,
                            onTap: { openSimilarDetail($0) },
                            transitionNamespace: similarNamespace,
                            transitionIDPrefix: "similar"
                        )

                        if let tmdbURL {
                            tmdbFooterLink(url: tmdbURL)
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
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [
                                    heroTint.color(for: colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.7),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: proxy.size.height * 0.45)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
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
                    listItem: item,
                    dismiss: { selectedSimilarItem = nil },
                    onRemove: { selectedSimilarItem = nil },
                    onAdd: canAddToLibrary ? { addSimilarFromDetail(item) } : nil,
                    existingIDs: existingIDs.union(addedSimilarIDs),
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
                allowsWatchedChanges: allowsWatchedChanges
            )
        }
    }

    // MARK: - Primary Add Pill

    /// Namespaced key for the currently-open title. `MediaIDKey.make` treats TV and movie ids as
    /// distinct namespaces so a set of these can safely mix both.
    private var currentMediaKey: String? {
        guard let media = listItem.media, let id = Int(media.id) else { return nil }
        return MediaIDKey.make(listItem.tvShow != nil ? .tvShow : .movie, id)
    }

    private var isAlreadyInLibrary: Bool {
        guard let currentMediaKey else { return false }
        return existingIDs.contains(currentMediaKey)
    }

    /// Human name for the primary add target: the collection name when opened in an "add to
    /// collection" flow (Discover/similar from inside a collection), else "Up Next".
    private var primaryAddTarget: String { addTargetName ?? "Up Next" }

    private enum PillState {
        /// Big glass "Add to <target>" pill; not yet added.
        case addable
        /// Big glass pill that was just tapped or is already in the target — shows the check state.
        case added
    }

    private var pillState: PillState {
        // Any of these mean the title is already in whatever the current target is: it's a library
        // item (owned), a collection member (collectionWatched set), we just added it in this
        // session, or the parent's existingIDs already flags it.
        if collectionWatched != nil || onAdd == nil || justAddedLocally || isAlreadyInLibrary {
            return .added
        }
        return .addable
    }

    /// The primary action pill shown right below metadata. Replaces the old toolbar "+" and puts
    /// the Add verb where the eye lands. Its menu is the one place users can add/remove this
    /// title from any collection while browsing detail.
    @ViewBuilder
    private var primaryAddPill: some View {
        switch pillState {
        case .addable:
            addablePillView
                .transition(Motion.morph)
        case .added:
            statusPillView
                .transition(Motion.morph)
        }
    }

    private var addablePillView: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    performPrimaryAdd()
                } label: {
                    Label("Add to \(primaryAddTarget)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .accessibilityLabel("Add to \(primaryAddTarget)")

                pillMenuButton
            }
        }
        .sensoryFeedback(.success, trigger: justAddedLocally)
    }

    private var statusPillView: some View {
        HStack(spacing: 10) {
            Image(systemName: statusPillIcon)
                .font(.title3)
                .foregroundStyle(statusPillIconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: statusPillIcon)
                .accessibilityHidden(true)

            Text(statusPillTitle)
                .font(.headline)

            Spacer(minLength: 0)

            pillMenuButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .accessibilityElement(children: .combine)
    }

    /// The status pill's label reflects the *actual* library state of the title, not just "On Up
    /// Next" — otherwise a show set to Watching reads "On Up Next" here while the card below offers
    /// "Move to Up Next", which is confusing. Order: collection > just-added toast > library state.
    private var statusPillTitle: String {
        if let collectionName, collectionWatched != nil {
            return "In \(collectionName)"
        }
        // Fresh-add flip in browse context: use the target we just added to, not the derived
        // library state (the ListItem may not have picked up its list membership yet).
        if justAddedLocally {
            return "On \(primaryAddTarget)"
        }
        // Library context: reflect the actual watch state.
        if listItem.list != nil {
            if listItem.isDropped { return "Dropped" }
            if listItem.isWatched { return "Watched" }
            if listItem.isWatching { return "Watching" }
            return "On Up Next"
        }
        // Browse context where the title was already in the parent's existingIDs — the transient
        // ListItem carries no library state, so "In Library" is the honest label.
        return "In Library"
    }

    private var statusPillIcon: String {
        if collectionWatched != nil { return "checkmark.circle.fill" }
        if justAddedLocally { return "checkmark.circle.fill" }
        if listItem.list != nil {
            if listItem.isDropped { return "xmark.circle.fill" }
            if listItem.isWatched { return "checkmark.circle.fill" }
            if listItem.isWatching { return "play.circle.fill" }
            return "bookmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusPillIconColor: Color {
        if collectionWatched != nil { return .green }
        if justAddedLocally { return .green }
        if listItem.list != nil {
            if listItem.isDropped { return .orange }
            if listItem.isWatched { return .green }
            if listItem.isWatching { return Color.accentColor }
            return Color.accentColor
        }
        return .green
    }

    private var pillMenuButton: some View {
        Menu {
            pillMenuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private var pillMenuContent: some View {
        libraryStateActions

        if !collectionMenuEntries.isEmpty {
            Section("Collections") {
                ForEach(collectionMenuEntries) { entry in
                    Button(action: entry.toggle) {
                        if entry.isMember {
                            Label(entry.name, systemImage: "checkmark")
                        } else {
                            Text(entry.name)
                        }
                    }
                }
            }
        }

        if canRemoveFromPill {
            // Plain Text (no `Label` with icon) so the destructive item renders on one line at
            // any menu width — the icon+text pair wrapped in narrow menus.
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Text(destructiveMenuLabel)
            }
        }
    }

    private var destructiveMenuLabel: String {
        if let removeLabel { return removeLabel }
        return "Remove from Up Next"
    }

    /// State-transition actions for library-owned titles — the pill's menu is the one place
    /// these live now (`WatchingToggleCard` / `WatchedToggleCard` / `DoneWatchingCard` are gone).
    @ViewBuilder
    private var libraryStateActions: some View {
        // Only library-owned items get state actions. Browse/add and collection contexts skip.
        if listItem.list != nil, collectionWatched == nil {
            Section {
                if listItem.tvShow != nil {
                    tvStateActions
                } else if listItem.movie != nil {
                    movieStateActions
                }
            }
        }
    }

    @ViewBuilder
    private var tvStateActions: some View {
        if listItem.isDropped {
            Button {
                withAnimation { listItem.resumeShow() }
                persistence.save()
            } label: { Label("Pick Back Up", systemImage: "arrow.uturn.forward.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        } else if listItem.isWatched {
            Button {
                markLibraryUnwatched()
            } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") }
        } else if listItem.isWatching {
            Button {
                withAnimation { listItem.toggleWatching() }
                persistence.save()
            } label: { Label("Move to Up Next", systemImage: "list.bullet.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        } else {
            // On Up Next
            Button {
                withAnimation { listItem.toggleWatching() }
                persistence.save()
            } label: { Label("Start Watching", systemImage: "play.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        }
    }

    @ViewBuilder
    private var movieStateActions: some View {
        if listItem.isWatched {
            Button {
                markLibraryUnwatched()
            } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") }
        } else {
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        }
    }

    /// Marks the current library item watched: seasons filled, `isWatched` on, `watchedAt` now.
    /// Also finalises Watching (clears `watchingStartedAt`) and reverses any drop, so the state
    /// ends cleanly at "Watched" instead of the "watching+watched" limbo.
    private func markLibraryWatched() {
        withAnimation {
            listItem.droppedAt = nil
            listItem.watchingStartedAt = nil
            if let tvShow = listItem.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                listItem.watchedSeasons = Array(1...total)
            }
            listItem.isWatched = true
            listItem.watchedAt = .now
        }
        persistence.save()
    }

    private func markLibraryUnwatched() {
        withAnimation {
            listItem.droppedAt = nil
            if let tvShow = listItem.tvShow, (tvShow.numberOfSeasons ?? 0) > 0 {
                listItem.watchedSeasons = []
            }
            listItem.isWatched = false
            listItem.watchedAt = nil
        }
        persistence.save()
    }

    private var persistence: PersistenceController { PersistenceController.shared }

    /// Present a Remove menu item whenever there's something to remove: a library-owned title, a
    /// collection member, or a title we just added in this session (so the same tap can undo).
    private var canRemoveFromPill: Bool {
        if collectionWatched != nil { return true }        // collection detail
        if onAdd == nil { return true }                     // library detail
        return false                                        // browse/add context: nothing to remove
    }

    private struct PillCollectionEntry: Identifiable {
        /// The `CustomList`'s stable UUID (`CustomList.id`) — no CoreData types leak into this view.
        let id: String
        let name: String
        let isMember: Bool
        let toggle: () -> Void
    }

    private var collectionMenuEntries: [PillCollectionEntry] {
        guard let vm = customListViewModel else { return [] }
        guard let mediaID = listItem.media?.id else { return [] }
        // Read changeToken so the menu re-derives its check marks when collections mutate.
        _ = vm.changeToken
        return vm.customLists.map { list in
            let isMember = vm.containsItem(mediaID: mediaID, mediaType: listItem.tvShow == nil ? .movie : .tvShow, in: list)
            return PillCollectionEntry(
                id: list.id.uuidString,
                name: list.name,
                isMember: isMember
            ) {
                toggleCollectionMembership(mediaID: mediaID, list: list, currentlyMember: isMember)
            }
        }
    }

    private func toggleCollectionMembership(mediaID: String, list: CustomList, currentlyMember: Bool) {
        guard let vm = customListViewModel else { return }
        if currentlyMember {
            if let item = vm.item(mediaID: mediaID, mediaType: listItem.tvShow == nil ? .movie : .tvShow, in: list) {
                let title = vm.removeItem(item, from: list) ?? listItem.media?.title ?? "Title"
                toast.show("\(title) removed from \(list.name)", icon: "trash")
            }
        } else {
            vm.addItem(movie: listItem.movie, tvShow: listItem.tvShow, to: list)
            let title = listItem.media?.title ?? "Title"
            toast.show("\(title) added to \(list.name)")
        }
    }

    /// The pill's primary-tap action for the addable state. Fires the parent's `onAdd`, shows a
    /// confirmation toast, and flips the pill to its status style in place — the sheet stays open
    /// so the user can keep reading and/or add to collections.
    private func performPrimaryAdd() {
        guard let onAdd else { return }
        onAdd()
        if let title = listItem.media?.title {
            toast.show(addedMessage(for: title))
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            justAddedLocally = true
        }
    }

    // MARK: - Trailer

    @ViewBuilder
    private var trailerButton: some View {
        if let trailerKey {
            Button { showingTrailer = true } label: {
                Label("Trailer", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .labelStyle(StackedLabelStyle())
            .controlSize(.large)
            .sheet(isPresented: $showingTrailer) {
                if let url = URL(string: "https://www.youtube.com/watch?v=\(trailerKey)") {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }

    /// Small caption-style link at the very bottom of the content column — the TMDB page is a
    /// reference, not an action, so it doesn't belong in the glass control row.
    private func tmdbFooterLink(url: URL) -> some View {
        Button {
            showingTMDBPage = true
        } label: {
            Text("View on TMDB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingTMDBPage) {
            SafariView(url: url)
                .ignoresSafeArea()
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
                seasonRatings = (detail.seasons ?? []).reduce(into: [:]) { ratings, season in
                    guard season.seasonNumber > 0, let rating = season.voteAverage,
                          rating.isFinite, rating > 0, rating <= 10 else { return }
                    ratings[season.seasonNumber] = rating
                }
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow.update(from: await service.mapToTVShow(detail, providers: providers))

                // Always re-derive, not just when the season count grew: an announced season
                // becoming watchable changes availability without changing the count, and the
                // handler is a cheap, idempotent re-sync.
                onSeasonCountChanged?(listItem, previousSeasonCount)

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
        selectedSimilarSourceID = "similar:" + MediaIDKey.make(item.mediaType, item.id)
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
        selectedSimilarSourceID = "collection:" + MediaIDKey.make(.movie, part.id)
        let posterURL = service.imageURL(path: part.posterPath)
        let movie = Movie(id: String(part.id), title: part.title, thumbnailURL: posterURL, voteAverage: part.voteAverage)
        selectedSimilarItem = ListItem(movie: movie)
    }

    private func addSimilarFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let key = MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        guard !existingIDs.contains(key), !addedSimilarIDs.contains(key) else { return }
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
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isWatched)

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
    @Environment(\.colorScheme) private var colorScheme
    let backdropPath: String?
    let posterURL: URL?
    let title: String
    /// Reports the artwork's dominant color upward whenever it's computed, so the presenting
    /// sheet can wash the same tint over its own background. Nil until the first image loads.
    var onTintChange: ((DominantTint?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Width of the view itself — only consulted at regular width, to scale the backdrop.
    @State private var availableWidth: CGFloat = 0
    /// Dominant color of whichever image is showing (backdrop, or poster in the fallback
    /// header) — drives `bottomFade` here and is mirrored to `onTintChange`.
    @State private var tint: DominantTint?

    private let compactBackdropHeight: CGFloat = 260
    /// Ceiling for the backdrop at regular width. Letting 16:9 run free in a 1000pt-wide page
    /// sheet would hand back a 560pt hero and push everything else below the fold.
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
        CachedAsyncImage(url: url, onLoad: applyTint) { phase in
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
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 10, y: 6)
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

    /// Runs off the main actor (dominant-color extraction renders through a `CIContext`), then
    /// applies the result to `tint` and reports it to the presenting sheet. Animated unless
    /// Reduce Motion is on — the tint value itself is unaffected, only how it arrives.
    private func applyTint(from image: UIImage) {
        let animated = !reduceMotion
        Task.detached(priority: .utility) {
            let color = image.dominantTint()
            await MainActor.run {
                if animated {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        tint = color
                    }
                } else {
                    tint = color
                }
                onTintChange?(color)
            }
        }
    }

    /// Fades the artwork into the app background so the header has no hard edge. The middle
    /// stops blend toward the artwork's dominant color when known; the final stop is always the
    /// exact sheet background so the fade never shows a seam against it.
    private func bottomFade(height: CGFloat) -> some View {
        let base = DesignTokens.Colors.backgroundBase(for: colorScheme)
        let mid = tint.map { base.mixed(with: $0.color(for: colorScheme), amount: colorScheme == .dark ? 0.75 : 0.6) } ?? base
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0.0),
                .init(color: mid.opacity(0.45), location: 0.4),
                .init(color: mid.opacity(0.88), location: 0.75),
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
                ClampedDescriptionText(text: descriptionText)
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A soft line limit: reveal the full passage if it needs only one extra line.
/// Longer passages keep the original limit and offer expansion. Measurements share
/// the rendered font and width, so the decision adapts to Dynamic Type and iPad layouts.
struct ClampedDescriptionText: View {
    let text: String
    var lineLimit: Int = 4
    var font: Font = .body
    var color: Color = .secondary
    /// Previews inside navigation buttons get the same soft limit without a nested button.
    var allowsExpansion = true

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var relaxedHeight: CGFloat = 0

    private var needsExpansion: Bool {
        fullHeight > relaxedHeight + 1 && relaxedHeight > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            description

            if needsExpansion && allowsExpansion {
                Button(isExpanded ? "less" : "more") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(font)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(isExpanded ? "Show less description" : "Show full description")
            }
        }
        .onChange(of: text) { isExpanded = false }
    }

    private var description: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(needsExpansion && !(isExpanded && allowsExpansion) ? lineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                // Separate backgrounds prevent one measuring copy from widening the other.
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    .accessibilityHidden(true)
            }
            .background(alignment: .topLeading) {
                Text(text)
                    .font(font)
                    .lineLimit(lineLimit + 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { relaxedHeight = $0 }
                    .accessibilityHidden(true)
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
    static let list = MediaList(name: "My Watchlist", createdAt: Date.now, context: nil)

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
    let listItem: ListItem

    var body: some View {
        MediaDetailView(
            listItem: listItem,
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
