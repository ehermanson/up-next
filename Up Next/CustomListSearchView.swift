import SwiftUI

struct CustomListSearchView: View {
    let viewModel: CustomListViewModel
    let list: CustomList
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedMediaType: MediaType = .movie
    @State private var tvShowResults: [TMDBTVShowSearchResult] = []
    @State private var movieResults: [TMDBMovieSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchFieldPresented = true

    private let service = TMDBService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Media Type", selection: $selectedMediaType) {
                    Text("Movies").tag(MediaType.movie)
                    Text("TV Shows").tag(MediaType.tvShow)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Group {
                    if isLoading {
                        VStack {
                            ProgressView()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text(error)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, height: 80)
                                .glassEffect(.regular, in: .circle)
                            Text("Search for \(selectedMediaType == .tvShow ? "TV shows" : "movies") to add")
                                .font(.title3)
                                .fontDesign(.rounded)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GlassEffectContainer(spacing: 8) {
                            List {
                                if selectedMediaType == .tvShow {
                                    ForEach(tvShowResults) { result in
                                        let isInList = viewModel.containsItem(mediaID: String(result.id), in: list)
                                        SearchResultRowWithImage(
                                            title: result.name,
                                            overview: result.overview,
                                            posterPath: result.posterPath,
                                            isAdded: isInList,
                                            onAdd: { addTVShow(result) }
                                        )
                                    }
                                } else {
                                    ForEach(movieResults) { result in
                                        let isInList = viewModel.containsItem(mediaID: String(result.id), in: list)
                                        SearchResultRowWithImage(
                                            title: result.title,
                                            overview: result.overview,
                                            posterPath: result.posterPath,
                                            isAdded: isInList,
                                            onAdd: { addMovie(result) }
                                        )
                                    }
                                }
                            }
                            .scrollContentBackground(.hidden)
                            .listStyle(.plain)
                        }
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle("Add to \(list.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
            .onChange(of: selectedMediaType) { _, _ in
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(for: searchText)
                }
            }
            .onAppear {
                isSearchFieldPresented = true
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
            if selectedMediaType == .tvShow {
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
        guard !viewModel.containsItem(mediaID: String(result.id), in: list) else { return }
        Task {
            let tvShow: TVShow
            do {
                let detail = try await service.getTVShowDetails(id: result.id)
                tvShow = service.mapToTVShow(detail)
            } catch {
                tvShow = service.mapToTVShow(result)
            }
            viewModel.addItem(tvShow: tvShow, to: list)
        }
    }

    private func addMovie(_ result: TMDBMovieSearchResult) {
        guard !viewModel.containsItem(mediaID: String(result.id), in: list) else { return }
        Task {
            let movie: Movie
            do {
                async let detailTask = service.getMovieDetails(id: result.id)
                async let providersTask = service.getMovieWatchProviders(id: result.id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                movie = service.mapToMovie(detail, providers: providers)
            } catch {
                movie = service.mapToMovie(result)
            }
            viewModel.addItem(movie: movie, to: list)
        }
    }
}
