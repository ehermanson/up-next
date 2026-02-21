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
    var onItemAdded: ((String) -> Void)?
    var libraryTVShows: [ListItem] = []
    var libraryMovies: [ListItem] = []

    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedMediaType: MediaType = .tvShow
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var addedIDs: Set<String> = []
    @State private var selectedListID: UUID?
    @State private var tvRecommendations: [TMDBTVShowSearchResult] = []
    @State private var movieRecommendations: [TMDBMovieSearchResult] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationTask: Task<Void, Never>?

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

    private var hasNoResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isLoading &&
        errorMessage == nil &&
        (effectiveMediaType == .tvShow ? tvShowResults.isEmpty : movieResults.isEmpty)
    }

    private var navigationTitleText: String {
        if isListMode {
            if let list = selectedList {
                return "Add to \(list.name)"
            }
            return "Add to List"
        }
        switch context {
        case .tvShows: return "Add TV Shows"
        case .movies: return "Add Movies"
        default: return "Add to Watchlist"
        }
    }

    private var emptyPromptText: String {
        if isListMode {
            return "Search to add to your list"
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
        return existingIDs.contains(stringID) || addedIDs.contains(stringID)
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

                Group {
                    if context == .myLists && selectedList == nil {
                        noListSelectedView
                    } else if isLoading {
                        ShimmerLoadingView()
                            .background(AppBackground())
                    } else if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                                .frame(width: 80, height: 80)
                                .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .circle)
                            Text(error)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !isListMode && isLoadingRecommendations {
                            ShimmerLoadingView()
                                .background(AppBackground())
                        } else if !isListMode && hasRecommendations {
                            recommendationsList
                        } else {
                            EmptyStateView(icon: "magnifyingglass", title: emptyPromptText)
                        }
                    } else if hasNoResults {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, height: 80)
                                .glassEffect(.regular, in: .circle)
                            Text("No Results Found")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .fontDesign(.rounded)
                                .foregroundStyle(.primary)
                            Text("Try adjusting your search")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fontDesign(.rounded)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        searchResultsList
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
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
                            HStack(spacing: 6) {
                                Image(systemName: list.iconName)
                                    .font(.caption)
                                Text(list.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(
                                selectedListID == list.id
                                    ? .regular.tint(.indigo.opacity(0.4))
                                    : .regular,
                                in: .capsule
                            )
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
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 80, height: 80)
                .glassEffect(.regular, in: .circle)
            if lists.isEmpty {
                Text("Create a list first")
                    .font(.title3)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
                Text("Go to My Lists to create a collection.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Select a list above")
                    .font(.title3)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchResultsList: some View {
        GlassEffectContainer(spacing: 8) {
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
                            voteAverage: result.voteAverage
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
                            voteAverage: result.voteAverage
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
        }
    }

    // MARK: - Recommendations

    private var hasRecommendations: Bool {
        effectiveMediaType == .tvShow ? !tvRecommendations.isEmpty : !movieRecommendations.isEmpty
    }

    private var recommendationsList: some View {
        GlassEffectContainer(spacing: 8) {
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
                                voteAverage: result.voteAverage
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
                                voteAverage: result.voteAverage
                            )
                        }
                    }
                } header: {
                    Label("Recommended For You", systemImage: "sparkles")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
        }
    }

    private func loadRecommendations() {
        guard !isListMode else { return }

        let libraryItems = effectiveMediaType == .tvShow ? libraryTVShows : libraryMovies
        guard !libraryItems.isEmpty else { return }

        recommendationTask?.cancel()
        isLoadingRecommendations = true

        recommendationTask = Task {
            defer { isLoadingRecommendations = false }

            let seeds = selectSeeds(from: libraryItems)
            guard !seeds.isEmpty, !Task.isCancelled else { return }

            let existingIDs = effectiveMediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
            let allExisting = existingIDs.union(addedIDs)

            if effectiveMediaType == .tvShow {
                let results = await fetchTVRecommendations(seeds: seeds, excluding: allExisting)
                guard !Task.isCancelled else { return }
                tvRecommendations = results
            } else {
                let results = await fetchMovieRecommendations(seeds: seeds, excluding: allExisting)
                guard !Task.isCancelled else { return }
                movieRecommendations = results
            }
        }
    }

    private func selectSeeds(from items: [ListItem]) -> [Int] {
        // Priority 1: Thumbs-up rated items (strongest quality signal for "more like this")
        let thumbsUp = items
            .filter { $0.userRating == 1 }
            .sorted { $0.addedAt > $1.addedAt }

        // Priority 2: Recently added unwatched items (current-interest signal)
        let unwatched = items
            .filter { !$0.isWatched && $0.userRating != 1 }
            .sorted { $0.addedAt > $1.addedAt }

        // Priority 3: Recently watched items (fallback)
        let recentlyWatched = items
            .filter { $0.isWatched && $0.userRating != 1 }
            .sorted { ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast) }

        var seeds: [Int] = []
        var seenIDs = Set<String>()

        for item in thumbsUp + unwatched + recentlyWatched {
            guard seeds.count < 5 else { break }
            guard let id = item.media?.id, !seenIDs.contains(id), let intID = Int(id) else { continue }
            seenIDs.insert(id)
            seeds.append(intID)
        }

        return seeds
    }

    private func fetchTVRecommendations(seeds: [Int], excluding existingIDs: Set<String>) async -> [TMDBTVShowSearchResult] {
        var allResults: [TMDBTVShowSearchResult] = []

        await withTaskGroup(of: [TMDBTVShowSearchResult].self) { group in
            for seedID in seeds {
                group.addTask {
                    (try? await service.fetchTVRecommendations(id: seedID)) ?? []
                }
            }
            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        return aggregateTV(allResults, excluding: existingIDs)
    }

    private func fetchMovieRecommendations(seeds: [Int], excluding existingIDs: Set<String>) async -> [TMDBMovieSearchResult] {
        var allResults: [TMDBMovieSearchResult] = []

        await withTaskGroup(of: [TMDBMovieSearchResult].self) { group in
            for seedID in seeds {
                group.addTask {
                    (try? await service.fetchMovieRecommendations(id: seedID)) ?? []
                }
            }
            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        return aggregateMovies(allResults, excluding: existingIDs)
    }

    private func aggregateTV(_ results: [TMDBTVShowSearchResult], excluding existingIDs: Set<String>) -> [TMDBTVShowSearchResult] {
        var frequency: [Int: Int] = [:]
        var bestByID: [Int: TMDBTVShowSearchResult] = [:]

        for result in results {
            guard !existingIDs.contains(String(result.id)) else { continue }
            guard (result.voteAverage ?? 0) >= 6.0 else { continue }
            frequency[result.id, default: 0] += 1
            if bestByID[result.id] == nil {
                bestByID[result.id] = result
            }
        }

        return bestByID.values
            .sorted { a, b in
                let freqA = frequency[a.id] ?? 0
                let freqB = frequency[b.id] ?? 0
                if freqA != freqB { return freqA > freqB }
                return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
            }
            .prefix(20)
            .map { $0 }
    }

    private func aggregateMovies(_ results: [TMDBMovieSearchResult], excluding existingIDs: Set<String>) -> [TMDBMovieSearchResult] {
        var frequency: [Int: Int] = [:]
        var bestByID: [Int: TMDBMovieSearchResult] = [:]

        for result in results {
            guard !existingIDs.contains(String(result.id)) else { continue }
            guard (result.voteAverage ?? 0) >= 6.0 else { continue }
            frequency[result.id, default: 0] += 1
            if bestByID[result.id] == nil {
                bestByID[result.id] = result
            }
        }

        return bestByID.values
            .sorted { a, b in
                let freqA = frequency[a.id] ?? 0
                let freqB = frequency[b.id] ?? 0
                if freqA != freqB { return freqA > freqB }
                return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
            }
            .prefix(20)
            .map { $0 }
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
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmed)
        }
    }

    private func performSearch(query: String) async {
        do {
            if effectiveMediaType == .tvShow {
                tvShowResults = try await service.searchTVShows(query: query)
            } else {
                movieResults = try await service.searchMovies(query: query)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Add Actions

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        guard !isAlreadyAdded(id: result.id) else { return }
        addedIDs.insert(String(result.id))
        onItemAdded?(result.name)
        Task {
            let tvShow: TVShow
            do {
                let detail = try await service.getTVShowDetails(id: result.id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow = service.mapToTVShow(detail, providers: providers)
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
        addedIDs.insert(String(result.id))
        onItemAdded?(result.title)
        Task {
            let movie: Movie
            do {
                let detail = try await service.getMovieDetails(id: result.id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie = service.mapToMovie(detail, providers: providers)
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
