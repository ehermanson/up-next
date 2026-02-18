import SwiftData
import SwiftUI

struct ContentView: View {
    private enum MediaTab: Hashable {
        case tvShows
        case movies
        case myLists
        case discover
        case search
    }

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MediaLibraryViewModel()
    @State private var customListViewModel = CustomListViewModel()

    @State private var expandedTVShowID: String? = nil
    @State private var expandedMovieID: String? = nil
    @State private var selectedTab: MediaTab = .tvShows
    @State private var previousTab: MediaTab = .tvShows
    @State private var selectedTVGenre: String? = nil
    @State private var selectedMovieGenre: String? = nil
    @State private var selectedTVProviderCategory: String? = nil
    @State private var selectedMovieProviderCategory: String? = nil
    @State private var showingSettings = false

    @State private var toastMessage: String?

    private var selectedTVShow: ListItem? {
        guard let id = expandedTVShowID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    private var selectedMovie: ListItem? {
        guard let id = expandedMovieID else { return nil }
        return viewModel.movies.first(where: { $0.media?.id == id })
    }

    private var availableTVGenres: [String] {
        Array(Set(viewModel.unwatchedTVShows.flatMap { $0.media?.genres ?? [] })).sorted()
    }

    private var availableMovieGenres: [String] {
        Array(Set(viewModel.unwatchedMovies.flatMap { $0.media?.genres ?? [] })).sorted()
    }

    private var availableTVProviderCategories: [String] {
        providerCategoryLabels(from: viewModel.unwatchedTVShows)
    }

    private var availableMovieProviderCategories: [String] {
        providerCategoryLabels(from: viewModel.unwatchedMovies)
    }

    private var filteredUnwatchedTVShows: [ListItem] {
        filterItems(viewModel.unwatchedTVShows, genre: selectedTVGenre, providerCategory: selectedTVProviderCategory)
    }

    private var filteredUnwatchedMovies: [ListItem] {
        filterItems(viewModel.unwatchedMovies, genre: selectedMovieGenre, providerCategory: selectedMovieProviderCategory)
    }

    private func providerCategoryLabels(from items: [ListItem]) -> [String] {
        var rawCategories = Set<String>()
        for item in items {
            guard let categories = item.media?.providerCategories else { continue }
            for category in categories.values {
                rawCategories.insert(category)
            }
        }
        var labels: [String] = []
        if rawCategories.contains("stream") { labels.append("Stream") }
        if rawCategories.contains("ads") { labels.append("Free with Ads") }
        if rawCategories.contains("rent") || rawCategories.contains("buy") { labels.append("Rent or Buy") }
        return labels
    }

    private func filterItems(_ items: [ListItem], genre: String?, providerCategory: String?) -> [ListItem] {
        var result = items
        if let genre {
            result = result.filter { $0.media?.genres.contains(genre) == true }
        }
        if let providerCategory {
            let rawCategories: Set<String>
            switch providerCategory {
            case "Stream": rawCategories = ["stream"]
            case "Free with Ads": rawCategories = ["ads"]
            case "Rent or Buy": rawCategories = ["rent", "buy"]
            default: rawCategories = []
            }
            result = result.filter { item in
                guard let categories = item.media?.providerCategories.values else { return false }
                return categories.contains(where: { rawCategories.contains($0) })
            }
        }
        return result
    }

    var body: some View {
        mainTabView
            .overlay(alignment: .bottom) {
                if let message = toastMessage {
                    Text(message)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .fontDesign(.rounded)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(.green.opacity(0.2)), in: .capsule)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 100)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    toastMessage = nil
                                }
                            }
                        }
                }
            }
            .animation(.spring(duration: 0.4), value: toastMessage)
            .sheet(isPresented: $showingSettings) {
                ProviderSettingsView()
            }
            .task {
                await viewModel.configure(modelContext: modelContext)
                customListViewModel.configure(modelContext: modelContext)
            }
            .onChange(of: availableTVGenres) {
                if let genre = selectedTVGenre, !availableTVGenres.contains(genre) {
                    selectedTVGenre = nil
                }
            }
            .onChange(of: availableMovieGenres) {
                if let genre = selectedMovieGenre, !availableMovieGenres.contains(genre) {
                    selectedMovieGenre = nil
                }
            }
            .onChange(of: availableTVProviderCategories) {
                if let cat = selectedTVProviderCategory, !availableTVProviderCategories.contains(cat) {
                    selectedTVProviderCategory = nil
                }
            }
            .onChange(of: availableMovieProviderCategories) {
                if let cat = selectedMovieProviderCategory, !availableMovieProviderCategories.contains(cat) {
                    selectedMovieProviderCategory = nil
                }
            }
            .onChange(of: selectedTab) { oldValue, _ in
                if oldValue != .search && oldValue != .discover {
                    previousTab = oldValue
                }
            }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            Tab("TV Shows", systemImage: "tv", value: .tvShows) {
                tvShowsTab
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                moviesTab
            }
            Tab("My Lists", systemImage: "tray.full", value: .myLists) {
                MyListsView(viewModel: customListViewModel)
            }
            Tab("Discover", systemImage: "sparkles", value: .discover) {
                discoverTab
            }
            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                searchTab
            }
        }
    }

    private var tvShowsTab: some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            filteredUnwatchedItems: filteredUnwatchedTVShows,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedTVShowID,
            availableGenres: availableTVGenres,
            selectedGenre: $selectedTVGenre,
            availableProviderCategories: availableTVProviderCategories,
            selectedProviderCategory: $selectedTVProviderCategory,
            navigationTitle: "TV Shows",
            subtitleProvider: { item in
                guard let tvShow = item.tvShow else { return nil }

                // Show "Next Season: S{next}" for partially-watched multi-season shows
                if !item.watchedSeasons.isEmpty,
                   let total = tvShow.numberOfSeasons, total > 1,
                   let next = item.nextSeasonToWatch {
                    let remaining = total - item.watchedSeasons.count
                    if remaining > 1 {
                        return "Next Season: S\(next) (\(remaining) left)"
                    } else {
                        return "Next Season: S\(next)"
                    }
                }
                return tvShow.seasonsEpisodesSummary
            },
            onItemExpanded: { id in
                expandedTVShowID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .tvShow)
            },
            onSearchTapped: { selectedTab = .search },
            onRandomPick: {
                if let randomItem = viewModel.unwatchedTVShows.randomElement(),
                   let id = randomItem.media?.id {
                    expandedTVShowID = id
                }
            },
            onSettingsTapped: { showingSettings = true },
            onItemDeleted: { id in
                viewModel.removeItem(withID: id, mediaType: .tvShow)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .tvShow)
            },
            isLoaded: viewModel.isLoaded
        )
        .sheet(
            item: Binding(
                get: { selectedTVShow },
                set: { _ in expandedTVShowID = nil }
            )
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item, in: $viewModel.tvShows),
                dismiss: {
                    expandedTVShowID = nil
                    viewModel.persistChanges(for: .tvShow)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedTVShowID = nil
                        viewModel.removeItem(withID: id, mediaType: .tvShow)
                    }
                },
                onSeasonCountChanged: { listItem, previousCount in
                    viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
                },
                customListViewModel: customListViewModel
            )
        }
    }

    private var moviesTab: some View {
        MediaListView(
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            filteredUnwatchedItems: filteredUnwatchedMovies,
            watchedItems: $viewModel.watchedMovies,
            expandedItemID: $expandedMovieID,
            availableGenres: availableMovieGenres,
            selectedGenre: $selectedMovieGenre,
            availableProviderCategories: availableMovieProviderCategories,
            selectedProviderCategory: $selectedMovieProviderCategory,
            navigationTitle: "Movies",
            subtitleProvider: { item in
                movieSubtitle(for: item)
            },
            onItemExpanded: { id in
                expandedMovieID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .movie)
            },
            onSearchTapped: { selectedTab = .search },
            onRandomPick: {
                if let randomItem = viewModel.unwatchedMovies.randomElement(),
                   let id = randomItem.media?.id {
                    expandedMovieID = id
                }
            },
            onSettingsTapped: { showingSettings = true },
            onItemDeleted: { id in
                viewModel.removeItem(withID: id, mediaType: .movie)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .movie)
            },
            isLoaded: viewModel.isLoaded
        )
        .sheet(
            item: Binding(
                get: { selectedMovie },
                set: { _ in expandedMovieID = nil }
            )
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item, in: $viewModel.movies),
                dismiss: {
                    expandedMovieID = nil
                    viewModel.persistChanges(for: .movie)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedMovieID = nil
                        viewModel.removeItem(withID: id, mediaType: .movie)
                    }
                },
                customListViewModel: customListViewModel
            )
        }
    }

    private var searchContext: WatchlistSearchView.SearchContext {
        switch previousTab {
        case .tvShows: .tvShows
        case .movies: .movies
        case .myLists: .myLists
        default: .all
        }
    }

    private var discoverTab: some View {
        DiscoverView(
            existingTVShowIDs: existingIDs(for: .tvShow),
            existingMovieIDs: existingIDs(for: .movie),
            onTVShowAdded: { viewModel.addTVShow($0) },
            onMovieAdded: { viewModel.addMovie($0) },
            onItemAdded: { title in
                toastMessage = "\(title) has been added"
            }
        )
    }

    private var searchTab: some View {
        WatchlistSearchView(
            context: searchContext,
            existingTVShowIDs: existingIDs(for: .tvShow),
            existingMovieIDs: existingIDs(for: .movie),
            onTVShowAdded: { viewModel.addTVShow($0) },
            onMovieAdded: { viewModel.addMovie($0) },
            customListViewModel: customListViewModel,
            onDone: { selectedTab = previousTab },
            onItemAdded: { title in
                toastMessage = "\(title) has been added"
            }
        )
    }

    private func binding(forItem item: ListItem, in array: Binding<[ListItem]>) -> Binding<ListItem>
    {
        Binding(
            get: {
                array.wrappedValue.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard
                    let id = item.media?.id,
                    let index = array.wrappedValue.firstIndex(where: { $0.media?.id == id })
                else { return }
                array.wrappedValue[index] = newValue
            }
        )
    }

    private func existingIDs(for mediaType: MediaType) -> Set<String> {
        let items = mediaType == .tvShow ? viewModel.tvShows : viewModel.movies
        return Set(items.compactMap { $0.media?.id })
    }

    private func movieSubtitle(for item: ListItem) -> String? {
        guard let movie = item.movie else { return nil }

        var meta: [String] = []
        if let year = movie.releaseYear {
            meta.append(year)
        }
        if let runtime = movie.runtime {
            meta.append("\(runtime) min")
        }

        return meta.isEmpty ? nil : meta.joined(separator: " \u{2022} ")
    }
}

#Preview {
    ContentView()
}
