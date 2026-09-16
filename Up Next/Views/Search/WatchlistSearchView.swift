import SwiftUI

struct WatchlistSearchView: View {
    enum SearchContext: Equatable {
        case all
        case tvShows
        case movies
        case myLists
        case specificList(CustomList)
    }

    var context: SearchContext = .all
    let existingTVShowIDs: Set<String>
    let existingMovieIDs: Set<String>
    let onTVShowAdded: (TVShow) -> Void
    let onMovieAdded: (Movie) -> Void
    var customListViewModel: CustomListViewModel?
    var onDone: (() -> Void)?
    var libraryTVShows: [ListItem] = []
    var libraryMovies: [ListItem] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastState.self) private var toast

    @State private var searchText = ""
    @State private var selectedMediaType: MediaType = .tvShow
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    /// Type-namespaced IDs (see `MediaIDKey`) of titles added during this session.
    @State private var addedIDs: Set<String> = []
    @State private var selectedListID: UUID?
    @State private var tvRecommendations: [TMDBTVShowSearchResult] = []
    @State private var movieRecommendations: [TMDBMovieSearchResult] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationTask: Task<Void, Never>?
    @State private var detailListItem: ListItem?

    private let service = TMDBService.shared

    private var showMediaTypePicker: Bool {
        switch context {
        case .all, .myLists, .specificList: return true
        case .tvShows, .movies: return false
        }
    }

    private var effectiveMediaType: MediaType {
        switch context {
        case .tvShows: .tvShow
        case .movies: .movie
        case .all, .myLists, .specificList: selectedMediaType
        }
    }

    private var isListMode: Bool {
        switch context {
        case .myLists, .specificList: return true
        default: return false
        }
    }

    private var hasScopedList: Bool {
        switch context {
        case .specificList: return true
        default: return customListViewModel?.activeListID != nil
        }
    }

    private var selectedList: CustomList? {
        switch context {
        case .specificList(let list):
            return list
        default:
            guard let id = selectedListID else { return nil }
            return customListViewModel?.customLists.first(where: { $0.id == id })
        }
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
        default: return "Add to Watchlist"
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

    private func isAlreadyAdded(id: Int) -> Bool {
        let stringID = String(id)
        if isListMode, let list = selectedList {
            return customListViewModel?.containsItem(mediaID: stringID, in: list) == true
        }
        let existingIDs = effectiveMediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
        return existingIDs.contains(stringID) || addedIDs.contains(MediaIDKey.make(effectiveMediaType, stringID))
    }

    private func performDone() {
        if let onDone {
            onDone()
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if context == .myLists && !hasScopedList {
                    listPickerSection
                }

                if showMediaTypePicker {
                    Picker("Media Type", selection: $selectedMediaType) {
                        Text("TV Shows").tag(MediaType.tvShow)
                        Text("Movies").tag(MediaType.movie)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                mainContent
            }
            .background(AppBackground())
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { performDone() }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search..."
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .onChange(of: searchText) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .onChange(of: selectedMediaType) { _, _ in
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(for: searchText)
                } else {
                    loadRecommendations()
                }
            }
            .onChange(of: context) { _, _ in
                resetSearch()
                syncActiveList()
            }
            .onChange(of: selectedListID) { _, _ in
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                loadRecommendations()
            }
            .onChange(of: addedIDs) { _, _ in
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                loadRecommendations()
            }
            .onAppear {
                syncActiveList()
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
            listItem: detailBinding(for: item),
            dismiss: { detailListItem = nil },
            onRemove: { detailListItem = nil },
            customListViewModel: isListMode ? nil : customListViewModel,
            onAdd: { addFromDetail(item) },
            existingIDs: allExistingIDs,
            onTVShowAdded: isListMode ? nil : { onTVShowAdded($0) },
            onMovieAdded: isListMode ? nil : { onMovieAdded($0) }
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        if context == .myLists && selectedList == nil {
            noListSelectedView
        } else if isLoading && !hasResults {
            // Only shimmer on a cold search — otherwise keystrokes would blank the
            // previous results while the debounced request is still in flight.
            ShimmerLoadingView()
        } else if let error = errorMessage {
            EmptyStateView(icon: "exclamationmark.triangle", title: error)
        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isLoadingRecommendations {
                ShimmerLoadingView()
            } else if hasRecommendations {
                recommendationsList
            } else {
                EmptyStateView(icon: "magnifyingglass", title: emptyPromptText)
            }
        } else if hasNoResults {
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
        } else {
            searchResultsList
        }
    }

    @ViewBuilder
    private var listPickerSection: some View {
        let lists = customListViewModel?.customLists ?? []
        if lists.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(lists, id: \.id) { list in
                        Button {
                            selectedListID = list.id
                        } label: {
                            Chip(icon: list.iconName, text: list.name, isEmphasized: selectedListID == list.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var noListSelectedView: some View {
        let lists = customListViewModel?.customLists ?? []
        if lists.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "Create a collection first",
                subtitle: "Go to the Collections tab to create one."
            )
        } else {
            EmptyStateView(icon: "tray", title: "Select a collection above")
        }
    }

    private var searchResultsList: some View {
        List {
            if effectiveMediaType == .tvShow {
                ForEach(tvShowResults) { result in
                    SearchResultRowWithImage(
                        title: result.name,
                        overview: result.overview,
                        posterPath: result.posterPath,
                        mediaId: result.id,
                        mediaType: .tvShow,
                        isAdded: isAlreadyAdded(id: result.id),
                        onAdd: { addTVShow(result) },
                        onTap: { openTVShowDetail(result) },
                        voteAverage: result.voteAverage,
                        year: year(from: result.firstAirDate)
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
                        isAdded: isAlreadyAdded(id: result.id),
                        onAdd: { addMovie(result) },
                        onTap: { openMovieDetail(result) },
                        voteAverage: result.voteAverage,
                        year: year(from: result.releaseDate)
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
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

    private var recommendationsList: some View {
        List {
            Section {
                if effectiveMediaType == .tvShow {
                    ForEach(tvRecommendations) { result in
                        SearchResultRowWithImage(
                            title: result.name,
                            overview: result.overview,
                            posterPath: result.posterPath,
                            mediaId: result.id,
                            mediaType: .tvShow,
                            isAdded: isAlreadyAdded(id: result.id),
                            onAdd: { addTVShow(result) },
                            onTap: { openTVShowDetail(result) },
                            voteAverage: result.voteAverage,
                            year: year(from: result.firstAirDate)
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
                            isAdded: isAlreadyAdded(id: result.id),
                            onAdd: { addMovie(result) },
                            onTap: { openMovieDetail(result) },
                            voteAverage: result.voteAverage,
                            year: year(from: result.releaseDate)
                        )
                    }
                }
            } header: {
                Label(recommendationHeaderText, systemImage: "sparkles")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func loadRecommendations() {
        recommendationTask?.cancel()

        let mediaType = effectiveMediaType
        let seeds: [Int]
        let allExisting: Set<String>
        let listName: String?

        if isListMode {
            guard let list = selectedList else {
                clearRecommendations(for: mediaType)
                isLoadingRecommendations = false
                return
            }

            let listItems = list.items ?? []
            seeds = RecommendationEngine.selectListSeeds(from: listItems, mediaType: mediaType)
            allExisting = RecommendationEngine.existingIDs(in: listItems, mediaType: mediaType)
                .union(MediaIDKey.rawIDs(mediaType, in: addedIDs))
            listName = list.name
        } else {
            let libraryItems = mediaType == .tvShow ? libraryTVShows : libraryMovies
            seeds = RecommendationEngine.selectSeeds(from: libraryItems)
            let existingIDs = mediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
            allExisting = existingIDs.union(MediaIDKey.rawIDs(mediaType, in: addedIDs))
            listName = nil
        }

        guard !seeds.isEmpty else {
            let keywords = RecommendationEngine.thematicKeywords(for: listName)
            guard isListMode, let name = listName, !keywords.isEmpty else {
                clearRecommendations(for: mediaType)
                isLoadingRecommendations = false
                return
            }

            let query = RecommendationEngine.thematicSearchQuery(for: name)
            guard !query.isEmpty else {
                clearRecommendations(for: mediaType)
                isLoadingRecommendations = false
                return
            }

            isLoadingRecommendations = true
            recommendationTask = Task {
                defer { isLoadingRecommendations = false }
                if mediaType == .tvShow {
                    let results = await RecommendationEngine.searchThematicResults(
                        query: query,
                        excluding: allExisting,
                        thematicKeywords: keywords
                    ) { try await service.searchTVShows(query: $0) }
                    guard !Task.isCancelled else { return }
                    tvRecommendations = results
                } else {
                    let results = await RecommendationEngine.searchThematicResults(
                        query: query,
                        excluding: allExisting,
                        thematicKeywords: keywords
                    ) { try await service.searchMovies(query: $0) }
                    guard !Task.isCancelled else { return }
                    movieRecommendations = results
                }
            }
            return
        }

        let minimumFrequency = RecommendationEngine.minimumFrequency(seedCount: seeds.count, isListMode: isListMode)
        let keywords = RecommendationEngine.thematicKeywords(for: listName)
        isLoadingRecommendations = true

        recommendationTask = Task {
            defer { isLoadingRecommendations = false }

            if mediaType == .tvShow {
                let results: [TMDBTVShowSearchResult] = await RecommendationEngine.fetchRecommendations(
                    seeds: seeds,
                    excluding: allExisting,
                    minimumFrequency: minimumFrequency,
                    thematicKeywords: keywords
                ) { id in
                    (try? await service.fetchTVRecommendations(id: id)) ?? []
                }
                guard !Task.isCancelled else { return }
                tvRecommendations = results
            } else {
                let results: [TMDBMovieSearchResult] = await RecommendationEngine.fetchRecommendations(
                    seeds: seeds,
                    excluding: allExisting,
                    minimumFrequency: minimumFrequency,
                    thematicKeywords: keywords
                ) { id in
                    (try? await service.fetchMovieRecommendations(id: id)) ?? []
                }
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
        let tvShow = service.mapToTVShow(result)
        detailListItem = ListItem(tvShow: tvShow)
    }

    private func openMovieDetail(_ result: TMDBMovieSearchResult) {
        let movie = service.mapToMovie(result)
        detailListItem = ListItem(movie: movie)
    }

    private func addFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let stringID = media.id
        guard let intID = Int(stringID), !isAlreadyAdded(id: intID) else { return }
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

    private func detailBinding(for item: ListItem) -> Binding<ListItem> {
        Binding(
            get: { detailListItem ?? item },
            set: { detailListItem = $0 }
        )
    }

    // MARK: - Search

    private func syncActiveList() {
        switch context {
        case .specificList(let list):
            selectedListID = list.id
        case .myLists:
            if let activeID = customListViewModel?.activeListID {
                selectedListID = activeID
            }
        default:
            break
        }
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchText = ""
        tvShowResults = []
        movieResults = []
        isLoading = false
        errorMessage = nil
        addedIDs = []
        selectedListID = nil
    }

    private func scheduleSearch(for query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = nil
            isLoading = false
            tvShowResults = []
            movieResults = []
            return
        }

        isLoading = true
        errorMessage = nil

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
        // Only the type on screen gets to raise the error banner.
        errorMessage = effectiveMediaType == .tvShow ? tv.error : movies.error
        isLoading = false
    }

    // MARK: - Add Actions

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        guard !isAlreadyAdded(id: result.id) else { return }
        addedIDs.insert(MediaIDKey.make(.tvShow, result.id))
        toast.show("\(result.name) has been added")
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
        guard !isAlreadyAdded(id: result.id) else { return }
        addedIDs.insert(MediaIDKey.make(.movie, result.id))
        toast.show("\(result.title) has been added")
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
