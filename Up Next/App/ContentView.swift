import SwiftUI

struct ContentView: View {
    private enum MediaTab: Hashable {
        case tvShows
        case movies
        case myLists
        case discover
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = MediaLibraryViewModel()
    @State private var customListViewModel = CustomListViewModel()

    @State private var selectedTab: MediaTab = ContentView.initialTab
    @State private var showingSettings = false
    @State private var showingSearch = false

    #if DEBUG
    /// Set once seeding finishes when launched with `--open <tmdbID>` (screenshot mode). Presented
    /// as its own sheet since `TVShowsTabView` owns `expandedItemID` privately.
    @State private var screenshotDetailItem: ListItem?
    #endif

    private let settings = ProviderSettings.shared
    private let persistence = PersistenceController.shared

    /// `--tab <tvShows|movies|collections|discover>` in screenshot mode, else the normal default.
    private static var initialTab: MediaTab {
        #if DEBUG
        switch ScreenshotMode.requestedTab {
        case "tvShows": return .tvShows
        case "movies": return .movies
        case "collections": return .myLists
        case "discover": return .discover
        default: return .tvShows
        }
        #else
        return .tvShows
        #endif
    }

    var body: some View {
        Group {
            if persistence.isJoiningSharedLibrary {
                joiningPlaceholder
            } else {
                tabView
            }
        }
        .sheet(isPresented: $showingSettings) {
            ProviderSettingsView()
        }
        .task {
            #if DEBUG
            // Screenshot mode: pick a populated provider set before the onboarding check below can
            // fire, so the first-launch sheet never appears.
            ScreenshotMode.configureProviders()
            #endif
            // First launch: prompt for streaming services once, and never again even if the
            // sheet is dismissed without choosing any. Presented before the (possibly slow)
            // library load so the user isn't staring at an empty list first.
            if !settings.hasSelectedProviders && !settings.hasCompletedProviderOnboarding {
                showingSettings = true
                settings.hasCompletedProviderOnboarding = true
            }
            await viewModel.configure()
            customListViewModel.configure()
            #if DEBUG
            if ScreenshotMode.isEnabled {
                await ScreenshotMode.seed(library: viewModel, lists: customListViewModel)
                if let requestedID = ScreenshotMode.requestedDetailID {
                    screenshotDetailItem = viewModel.tvShows.first(where: { $0.media?.id == requestedID })
                }
            }
            #endif
        }
        .onChange(of: settings.regionOverride) {
            // Provider availability is region-specific, so every stored row's networks are now
            // stale. A full refresh re-fetches details — and therefore providers — for all of them.
            Task { await viewModel.refreshNow() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // A swipe-delete is only committed after the undo window; flush it before the app can
            // be terminated in the background, otherwise the item resurrects on relaunch.
            if newPhase == .background {
                viewModel.commitPendingDeletion()
                customListViewModel.commitPendingRemoval()
                // Detail-sheet edits (rating, notes, seasons) are only saved when the sheet closes
                // and Core Data has no autosave, so flush whatever is dirty before the app can be
                // terminated in the background.
                persistence.save()
            }
        }
        .onChange(of: persistence.remoteChangeCount) {
            viewModel.reloadFromStore()
            customListViewModel.reloadFromStore()
        }
    }

    private var joiningPlaceholder: some View {
        EmptyStateView(
            icon: "icloud.and.arrow.down",
            title: "Joining shared library…",
            subtitle: "Waiting for the shared library to arrive from iCloud."
        )
        .background(AppBackground())
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab("TV Shows", systemImage: "tv", value: .tvShows) {
                TVShowsTabView(
                    viewModel: viewModel,
                    customListViewModel: customListViewModel,
                    onSearchTapped: { showingSearch = true },
                    onSettingsTapped: { showingSettings = true }
                )
                .toastOverlay(bottomPadding: 12)
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                MoviesTabView(
                    viewModel: viewModel,
                    customListViewModel: customListViewModel,
                    onSearchTapped: { showingSearch = true },
                    onSettingsTapped: { showingSettings = true }
                )
                .toastOverlay(bottomPadding: 12)
            }
            Tab("Collections", systemImage: "tray.full", value: .myLists) {
                MyListsView(viewModel: customListViewModel)
                    // List rows derive watched state / rating / season progress from the library.
                    .environment(viewModel)
                    .toastOverlay(bottomPadding: 12)
            }
            Tab("Discover", systemImage: "sparkles", value: .discover) {
                DiscoverView(
                    existingTVShowIDs: viewModel.existingTVShowIDs,
                    existingMovieIDs: viewModel.existingMovieIDs,
                    onTVShowAdded: { viewModel.addTVShow($0) },
                    onMovieAdded: { viewModel.addMovie($0) }
                )
                .toastOverlay(bottomPadding: 12)
            }
        }
        // Tab bar on iPhone, sidebar on a wide iPad window — the Apple TV / Music shape.
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
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
        #if DEBUG
        // Screenshot mode only (`--open <tmdbID>`): TVShowsTabView owns `expandedItemID` privately,
        // so this is a self-contained sheet over the tab view rather than reaching into it.
        .sheet(
            item: $screenshotDetailItem,
            onDismiss: { viewModel.persistChanges(for: .tvShow) }
        ) { item in
            MediaDetailView(
                listItem: item,
                dismiss: { screenshotDetailItem = nil },
                onRemove: { screenshotDetailItem = nil },
                customListViewModel: customListViewModel,
                existingIDs: MediaIDKey.makeSet(.tvShow, viewModel.existingTVShowIDs)
                    .union(MediaIDKey.makeSet(.movie, viewModel.existingMovieIDs)),
                onTVShowAdded: { viewModel.addTVShow($0) },
                onMovieAdded: { viewModel.addMovie($0) }
            )
        }
        #endif
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
