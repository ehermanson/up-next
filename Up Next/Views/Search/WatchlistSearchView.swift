import SwiftUI

struct WatchlistSearchView: View {
    enum SearchContext: Equatable {
        case all
        case tvShows
        case movies
        case specificList(CustomList)
    }

    var context: SearchContext = .all
    let existingTVShowIDs: Set<String>
    let existingMovieIDs: Set<String>
    let onTVShowAdded: (TVShow) -> Void
    let onMovieAdded: (Movie) -> Void
    var customListViewModel: CustomListViewModel?
    var libraryTVShows: [ListItem] = []
    var libraryMovies: [ListItem] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastState.self) private var toast

    @State private var searchText = ""
    @State private var selectedMediaType: MediaType
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    /// Kept per type (rather than one shared `errorMessage`) so flipping the segment can re-read
    /// the already-fetched outcome for the other type instead of re-running the search — both
    /// types are always fetched together in `performSearch`.
    @State private var tvSearchError: String?
    @State private var movieSearchError: String?
    @State private var searchTask: Task<Void, Never>?
    /// Type-namespaced IDs (see `MediaIDKey`) of titles added during this session.
    @State private var addedIDs: Set<String> = []
    @State private var tvRecommendations: [TMDBTVShowSearchResult] = []
    @State private var movieRecommendations: [TMDBMovieSearchResult] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationTask: Task<Void, Never>?
    @State private var detailListItem: ListItem?
    /// The tapped row's zoom-transition source id, captured alongside `detailListItem`.
    @State private var detailSourceID: String = ""
    @Namespace private var detailNamespace

    private let service = TMDBService.shared

    init(
        context: SearchContext = .all,
        initialMediaType: MediaType = .tvShow,
        existingTVShowIDs: Set<String>,
        existingMovieIDs: Set<String>,
        onTVShowAdded: @escaping (TVShow) -> Void,
        onMovieAdded: @escaping (Movie) -> Void,
        customListViewModel: CustomListViewModel? = nil,
        libraryTVShows: [ListItem] = [],
        libraryMovies: [ListItem] = []
    ) {
        self.context = context
        self.existingTVShowIDs = existingTVShowIDs
        self.existingMovieIDs = existingMovieIDs
        self.onTVShowAdded = onTVShowAdded
        self.onMovieAdded = onMovieAdded
        self.customListViewModel = customListViewModel
        self.libraryTVShows = libraryTVShows
        self.libraryMovies = libraryMovies
        _selectedMediaType = State(initialValue: initialMediaType)
    }

    private var showMediaTypePicker: Bool {
        switch context {
        case .all, .specificList: return true
        case .tvShows, .movies: return false
        }
    }

    private var effectiveMediaType: MediaType {
        switch context {
        case .tvShows: .tvShow
        case .movies: .movie
        case .all, .specificList: selectedMediaType
        }
    }

    private var isListMode: Bool {
        if case .specificList = context { return true }
        return false
    }

    private var selectedList: CustomList? {
        if case .specificList(let list) = context { return list }
        return nil
    }

    private var errorMessage: String? {
        effectiveMediaType == .tvShow ? tvSearchError : movieSearchError
    }

    private var hasResults: Bool {
        effectiveMediaType == .tvShow ? !tvShowResults.isEmpty : !movieResults.isEmpty
    }

    private var hasNoResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isLoading &&
        errorMessage == nil &&
        (effectiveMediaType == .tvShow ? tvShowResults.isEmpty : movieResults.isEmpty)
    }

    // MARK: - Cross-type hint

    private var otherMediaType: MediaType {
        effectiveMediaType == .tvShow ? .movie : .tvShow
    }

    /// How many results the *unselected* segment has. Both types are searched on every query,
    /// so this is always current.
    private var crossTypeResultCount: Int {
        effectiveMediaType == .tvShow ? movieResults.count : tvShowResults.count
    }

    /// Only offered when the picker is actually on screen — in a type-scoped context
    /// (`.tvShows` / `.movies`) flipping the selection would have no effect.
    private var showsCrossTypeHint: Bool {
        showMediaTypePicker && crossTypeResultCount > 0
    }

    private var crossTypeHintTitle: String {
        let count = crossTypeResultCount
        if effectiveMediaType == .tvShow {
            return "Show \(count) movie\(count == 1 ? "" : "s") instead"
        }
        return "Show \(count) TV show\(count == 1 ? "" : "s") instead"
    }

    /// Year component of a TMDB `yyyy-MM-dd` date string.
    private func year(from date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    private var navigationTitleText: String {
        if isListMode {
            if let list = selectedList {
                return "Add to \(list.name)"
            }
            return "Add to Collection"
        }
        switch context {
        case .tvShows: return "Add TV Shows"
        case .movies: return "Add Movies"
        default: return "Add to Up Next"
        }
    }

    private var emptyPromptText: String {
        if isListMode {
            return "Search to add to your collection"
        }
        switch context {
        case .tvShows: return "Search for TV shows to add"
        case .movies: return "Search for movies to add"
        default: return "Search to add to your watchlist"
        }
    }

    private func isAlreadyAdded(id: Int, mediaType: MediaType) -> Bool {
        let stringID = String(id)
        if addedIDs.contains(MediaIDKey.make(mediaType, stringID)) { return true }
        if isListMode, let list = selectedList {
            return customListViewModel?.containsItem(mediaID: stringID, mediaType: mediaType, in: list) == true
        }
        let existingIDs = mediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
        return existingIDs.contains(stringID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showMediaTypePicker {
                    Picker("Media Type", selection: $selectedMediaType) {
                        Text("TV Shows").tag(MediaType.tvShow)
                        Text("Movies").tag(MediaType.movie)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, DesignTokens.Spacing.screenInset)
                    .padding(.vertical, 8)
                }

                mainContent
            }
            .background(AppBackground())
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search…"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .onChange(of: searchText) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .onChange(of: selectedMediaType) { _, _ in
                // Both types are already fetched together in `performSearch` — flipping the
                // segment just re-reads the per-type state (`resultRows`, `errorMessage`) for the
                // other type, no refetch needed. Recommendations are fetched per-type on demand,
                // so an empty query does need a fresh load for whichever type wasn't loaded yet.
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loadRecommendations()
                }
            }
            .task {
                loadRecommendations()
            }
            .onDisappear {
                searchTask?.cancel()
                recommendationTask?.cancel()
            }
            .sheet(item: $detailListItem) { item in
                detailSheet(for: item)
            }
        }
        .toastOverlay()
    }

    private func detailSheet(for item: ListItem) -> some View {
        MediaDetailView(
            listItem: item,
            dismiss: { detailListItem = nil },
            onRemove: { detailListItem = nil },
            customListViewModel: isListMode ? nil : customListViewModel,
            onAdd: { addFromDetail(item) },
            existingIDs: allExistingIDs,
            onTVShowAdded: isListMode ? nil : { onTVShowAdded($0) },
            onMovieAdded: isListMode ? nil : { onMovieAdded($0) }
        )
        .navigationTransition(.zoom(sourceID: detailSourceID, in: detailNamespace))
    }

    /// A single stable `List` lives under `.searchable` at all times — swapping the whole
    /// scroll container per state would make the search bar jump and can drop keyboard focus.
    /// Every state below is expressed as rows inside it instead.
    private var mainContent: some View {
        List {
            mainContentRows
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    @ViewBuilder
    private var mainContentRows: some View {
        if isLoading && !hasResults {
            // Only shimmer on a cold search — otherwise keystrokes would blank the
            // previous results while the debounced request is still in flight.
            ShimmerRows()
        } else if let error = errorMessage {
            errorRow(error)
        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isLoadingRecommendations {
                ShimmerRows()
            } else if hasRecommendations {
                recommendationsSection
            } else {
                emptyPromptRow
            }
        } else if hasNoResults {
            noResultsRow
        } else {
            resultRows
        }
    }

    /// Wraps a non-row state view (an `EmptyStateView`) so it behaves like a normal `List`
    /// row: no separator/background, centered, with generous vertical breathing room. The
    /// stable `id` keeps SwiftUI from animating oddly when the state changes.
    private func emptyStateRow(id: String, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .id(id)
    }

    private func errorRow(_ message: String) -> some View {
        emptyStateRow(id: "error") {
            EmptyStateView(icon: "exclamationmark.triangle", title: message)
        }
    }

    private var emptyPromptRow: some View {
        emptyStateRow(id: "emptyPrompt") {
            EmptyStateView(icon: "magnifyingglass", title: emptyPromptText)
        }
    }

    private var noResultsRow: some View {
        emptyStateRow(id: "noResults") {
            EmptyStateView(
                icon: "magnifyingglass.circle",
                title: "No Results Found",
                subtitle: showsCrossTypeHint ? nil : "Try adjusting your search"
            ) {
                if showsCrossTypeHint {
                    Button(crossTypeHintTitle) {
                        selectedMediaType = otherMediaType
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    @ViewBuilder
    private var resultRows: some View {
        if effectiveMediaType == .tvShow {
            ForEach(tvShowResults) { result in
                SearchResultRowWithImage(
                    title: result.name,
                    overview: result.overview,
                    posterPath: result.posterPath,
                    mediaId: result.id,
                    mediaType: .tvShow,
                    isAdded: isAlreadyAdded(id: result.id, mediaType: effectiveMediaType),
                    onAdd: { addTVShow(result) },
                    onTap: { openTVShowDetail(result) },
                    voteAverage: result.voteAverage,
                    year: year(from: result.firstAirDate),
                    transitionSource: (id: MediaIDKey.make(.tvShow, result.id), namespace: detailNamespace)
                )
            }
        } else {
            ForEach(movieResults) { result in
                SearchResultRowWithImage(
                    title: result.title,
                    overview: result.overview,
                    posterPath: result.posterPath,
                    mediaId: result.id,
                    mediaType: .movie,
                    isAdded: isAlreadyAdded(id: result.id, mediaType: effectiveMediaType),
                    onAdd: { addMovie(result) },
                    onTap: { openMovieDetail(result) },
                    voteAverage: result.voteAverage,
                    year: year(from: result.releaseDate),
                    transitionSource: (id: MediaIDKey.make(.movie, result.id), namespace: detailNamespace)
                )
            }
        }
    }

    // MARK: - Recommendations

    private var hasRecommendations: Bool {
        effectiveMediaType == .tvShow ? !tvRecommendations.isEmpty : !movieRecommendations.isEmpty
    }

    private var recommendationHeaderText: String {
        if isListMode, let list = selectedList {
            return "Recommended for \(list.name)"
        }
        return "Recommended For You"
    }

    /// The heading is a plain row, not a `Section` header: `.plain` list headers pin under the
    /// nav bar and this one has no background, so scrolled rows showed through it.
    @ViewBuilder
    private var recommendationsSection: some View {
        Label(recommendationHeaderText, systemImage: "sparkles")
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .id("recommendationsHeader")

        Group {
            if effectiveMediaType == .tvShow {
                ForEach(tvRecommendations) { result in
                    SearchResultRowWithImage(
                        title: result.name,
                        overview: result.overview,
                        posterPath: result.posterPath,
                        mediaId: result.id,
                        mediaType: .tvShow,
                        isAdded: isAlreadyAdded(id: result.id, mediaType: effectiveMediaType),
                        onAdd: { addTVShow(result) },
                        onTap: { openTVShowDetail(result) },
                        voteAverage: result.voteAverage,
                        year: year(from: result.firstAirDate),
                        transitionSource: (id: MediaIDKey.make(.tvShow, result.id), namespace: detailNamespace)
                    )
                }
            } else {
                ForEach(movieRecommendations) { result in
                    SearchResultRowWithImage(
                        title: result.title,
                        overview: result.overview,
                        posterPath: result.posterPath,
                        mediaId: result.id,
                        mediaType: .movie,
                        isAdded: isAlreadyAdded(id: result.id, mediaType: effectiveMediaType),
                        onAdd: { addMovie(result) },
                        onTap: { openMovieDetail(result) },
                        voteAverage: result.voteAverage,
                        year: year(from: result.releaseDate),
                        transitionSource: (id: MediaIDKey.make(.movie, result.id), namespace: detailNamespace)
                    )
                }
            }
        }
    }

    private func loadRecommendations() {
        recommendationTask?.cancel()

        let mediaType = effectiveMediaType

        guard isListMode else {
            loadPersonalRecommendations(for: mediaType)
            return
        }

        guard let list = selectedList else {
            clearRecommendations(for: mediaType)
            isLoadingRecommendations = false
            return
        }
        let items = customListViewModel?.visibleItems(in: list) ?? list.items ?? []
        let seeds = RecommendationEngine.selectListSeeds(from: items, mediaType: mediaType)
        let existing = RecommendationEngine.existingIDs(in: items, mediaType: mediaType)
            .union(MediaIDKey.rawIDs(mediaType, in: addedIDs))
        let name = list.name
        isLoadingRecommendations = true
        recommendationTask = Task {
            if mediaType == .tvShow {
                let results = await service.collectionTVShows(name: name, seeds: seeds, excluding: existing)
                guard !Task.isCancelled else { return }
                tvRecommendations = results
            } else {
                let results = await service.collectionMovies(name: name, seeds: seeds, excluding: existing)
                guard !Task.isCancelled else { return }
                movieRecommendations = results
            }
            isLoadingRecommendations = false
        }
    }

    /// "Recommended For You": seeded by what's already on the watchlist, steered by genre taste,
    /// thumbs-down, and the user's streaming services.
    private func loadPersonalRecommendations(for mediaType: MediaType) {
        let watchlistItems = mediaType == .tvShow ? libraryTVShows : libraryMovies
        let seeds = RecommendationEngine.weightedSeeds(from: watchlistItems)
        let affinity = RecommendationEngine.genreAffinity(from: watchlistItems)
        let providerQuery = ProviderSettings.shared.watchProvidersQueryValue
        let existingIDs = mediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
        let allExisting = existingIDs.union(MediaIDKey.rawIDs(mediaType, in: addedIDs))

        // Thumbs-down seeds alone can only subtract, so they aren't enough to build a pool from.
        let hasPositiveSeed = seeds.contains { $0.weight > 0 }
        guard hasPositiveSeed || !affinity.isEmpty || providerQuery != nil else {
            clearRecommendations(for: mediaType)
            isLoadingRecommendations = false
            return
        }

        isLoadingRecommendations = true

        recommendationTask = Task {
            defer { isLoadingRecommendations = false }

            if mediaType == .tvShow {
                let results: [TMDBTVShowSearchResult] = await RecommendationEngine.fetchLibraryRecommendations(
                    seeds: seeds,
                    affinity: affinity,
                    mediaType: mediaType,
                    providerQuery: providerQuery,
                    excluding: allExisting,
                    recommendationFetcher: { try await service.fetchTVRecommendations(id: $0) },
                    discoverFetcher: { genres, providers, voteCountGte, dateLte in
                        try await service.discoverTVShows(
                            withGenres: genres,
                            withWatchProviders: providers,
                            voteCountGte: voteCountGte,
                            firstAirDateLte: dateLte
                        ).results
                    }
                )
                guard !Task.isCancelled else { return }
                tvRecommendations = results
            } else {
                let results: [TMDBMovieSearchResult] = await RecommendationEngine.fetchLibraryRecommendations(
                    seeds: seeds,
                    affinity: affinity,
                    mediaType: mediaType,
                    providerQuery: providerQuery,
                    excluding: allExisting,
                    recommendationFetcher: { try await service.fetchMovieRecommendations(id: $0) },
                    discoverFetcher: { genres, providers, voteCountGte, dateLte in
                        try await service.discoverMovies(
                            withGenres: genres,
                            withWatchProviders: providers,
                            voteCountGte: voteCountGte,
                            releaseDateLte: dateLte
                        ).results
                    }
                )
                guard !Task.isCancelled else { return }
                movieRecommendations = results
            }
        }
    }

    private func clearRecommendations(for mediaType: MediaType) {
        if mediaType == .tvShow {
            tvRecommendations = []
        } else {
            movieRecommendations = []
        }
    }

    // MARK: - Detail Sheet

    private var allExistingIDs: Set<String> {
        MediaIDKey.makeSet(.tvShow, existingTVShowIDs)
            .union(MediaIDKey.makeSet(.movie, existingMovieIDs))
            .union(addedIDs)
    }

    private func openTVShowDetail(_ result: TMDBTVShowSearchResult) {
        detailSourceID = MediaIDKey.make(.tvShow, result.id)
        let tvShow = service.mapToTVShow(result)
        detailListItem = ListItem(tvShow: tvShow)
    }

    private func openMovieDetail(_ result: TMDBMovieSearchResult) {
        detailSourceID = MediaIDKey.make(.movie, result.id)
        let movie = service.mapToMovie(result)
        detailListItem = ListItem(movie: movie)
    }

    private func addFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let stringID = media.id
        guard let intID = Int(stringID), !isAlreadyAdded(id: intID, mediaType: item.tvShow == nil ? .movie : .tvShow) else { return }
        addedIDs.insert(MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, stringID))

        if let tvShow = item.tvShow {
            if isListMode, let list = selectedList {
                customListViewModel?.addItem(tvShow: tvShow, to: list)
            } else {
                onTVShowAdded(tvShow)
            }
        } else if let movie = item.movie {
            if isListMode, let list = selectedList {
                customListViewModel?.addItem(movie: movie, to: list)
            } else {
                onMovieAdded(movie)
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch(for query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tvSearchError = nil
            movieSearchError = nil
            isLoading = false
            tvShowResults = []
            movieResults = []
            return
        }

        isLoading = true
        tvSearchError = nil
        movieSearchError = nil

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmed)
        }
    }

    /// One type's search outcome. Failures are kept per-type so a movie outage can't blank the
    /// TV results the user is actually looking at.
    private struct SearchOutcome<Element> {
        var results: [Element] = []
        var error: String?
    }

    private func fetchTVShowResults(query: String) async -> SearchOutcome<TMDBTVShowSearchResult> {
        do {
            return SearchOutcome(results: try await service.searchTVShows(query: query))
        } catch {
            return SearchOutcome(error: Self.searchErrorText(error))
        }
    }

    private func fetchMovieResults(query: String) async -> SearchOutcome<TMDBMovieSearchResult> {
        do {
            return SearchOutcome(results: try await service.searchMovies(query: query))
        } catch {
            return SearchOutcome(error: Self.searchErrorText(error))
        }
    }

    /// `nil` for cancellations — a superseded keystroke isn't a failure worth showing.
    private static func searchErrorText(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        return error.localizedDescription
    }

    private func performSearch(query: String) async {
        // Both types are searched every time so the cross-type hint ("Show 12 movies instead")
        // is accurate and flipping the segment is instant — the second request is served from
        // the response cache.
        async let tvFetch = fetchTVShowResults(query: query)
        async let movieFetch = fetchMovieResults(query: query)
        let (tv, movies) = await (tvFetch, movieFetch)

        // The shared request task isn't cancelled by us, so check explicitly after the awaits —
        // a superseded keystroke's response must not overwrite the current one.
        guard !Task.isCancelled else { return }

        // A failed type keeps its previous results rather than blanking.
        if tv.error == nil { tvShowResults = tv.results }
        if movies.error == nil { movieResults = movies.results }
        // Kept per type so flipping the segment re-reads the right banner without a refetch.
        tvSearchError = tv.error
        movieSearchError = movies.error
        isLoading = false
    }

    // MARK: - Add Actions

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        guard !isAlreadyAdded(id: result.id, mediaType: .tvShow) else { return }
        addedIDs.insert(MediaIDKey.make(.tvShow, result.id))
        toast.show("Added \(result.name)")
        Task {
            let tvShow: TVShow
            do {
                let detail = try await service.getTVShowDetails(id: result.id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow = await service.mapToTVShow(detail, providers: providers)
            } catch {
                tvShow = service.mapToTVShow(result)
            }
            if isListMode, let list = selectedList {
                customListViewModel?.addItem(tvShow: tvShow, to: list)
            } else {
                onTVShowAdded(tvShow)
            }
        }
    }

    private func addMovie(_ result: TMDBMovieSearchResult) {
        guard !isAlreadyAdded(id: result.id, mediaType: .movie) else { return }
        addedIDs.insert(MediaIDKey.make(.movie, result.id))
        toast.show("Added \(result.title)")
        Task {
            let movie: Movie
            do {
                let detail = try await service.getMovieDetails(id: result.id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie = await service.mapToMovie(detail, providers: providers)
            } catch {
                movie = service.mapToMovie(result)
            }
            if isListMode, let list = selectedList {
                customListViewModel?.addItem(movie: movie, to: list)
            } else {
                onMovieAdded(movie)
            }
        }
    }
}
