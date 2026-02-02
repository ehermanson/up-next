import SwiftData
import SwiftUI

enum MediaType: Identifiable {
    case tvShow
    case movie

    var id: Self { self }
}

struct SearchView: View {
    let mediaType: MediaType
    let existingIDs: Set<String>
    let onTVShowAdded: ((TVShow) -> Void)?
    let onMovieAdded: ((Movie) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchFieldPresented = true
    @State private var addedIDs: Set<String> = []

    init(
        mediaType: MediaType,
        existingIDs: Set<String> = [],
        onTVShowAdded: ((TVShow) -> Void)? = nil,
        onMovieAdded: ((Movie) -> Void)? = nil,
        initialSearchText: String = "",
        initialTVResults: [TMDBTVShowSearchResult] = [],
        initialMovieResults: [TMDBMovieSearchResult] = []
    ) {
        self.mediaType = mediaType
        self.existingIDs = existingIDs
        self.onTVShowAdded = onTVShowAdded
        self.onMovieAdded = onMovieAdded
        _searchText = State(initialValue: initialSearchText)
        _tvShowResults = State(initialValue: initialTVResults)
        _movieResults = State(initialValue: initialMovieResults)
    }

    private func isAlreadyAdded(id: Int) -> Bool {
        let stringID = String(id)
        return existingIDs.contains(stringID) || addedIDs.contains(stringID)
    }

    private var service: TMDBService {
        TMDBService.shared
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ShimmerLoadingView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .background(AppBackground())
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, height: 80)
                            .glassEffect(.regular, in: .circle)
                        Text("Search for \(mediaType == .tvShow ? "TV shows" : "movies")")
                            .font(.title3)
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppBackground())
                } else {
                    GlassEffectContainer(spacing: 8) {
                        List {
                            if mediaType == .tvShow {
                                ForEach(tvShowResults) { result in
                                    SearchResultRowWithImage(
                                        title: result.name,
                                        overview: result.overview,
                                        posterPath: result.posterPath,
                                        isAdded: isAlreadyAdded(id: result.id),
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
                                        isAdded: isAlreadyAdded(id: result.id),
                                        onAdd: {
                                            addMovie(result)
                                        }
                                    )
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                    .background(AppBackground())
                }
            }
            .navigationTitle("Search \(mediaType == .tvShow ? "TV Shows" : "Movies")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
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
                tvShowResults = try await service.searchTVShows(query: query)
            } else {
                movieResults = try await service.searchMovies(query: query)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func addTVShow(_ result: TMDBTVShowSearchResult) {
        guard !isAlreadyAdded(id: result.id) else { return }
        addedIDs.insert(String(result.id))
        Task {
            let tvShow: TVShow
            do {
                let detail = try await service.getTVShowDetails(id: result.id)
                tvShow = service.mapToTVShow(detail)
            } catch {
                tvShow = service.mapToTVShow(result)
            }
            onTVShowAdded?(tvShow)
        }
    }

    private func addMovie(_ result: TMDBMovieSearchResult) {
        guard !isAlreadyAdded(id: result.id) else { return }
        addedIDs.insert(String(result.id))
        Task {
            let movie: Movie
            do {
                async let detailTask = service.getMovieDetails(id: result.id)
                async let providersTask = service.getMovieWatchProviders(
                    id: result.id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                movie = service.mapToMovie(detail, providers: providers)
            } catch {
                movie = service.mapToMovie(result)
            }
            onMovieAdded?(movie)
        }
    }
}

private struct ShimmerLoadingView: View {
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 12) {
                        Color.clear
                            .frame(width: 60, height: 90)
                            .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 8) {
                            Color.clear
                                .frame(height: 16)
                                .frame(maxWidth: 180)
                                .glassEffect(.regular, in: .capsule)
                            Color.clear
                                .frame(height: 12)
                                .frame(maxWidth: 240)
                                .glassEffect(.regular, in: .capsule)
                            Color.clear
                                .frame(height: 12)
                                .frame(maxWidth: 200)
                                .glassEffect(.regular, in: .capsule)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .overlay(
            LinearGradient(
                colors: [
                    .clear,
                    Color.white.opacity(0.08),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .offset(x: shimmerOffset)
        )
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
}

struct SearchResultRowWithImage: View {
    let title: String
    let overview: String?
    let posterPath: String?
    let isAdded: Bool
    let onAdd: () -> Void

    @State private var imageURL: URL?
    private let service = TMDBService.shared

    var body: some View {
        SearchResultRow(
            title: title,
            overview: overview,
            imageURL: imageURL,
            isAdded: isAdded,
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
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        Button {
            if !isAdded {
                onAdd()
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                            .clipped()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                    @unknown default:
                        EmptyView()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .lineLimit(2)

                    if let overview = overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer()

                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Already added")
                } else {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Add to list")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 20))
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
                onTVShowAdded: { _ in },
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
                onMovieAdded: { _ in },
                initialSearchText: "Dune",
                initialMovieResults: SearchViewPreviewData.movies
            )
        }
        .preferredColorScheme(.dark)
    }
#endif
