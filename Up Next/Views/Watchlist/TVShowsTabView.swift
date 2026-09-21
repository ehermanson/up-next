import SwiftUI

struct TVShowsTabView: View {
    @Bindable var viewModel: MediaLibraryViewModel
    let customListViewModel: CustomListViewModel
    var onSearchTapped: () -> Void
    var onSettingsTapped: () -> Void

    private let settings = ProviderSettings.shared
    private let persistence = PersistenceController.shared

    /// See the "Sharing" section of CLAUDE.md for the full rule. `persistence.isSharingLive` and
    /// `isCloudAccountAvailable` are both observable, so this re-derives automatically — no local
    /// state or manual refresh needed (contrast the old `existingShare()`-based check, which had
    /// to poll on appear/foreground/remote-change to stay current).
    private var showsSharePitch: Bool {
        guard !settings.hasDismissedSharePitch,
              persistence.role != .participant,
              !persistence.isJoiningSharedLibrary,
              persistence.isCloudAccountAvailable == true,
              !persistence.isSharingLive,
              viewModel.isLoaded,
              viewModel.tvShows.count + viewModel.movies.count >= 3
        else { return false }
        return true
    }

    var body: some View {
        WatchlistTabView(
            viewModel: viewModel,
            customListViewModel: customListViewModel,
            mediaType: .tvShow,
            onlyMyServicesKey: StorageKey.tvOnlyMyServices,
            navigationTitle: "TV Shows",
            upcomingTitle: "Returning Soon",
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            watchedItems: $viewModel.watchedTVShows,
            watchingItems: viewModel.watchingTVShows,
            upcomingItems: upcomingEntries(from: viewModel.tvShows, mediaType: .tvShow),
            availableGenres: viewModel.availableTVGenres,
            availableProviderCategories: viewModel.availableTVProviderCategories,
            subtitleProvider: { item in tvShowSubtitle(for: item) },
            onSearchTapped: onSearchTapped,
            onSettingsTapped: onSettingsTapped,
            topContent: showsSharePitch ? { AnyView(SharePitchCard()) } : nil,
            onSeasonCountChanged: { listItem, previousCount in
                viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
            }
        )
    }

    private func tvShowSubtitle(for item: ListItem) -> String? {
        guard let tvShow = item.tvShow else { return nil }

        if item.isWatching && item.isWatched { return "Caught up" }

        if item.isDropped {
            let count = item.watchedSeasons.count
            let total = tvShow.numberOfSeasons ?? 0
            return total > 0 ? "Dropped \u{00B7} \(count) of \(total) seasons" : "Dropped"
        }

        // Caught up, with the next season only announced: say so rather than falling through to a
        // plain season count, which reads like there's something waiting.
        if item.isWatched, let announced = tvShow.announcedSeasonNumber {
            if let premiere = tvShow.announcedSeasonPremiere {
                let label = AirDateFormat.shortLabel(from: premiere) ?? premiere
                return "Season \(announced) premieres \(label)"
            }
            return "Season \(announced) announced"
        }

        if !item.watchedSeasons.isEmpty,
           let total = tvShow.numberOfSeasons, total > 1,
           !item.isWatched {
            let watched = Set(item.watchedSeasons).filter { (1...total).contains($0) }.count
            return "\(watched) of \(total) seasons watched"
        }

        return tvShow.seasonsEpisodesSummary
    }
}
