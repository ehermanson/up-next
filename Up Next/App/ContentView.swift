import SwiftData
import SwiftUI

struct ContentView: View {
    private enum MediaTab: Hashable {
        case tvShows
        case movies
        case myLists
        case discover
    }

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MediaLibraryViewModel()
    @State private var customListViewModel = CustomListViewModel()

    @State private var selectedTab: MediaTab = .tvShows
    @State private var showingSettings = false
    @State private var showingSearch = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("TV Shows", systemImage: "tv", value: .tvShows) {
                TVShowsTabView(
                    viewModel: viewModel,
                    customListViewModel: customListViewModel,
                    onSearchTapped: { showingSearch = true },
                    onSettingsTapped: { showingSettings = true }
                )
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                MoviesTabView(
                    viewModel: viewModel,
                    customListViewModel: customListViewModel,
                    onSearchTapped: { showingSearch = true },
                    onSettingsTapped: { showingSettings = true }
                )
            }
            Tab("My Lists", systemImage: "tray.full", value: .myLists) {
                MyListsView(viewModel: customListViewModel)
            }
            Tab("Discover", systemImage: "sparkles", value: .discover) {
                DiscoverView(
                    existingTVShowIDs: viewModel.existingTVShowIDs,
                    existingMovieIDs: viewModel.existingMovieIDs,
                    onTVShowAdded: { viewModel.addTVShow($0) },
                    onMovieAdded: { viewModel.addMovie($0) }
                )
            }
        }
        .toastOverlay(bottomPadding: 100)
        .sheet(isPresented: $showingSettings) {
            ProviderSettingsView()
        }
        .task {
            await viewModel.configure(modelContext: modelContext)
            customListViewModel.configure(modelContext: modelContext)
        }
        .sheet(isPresented: $showingSearch) {
            WatchlistSearchView(
                context: searchContext,
                existingTVShowIDs: viewModel.existingTVShowIDs,
                existingMovieIDs: viewModel.existingMovieIDs,
                onTVShowAdded: { viewModel.addTVShow($0) },
                onMovieAdded: { viewModel.addMovie($0) },
                customListViewModel: customListViewModel,
                libraryTVShows: viewModel.tvShows,
                libraryMovies: viewModel.movies
            )
        }
    }

    private var searchContext: WatchlistSearchView.SearchContext {
        switch selectedTab {
        case .tvShows: .tvShows
        case .movies: .movies
        case .myLists: .myLists
        default: .all
        }
    }
}

#Preview {
    ContentView()
}
