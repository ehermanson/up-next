import SwiftData
import SwiftUI

enum MediaType: Identifiable {
    case tvShow
    case movie

    var id: Self { self }
}

struct SearchView: View {
    let mediaType: MediaType
    let onItemAdded: (ListItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchFieldPresented = true

    init(
        mediaType: MediaType,
        onItemAdded: @escaping (ListItem) -> Void,
        initialSearchText: String = "",
        initialTVResults: [TMDBTVShowSearchResult] = [],
        initialMovieResults: [TMDBMovieSearchResult] = []
    ) {
        self.mediaType = mediaType
        self.onItemAdded = onItemAdded
        _searchText = State(initialValue: initialSearchText)
        _tvShowResults = State(initialValue: initialTVResults)
        _movieResults = State(initialValue: initialMovieResults)
    }

    private var service: TMDBService {
        TMDBService.shared
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView("Searching...")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Search for \(mediaType == .tvShow ? "TV shows" : "movies")")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if mediaType == .tvShow {
                            ForEach(tvShowResults) { result in
                                SearchResultRowWithImage(
                                    title: result.name,
                                    overview: result.overview,
                                    posterPath: result.posterPath,
                                    onAdd: {
                                        addTVShow(result)
                                    }
                                )
                            }
                        } else {
                            ForEach(movieResults) { result in
                                SearchResultRowWithImage(
                                    title: result.title,
                                    overview: result.overview,
                                    posterPath: result.posterPath,
                                    onAdd: {
                                        addMovie(result)
                                    }
                                )
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search \(mediaType == .tvShow ? "TV Shows" : "Movies")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchFieldPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search..."
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .onChange(of: searchText) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .onAppear {
                isSearchFieldPresented = true
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(for: searchText)
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
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
            if mediaType == .tvShow {
                let results = try await service.searchTVShows(query: query)
                await MainActor.run {
                    tvShowResults = results
                    isLoading = false
                }
            } else {
                let results = try await service.searchMovies(query: query)
                await MainActor.run {
                    movieResults = results
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        Task {
            do {
                // Fetch full details for better data
                let detail = try await service.getTVShowDetails(id: result.id)
                let tvShow = await service.mapToTVShow(detail)

                // Create a stub user and list for the ListItem
                // These will be replaced by the actual values in ContentView
                let stubUser = UserIdentity(id: "current-user", displayName: "Current User")
                let stubList = MediaList(name: "Temp", createdBy: stubUser, createdAt: Date())

                let listItem = ListItem(
                    tvShow: tvShow,
                    list: stubList,
                    addedBy: stubUser,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 0
                )

                await MainActor.run {
                    onItemAdded(listItem)
                    dismiss()
                }
            } catch {
                // If detail fetch fails, use search result data
                let tvShow = await service.mapToTVShow(result)
                let stubUser = UserIdentity(id: "current-user", displayName: "Current User")
                let stubList = MediaList(name: "Temp", createdBy: stubUser, createdAt: Date())

                let listItem = ListItem(
                    tvShow: tvShow,
                    list: stubList,
                    addedBy: stubUser,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 0
                )

                await MainActor.run {
                    onItemAdded(listItem)
                    dismiss()
                }
            }
        }
    }

    private func addMovie(_ result: TMDBMovieSearchResult) {
        Task {
            do {
                // Fetch full details and watch providers for richer data
                async let detailTask = service.getMovieDetails(id: result.id)
                async let providersTask = service.getMovieWatchProviders(
                    id: result.id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                let movie = await service.mapToMovie(detail, providers: providers)

                // Create a stub user and list for the ListItem
                // These will be replaced by the actual values in ContentView
                let stubUser = UserIdentity(id: "current-user", displayName: "Current User")
                let stubList = MediaList(name: "Temp", createdBy: stubUser, createdAt: Date())

                let listItem = ListItem(
                    movie: movie,
                    list: stubList,
                    addedBy: stubUser,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 0
                )

                await MainActor.run {
                    onItemAdded(listItem)
                    dismiss()
                }
            } catch {
                // If detail fetch fails, fall back to search result data
                let movie = await service.mapToMovie(result)
                let stubUser = UserIdentity(id: "current-user", displayName: "Current User")
                let stubList = MediaList(name: "Temp", createdBy: stubUser, createdAt: Date())

                let listItem = ListItem(
                    movie: movie,
                    list: stubList,
                    addedBy: stubUser,
                    addedAt: Date(),
                    isWatched: false,
                    watchedAt: nil,
                    order: 0
                )

                await MainActor.run {
                    onItemAdded(listItem)
                    dismiss()
                }
            }
        }
    }
}

struct SearchResultRowWithImage: View {
    let title: String
    let overview: String?
    let posterPath: String?
    let onAdd: () -> Void

    @State private var imageURL: URL?
    private let service = TMDBService.shared

    var body: some View {
        SearchResultRow(
            title: title,
            overview: overview,
            imageURL: imageURL,
            onAdd: onAdd
        )
        .task {
            if let path = posterPath {
                let url = service.imageURL(path: path)
                imageURL = url
            }
        }
    }
}

struct SearchResultRow: View {
    let title: String
    let overview: String?
    let imageURL: URL?
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 60, height: 90)
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 90)
                        .clipShape(.rect(cornerRadius: 8))
                        .clipped()
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 60, height: 90)
                @unknown default:
                    EmptyView()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                if let overview = overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add to list")
            .buttonStyle(LiquidGlassCircleButtonStyle())
            .contentShape(Circle())
            .hoverEffect(.lift)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
    private enum SearchViewPreviewData {
        static let tvShows: [TMDBTVShowSearchResult] = [
            TMDBTVShowSearchResult(
                id: 1,
                name: "Severance",
                overview:
                    "A mysterious workplace drama where memories are split between work and home.",
                posterPath: "/fxywKYcFh8JVulZqVJ8I9nukN1y.jpg",
                backdropPath: "/xMI7YzqZ77N8DfszT8Z5ANxTHnQ.jpg",
                firstAirDate: "2022-02-18",
                voteAverage: 8.4
            ),
            TMDBTVShowSearchResult(
                id: 2,
                name: "The Bear",
                overview:
                    "A fine-dining chef returns to run his family's sandwich shop in Chicago.",
                posterPath: "/gMDhSl30Y2v3HRk3T9bTN7mAMvI.jpg",
                backdropPath: "/r4Fke2wzq8pt5TRbUDRkqRAi4Kk.jpg",
                firstAirDate: "2022-06-23",
                voteAverage: 8.3
            ),
        ]

        static let movies: [TMDBMovieSearchResult] = [
            TMDBMovieSearchResult(
                id: 101,
                title: "Dune: Part Two",
                overview: "Paul unites with the Fremen to wage war against House Harkonnen.",
                posterPath: "/8b8R8l88Qje9dn9OE8PY05Nxl1X.jpg",
                backdropPath: "/dZbLqRjjiiNCpTYzhzL2NMvz4J0.jpg",
                releaseDate: "2024-03-01",
                voteAverage: 8.7
            ),
            TMDBMovieSearchResult(
                id: 102,
                title: "Everything Everywhere All at Once",
                overview:
                    "An unlikely hero must channel newfound powers to fight bewildering dangers.",
                posterPath: "/w3LxiVYdWWRvEVdn5RYq6jIqkb1.jpg",
                backdropPath: "/t1OSBIh1THQ2QxZYM6eZ6JhcSlY.jpg",
                releaseDate: "2022-03-24",
                voteAverage: 7.9
            ),
        ]
    }

    #Preview("TV Shows") {
        NavigationStack {
            SearchView(
                mediaType: .tvShow,
                onItemAdded: { _ in },
                initialSearchText: "Sev",
                initialTVResults: SearchViewPreviewData.tvShows
            )
        }
        .preferredColorScheme(.dark)
    }

    #Preview("Movies") {
        NavigationStack {
            SearchView(
                mediaType: .movie,
                onItemAdded: { _ in },
                initialSearchText: "Dune",
                initialMovieResults: SearchViewPreviewData.movies
            )
        }
        .preferredColorScheme(.dark)
    }
#endif
