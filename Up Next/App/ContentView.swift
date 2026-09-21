import CloudKit
import SwiftUI

struct ContentView: View {
    private enum MediaTab: Hashable {
        case tvShows
        case movies
        case myLists
        case discover
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ToastState.self) private var toast
    @State private var viewModel = MediaLibraryViewModel()
    @State private var customListViewModel = CustomListViewModel()

    @State private var selectedTab: MediaTab = ContentView.initialTab
    @State private var showingSettings = false
    /// First-launch provider onboarding presents `ProviderSettingsView` directly (its own
    /// `NavigationStack` + Done) rather than the full `SettingsView` — a single, focused choice
    /// before the library loads, not a tour of every settings row.
    @State private var showingOnboarding = false
    @State private var showingSearch = false
    /// One-time offer to bring a 1.x library over (`LegacyImporter.isOfferPending`).
    @State private var showingLegacyImport = false
    @State private var joinErrorMessage: String?

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
            SettingsView(library: viewModel, lists: customListViewModel)
        }
        // Only one sheet can be up at a time, so the import offer waits for onboarding to close.
        .sheet(isPresented: $showingOnboarding, onDismiss: { presentLegacyImportIfNeeded() }) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $showingLegacyImport) {
            LegacyImportView(library: viewModel, lists: customListViewModel)
        }
        .task {
            #if DEBUG
            // Screenshot mode: pick a populated provider set before the onboarding check below can
            // fire, so the first-launch sheet never appears.
            ScreenshotMode.configureProviders()
            #endif
            // First launch: prompt for streaming services once, and never again even if the
            // sheet is dismissed without choosing any. Presented before the (possibly slow)
            // library load so the user isn't staring at an empty list first. Skipped while a
            // share invitation is waiting for an answer — the app was launched from a link and
            // that alert comes first; `presentOnboardingIfNeeded` runs once it's decided.
            if persistence.pendingShareInvitation == nil {
                presentOnboardingIfNeeded()
            }
            await viewModel.configure()
            customListViewModel.configure()
            presentLegacyImportIfNeeded()
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
        .onChange(of: persistence.pendingShareInvitation == nil) { _, decided in
            if decided { presentOnboardingIfNeeded() }
        }
        // Joining or leaving swaps the whole store out from under the view models: the library is
        // gone for the duration and `group` is nil, so they have to drop what they're holding.
        .onChange(of: persistence.isJoiningSharedLibrary) {
            viewModel.reloadFromStore()
            customListViewModel.reloadFromStore()
        }
        // A rejected save is silent otherwise, and the user's edit is rolled back underneath them.
        .onChange(of: persistence.lastSaveError != nil) { _, failed in
            guard failed else { return }
            toast.show("Couldn't save your changes", icon: "exclamationmark.triangle.fill")
            persistence.clearLastSaveError()
        }
        // The partner's edits landing while the app is on screen: toast rather than banner.
        .onChange(of: persistence.recentRemoteActivity) { _, lines in
            guard let first = lines.first else { return }
            toast.show(
                lines.count > 1 ? "\(first) and \(lines.count - 1) more" : first,
                icon: "person.2.fill"
            )
            persistence.recentRemoteActivity = []
        }
        // A tapped share link waits here: joining replaces this device's own library, so say so
        // before doing it.
        //
        // Ordering trap, do not reintroduce: SwiftUI writes `false` into `isPresented` as soon as
        // *any* button is tapped, before that button's action runs. A setter that declined on
        // `false` therefore cleared `pendingShareInvitation` out from under the Join action, which
        // then had nothing to accept. The setter is a no-op and each button clears the invitation
        // itself — Join after capturing the metadata synchronously.
        .alert(
            joinInvitationTitle,
            isPresented: Binding(
                get: { persistence.pendingShareInvitation != nil },
                set: { _ in }
            )
        ) {
            Button("Join", role: .destructive) {
                guard let metadata = persistence.pendingShareInvitation else { return }
                persistence.declinePendingShareInvitation()
                Task {
                    do {
                        try await persistence.switchShare(to: metadata)
                    } catch {
                        joinErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                persistence.declinePendingShareInvitation()
            }
        } message: {
            Text(joinInvitationMessage)
        }
        // An owner who is already sharing can't join: accepting purges the private store, which
        // holds the share root, and CloudKit would delete the zone out from under their partner.
        .alert(
            "Stop Sharing First",
            isPresented: Binding(
                get: { persistence.blockedShareInvitation != nil },
                set: { _ in }
            )
        ) {
            Button("OK", role: .cancel) {
                persistence.clearBlockedShareInvitation()
            }
        } message: {
            Text(blockedInvitationMessage)
        }
        // The owner stopped sharing: the participant's library is gone and they're an owner again.
        .alert(
            "\(persistence.sharingEndedByOwnerName ?? "Your partner") Stopped Sharing",
            isPresented: Binding(
                get: { persistence.sharingEndedByOwnerName != nil },
                set: { _ in }
            )
        ) {
            Button("OK", role: .cancel) {
                persistence.sharingEndedByOwnerName = nil
            }
        } message: {
            Text("You now have an empty library of your own. Anything you add from here on is just yours.")
        }
        .alert(
            "Couldn't Join Shared Library",
            isPresented: Binding(
                get: { joinErrorMessage != nil },
                set: { if !$0 { joinErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(joinErrorMessage ?? "")
        }
    }

    /// A library from Up Next 1.x is still on disk: offer to bring it over, once. Gated on the
    /// watchlists having loaded — until they do, `addTVShow` queues rows and there'd be no
    /// `ListItem` to copy the old watched state onto — and on nothing else owning the sheet slot
    /// (the provider onboarding sheet re-checks this when it closes).
    private func presentLegacyImportIfNeeded() {
        guard !showingOnboarding, !showingSettings, !showingSearch,
              !persistence.isJoiningSharedLibrary,
              persistence.pendingShareInvitation == nil,
              viewModel.isLoaded,
              LegacyImporter.isOfferPending
        else { return }
        showingLegacyImport = true
    }

    private func presentOnboardingIfNeeded() {
        guard !settings.hasSelectedProviders && !settings.hasCompletedProviderOnboarding else { return }
        showingOnboarding = true
        settings.hasCompletedProviderOnboarding = true
    }

    // MARK: - Join confirmation

    private var invitationOwnerName: String? {
        persistence.pendingShareInvitation?.ownerIdentity.displayName
    }

    private var joinInvitationTitle: String {
        if let name = invitationOwnerName {
            return "Join \(name)'s library?"
        }
        return "Join this shared library?"
    }

    private var joinInvitationMessage: String {
        let shared = "You'll both see and edit the same watchlist and collections."
        // Already in someone else's library: nothing of this device's own is at stake, but the
        // library they're in right now is.
        if let currentOwner = persistence.pendingInvitationCurrentOwnerName {
            return "You're currently in \(currentOwner)'s shared library. Joining replaces it on this device. You can rejoin later from the original link."
        }

        let counts = persistence.ownedLibraryCounts()
        guard counts.titles > 0 || counts.collections > 0 else { return shared }
        var parts: [String] = []
        if counts.titles > 0 {
            parts.append("\(counts.titles) \(counts.titles == 1 ? "title" : "titles")")
        }
        if counts.collections > 0 {
            parts.append("\(counts.collections) \(counts.collections == 1 ? "collection" : "collections")")
        }
        return "Your own \(parts.joined(separator: " and ")) on this device will be removed and replaced by the shared library. \(shared)"
    }

    private var blockedInvitationMessage: String {
        let partner = persistence.liveShare?.partnerParticipant?.displayName ?? "your partner"
        let library = persistence.blockedShareInvitationOwnerName.map { "\($0)'s library" } ?? "this library"
        return "You're sharing your library with \(partner). To join \(library) instead, stop sharing yours first in Settings → Sharing."
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
                MyListsView(viewModel: customListViewModel, onSettingsTapped: { showingSettings = true })
                    // List rows derive watched state / rating / season progress from the library.
                    .environment(viewModel)
                    .toastOverlay(bottomPadding: 12)
            }
            Tab("Discover", systemImage: "sparkles", value: .discover) {
                DiscoverView(
                    existingTVShowIDs: viewModel.existingTVShowIDs,
                    existingMovieIDs: viewModel.existingMovieIDs,
                    onTVShowAdded: { viewModel.addTVShow($0) },
                    onMovieAdded: { viewModel.addMovie($0) },
                    onSettingsTapped: { showingSettings = true }
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
        .environment(ToastState())
}
