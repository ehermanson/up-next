import SwiftUI

struct DiscoverView: View {
    let existingTVShowIDs: Set<String>
    let existingMovieIDs: Set<String>
    let onTVShowAdded: (TVShow) -> Void
    let onMovieAdded: (Movie) -> Void
    var onSettingsTapped: () -> Void

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = DiscoverViewModel()
    /// Type-namespaced IDs (see `MediaIDKey`) of titles added during this session.
    @State private var addedIDs: Set<String> = []
    @State private var detailListItem: ListItem?
    /// The tapped card's zoom-transition source id, captured alongside `detailListItem` — a title
    /// can appear in more than one carousel (or a carousel and Browse All) at once, so each card's
    /// source id is prefixed by its section (see `openDetail(for:sourceID:)`).
    @State private var detailSourceID: String = ""
    @State private var showingProviderSettings = false
    @Namespace private var detailNamespace

    private let service = TMDBService.shared
    private let settings = ProviderSettings.shared

    var body: some View {
        NavigationStack {
            // Exactly one `ScrollView` stays mounted under `.searchable` at all times — swapping
            // the scroll container under the search bar makes the field jump and drop focus
            // (see `WatchlistSearchView`'s equivalent note for its `List`).
            ScrollView {
                VStack(spacing: 20) {
                    mediaTypePicker
                    if viewModel.isSearchActive {
                        searchResultsSection
                    } else {
                        providerFilterRow
                        carouselSections
                        browseAllSection
                    }
                }
                .padding(.bottom, 20)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .background(AppBackground(drifts: true))
            .navigationTitle("Discover")
            .searchable(text: $viewModel.searchQuery, prompt: "Search movies & TV shows")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(action: onSettingsTapped)
                }
            }
        }
        .task {
            await viewModel.initialLoad()
        }
        .onChange(of: settings.onlyMyServicesInDiscover) {
            viewModel.providerFilterChanged()
        }
        .onChange(of: settings.selectedProviderIDs) {
            viewModel.providerFilterChanged()
        }
        .onChange(of: settings.regionOverride) {
            // `watch_region` / `region` are baked into every URL, so the cache keys already
            // differ — reissuing under the new region is enough, no invalidation needed.
            viewModel.providerFilterChanged()
        }
        .sheet(isPresented: $showingProviderSettings) {
            ProviderSettingsView()
        }
        .sheet(item: $detailListItem) { item in
            if horizontalSizeClass == .regular {
                detailSheetContent(for: item)
                    .presentationSizing(.page)
            } else {
                detailSheetContent(for: item)
            }
        }
    }

    private func detailSheetContent(for item: ListItem) -> some View {
        MediaDetailView(
            listItem: item,
            dismiss: { detailListItem = nil },
            onRemove: { detailListItem = nil },
            onAdd: {
                addFromDetail(item)
            },
            existingIDs: MediaIDKey.makeSet(.tvShow, existingTVShowIDs)
                .union(MediaIDKey.makeSet(.movie, existingMovieIDs))
                .union(addedIDs),
            onTVShowAdded: { onTVShowAdded($0) },
            onMovieAdded: { onMovieAdded($0) }
        )
        .navigationTransition(.zoom(sourceID: detailSourceID, in: detailNamespace))
    }

    // MARK: - Media Type Picker

    private var mediaTypePicker: some View {
        Picker("Media Type", selection: $viewModel.selectedMediaType) {
            ForEach(DiscoverViewModel.DiscoverMediaType.allCases, id: \.self) { type in
                Text(type.rawValue).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DesignTokens.Spacing.screenInset)
        .frame(maxWidth: horizontalSizeClass == .regular ? 480 : .infinity)
    }

    // MARK: - Provider Filter Row

    /// Compact chip directly under the media-type picker — a full-width toggle card was too
    /// heavy for what's a single on/off filter.
    private var providerFilterRow: some View {
        HStack {
            if settings.hasSelectedProviders {
                Button {
                    settings.onlyMyServicesInDiscover.toggle()
                } label: {
                    Chip(
                        icon: settings.onlyMyServicesInDiscover ? "checkmark.seal.fill" : "checkmark.seal",
                        text: "On my services",
                        isEmphasized: settings.onlyMyServicesInDiscover
                    )
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.onlyMyServicesInDiscover ? .isSelected : [])
            } else {
                Button {
                    showingProviderSettings = true
                } label: {
                    Chip(icon: "play.tv", text: "Choose your services")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.screenInset)
        .frame(maxWidth: horizontalSizeClass == .regular ? 480 : .infinity)
    }

    /// True when Discover results are currently narrowed to the user's selected services.
    private var providerFilterIsActive: Bool {
        settings.onlyMyServicesInDiscover && settings.hasSelectedProviders
    }

    // MARK: - Carousel Sections

    @ViewBuilder
    private var carouselSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            if viewModel.isCarouselLoading {
                carouselShimmer
            } else if let error = viewModel.carouselError, !viewModel.hasCarouselItems {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't Load",
                    subtitle: error
                ) {
                    Button("Try Again") {
                        Task { await viewModel.reload() }
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.vertical, 40)
            } else {
                carouselRow("Trending", items: viewModel.trendingItems)
                carouselRow("Airing This Week", items: viewModel.airingThisWeekItems, showsAirDate: true)
                carouselRow("In Theaters", items: viewModel.inTheatersItems)
                carouselRow("Top Rated", items: viewModel.topRatedItems)
                carouselRow("New Releases", items: viewModel.newReleasesItems)
            }
        }
    }

    /// Renders nothing when the carousel has no items — "Airing This Week" and "In Theaters"
    /// only apply to one media type each.
    @ViewBuilder
    private func carouselRow(
        _ title: String, items: [DiscoverViewModel.DiscoverItem], showsAirDate: Bool = false
    ) -> some View {
        if !items.isEmpty {
            carouselRowContent(title, items: items, showsAirDate: showsAirDate)
        }
    }

    private func carouselRowContent(
        _ title: String, items: [DiscoverViewModel.DiscoverItem], showsAirDate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, showsFilter: false)
                .padding(.horizontal, DesignTokens.Spacing.screenInset)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        carouselCard(item, carouselTitle: title, showsAirDate: showsAirDate)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A title can appear in more than one carousel (or a carousel and Browse All) at once, so
    /// every card's zoom-transition source id is namespaced by where it's rendered, on top of
    /// `MediaIDKey`'s movie/TV namespacing.
    private func transitionSourceID(_ sectionPrefix: String, _ item: DiscoverViewModel.DiscoverItem) -> String {
        "\(sectionPrefix):" + MediaIDKey.make(item.mediaType, item.tmdbId)
    }

    /// Carousel poster size — larger on regular width (iPad) to use the extra space, same 2:3 ratio.
    private var posterCardSize: CGSize {
        horizontalSizeClass == .regular ? CGSize(width: 170, height: 255) : CGSize(width: 140, height: 210)
    }

    private func carouselCard(
        _ item: DiscoverViewModel.DiscoverItem, carouselTitle: String, showsAirDate: Bool = false
    ) -> some View {
        let added = isAlreadyAdded(id: item.tmdbId, mediaType: item.mediaType)
        let sourceID = transitionSourceID(carouselTitle, item)

        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button { openDetail(for: item, sourceID: sourceID) } label: {
                    CachedAsyncImage(url: service.imageURL(path: item.posterPath)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: posterCardSize.width, height: posterCardSize.height)
                                .clipped()
                        case .failure:
                            posterPlaceholder
                        case .empty:
                            posterPlaceholder
                        @unknown default:
                            posterPlaceholder
                        }
                    }
                    .frame(width: posterCardSize.width, height: posterCardSize.height)
                    .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterCard))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: sourceID, in: detailNamespace)
                .accessibilityLabel(item.title)

                Button(added ? "Added" : "Add", systemImage: added ? "checkmark.circle.fill" : "plus.circle.fill") {
                    if !added { addItem(item) }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(added ? .green : Color.accentColor)
                .frame(width: 44, height: 44)
                .chipSurface()
                .padding(4)
                .buttonStyle(.plain)
                .checkmarkPop(isOn: added)
            }
            .overlay(alignment: .bottomLeading) {
                if showsAirDate, let label = airDateLabel(for: item) {
                    Chip(icon: "calendar", text: label)
                        .padding(6)
                }
            }
            .task(id: item.tmdbId) {
                guard showsAirDate, item.mediaType == .tvShow else { return }
                await viewModel.loadAiringDate(for: item.tmdbId)
            }

            // Same destination as the poster button above — VoiceOver only needs one of the two.
            Button { openDetail(for: item, sourceID: sourceID) } label: {
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: posterCardSize.width, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            if let vote = item.voteAverage, vote > 0 {
                StarRatingLabel(vote: vote)
            }
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .frame(width: posterCardSize.width, height: posterCardSize.height)
    }

    /// "S3E2 · Tuesday" label for the "Airing This Week" chip, or `nil` until the per-card fetch
    /// (`.task(id:)` below, via `viewModel.loadAiringDate(for:)`) lands. `/discover/tv` and
    /// `/search/tv` payloads (`TMDBTVShowSearchResult`) only carry `firstAirDate` — the show's
    /// original premiere — not the specific upcoming episode that actually placed it in this
    /// carousel's air-date window, so the label comes from a lazily-fetched `next_episode_to_air`
    /// instead of that field.
    private func airDateLabel(for item: DiscoverViewModel.DiscoverItem) -> String? {
        guard let dateString = viewModel.airingDates[item.tmdbId],
              let date = AirDateFormat.date(from: dateString)
        else { return nil }
        let relative = AirDateFormat.relativeLabel(for: date)
        guard let code = viewModel.airingEpisodeCodes[item.tmdbId] else { return relative }
        return "\(code) · \(relative)"
    }

    private var carouselShimmer: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .fill(.fill.quaternary)
                        .frame(width: 120, height: 20)
                        .padding(.horizontal, DesignTokens.Spacing.screenInset)

                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.posterCard)
                                    .fill(.fill.tertiary)
                                    .frame(width: posterCardSize.width, height: posterCardSize.height)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.screenInset)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDisabled(true)
                }
            }
        }
    }

    // MARK: - Browse All Section

    private var browseAllSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            browseHeader
            browseList
        }
    }

    private var browseHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Browse All", showsFilter: false)
                .padding(.horizontal, DesignTokens.Spacing.screenInset)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Menu {
                        Button("All Genres") {
                            viewModel.selectedGenre = nil
                        }
                        ForEach(viewModel.genres, id: \.id) { genre in
                            Button(genre.name) {
                                viewModel.selectedGenre = genre
                            }
                        }
                    } label: {
                        Chip(
                            icon: "line.3.horizontal.decrease",
                            text: viewModel.selectedGenre?.name ?? "All Genres",
                            isEmphasized: viewModel.selectedGenre != nil
                        )
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    // Same as `SectionHeader`'s filter: keep the Menu from tinting the chip purple.
                    .tint(.primary)

                    ForEach(DiscoverViewModel.SortOption.allCases, id: \.self) { option in
                        Button {
                            viewModel.selectedSort = option
                        } label: {
                            Chip(text: option.rawValue, isEmphasized: viewModel.selectedSort == option)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var browseList: some View {
        Group {
            if let error = viewModel.browseError, viewModel.browseItems.isEmpty {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't Load",
                    subtitle: error
                ) {
                    Button("Try Again") {
                        Task { await viewModel.reloadBrowse() }
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.vertical, 40)
            } else if viewModel.browseItems.isEmpty && !viewModel.isBrowseLoading && providerFilterIsActive {
                EmptyStateView(
                    icon: "tv.slash",
                    title: "Nothing on your services",
                    subtitle: "Turn off \"On my services\" to see everything."
                )
                .padding(.vertical, 40)
            } else {
                VStack(spacing: 8) {
                    if horizontalSizeClass == .regular {
                        // Regular width: let rows form 2-3 columns instead of one long list.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(viewModel.browseItems) { item in
                                browseRow(item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.browseItems) { item in
                                browseRow(item)
                            }
                        }
                    }

                    if viewModel.isBrowseLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else if viewModel.browsePage < viewModel.browseTotalPages {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await viewModel.loadNextBrowsePage() }
                            }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
            }
        }
    }

    private func browseRow(_ item: DiscoverViewModel.DiscoverItem) -> some View {
        let sourceID = transitionSourceID("browse", item)
        return SearchResultRowWithImage(
            title: item.title,
            overview: item.overview,
            posterPath: item.posterPath,
            mediaId: item.tmdbId,
            mediaType: item.mediaType,
            isAdded: isAlreadyAdded(id: item.tmdbId, mediaType: item.mediaType),
            onAdd: { addItem(item) },
            onTap: { openDetail(for: item, sourceID: sourceID) },
            voteAverage: item.voteAverage,
            year: item.year,
            transitionSource: (id: sourceID, namespace: detailNamespace)
        )
    }

    // MARK: - Search Results

    /// Shown in place of the provider chip, carousels and Browse All while
    /// `viewModel.searchQuery` is non-empty — rendered as plain views inside the same `ScrollView`
    /// (mirroring `browseList`'s `LazyVStack` path) rather than swapping in a `List`, which would
    /// make the search field under `.searchable` jump and drop focus. Reuses
    /// `SearchResultRowWithImage`/`ShimmerRows` from `SearchComponents.swift` and the same
    /// `openDetail`/`addItem`/`isAlreadyAdded` plumbing the carousels and Browse All already use,
    /// rather than duplicating the recommendation/search engine from `WatchlistSearchView`.
    @ViewBuilder
    private var searchResultsSection: some View {
        if viewModel.isSearching && !viewModel.hasSearchResults {
            // Only shimmer on a cold search — otherwise keystrokes would blank the previous
            // results while the debounced request is still in flight.
            VStack(spacing: 8) {
                ShimmerRows()
            }
            .padding(.horizontal, DesignTokens.Spacing.screenInset)
        } else if let error = viewModel.searchError {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't Load", subtitle: error)
                .padding(.vertical, 40)
        } else if viewModel.hasSearchResults {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.searchResultItems) { item in
                    browseRow(item)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenInset)
        } else {
            EmptyStateView(
                icon: "magnifyingglass.circle",
                title: "No Results Found",
                subtitle: viewModel.crossTypeSearchResultCount > 0 ? nil : "Try adjusting your search"
            ) {
                if viewModel.crossTypeSearchResultCount > 0 {
                    Button(viewModel.searchCrossTypeHintTitle) {
                        viewModel.showOtherSearchMediaType()
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.vertical, 40)
        }
    }

    // MARK: - Detail Sheet

    private func openDetail(for item: DiscoverViewModel.DiscoverItem, sourceID: String) {
        detailSourceID = sourceID
        switch item {
        case .tvShow(let result):
            let tvShow = service.mapToTVShow(result)
            detailListItem = ListItem(tvShow: tvShow)
        case .movie(let result):
            let movie = service.mapToMovie(result)
            detailListItem = ListItem(movie: movie)
        }
    }

    private func addFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let key = MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        guard !addedIDs.contains(key) else { return }
        addedIDs.insert(key)

        if let tvShow = item.tvShow {
            onTVShowAdded(tvShow)
        } else if let movie = item.movie {
            onMovieAdded(movie)
        }
    }

    // MARK: - Add Directly

    private func addItem(_ item: DiscoverViewModel.DiscoverItem) {
        let key = MediaIDKey.make(item.mediaType, item.tmdbId)
        guard !addedIDs.contains(key) else { return }
        addedIDs.insert(key)
        toast.show("\(item.title) has been added")

        Task {
            switch item {
            case .tvShow(let result):
                let tvShow: TVShow
                do {
                    let detail = try await service.getTVShowDetails(id: result.id)
                    let providers = detail.watchProviders?.results?[service.currentRegion]
                    tvShow = await service.mapToTVShow(detail, providers: providers)
                } catch {
                    tvShow = service.mapToTVShow(result)
                }
                onTVShowAdded(tvShow)
            case .movie(let result):
                let movie: Movie
                do {
                    let detail = try await service.getMovieDetails(id: result.id)
                    let providers = detail.watchProviders?.results?[service.currentRegion]
                    movie = await service.mapToMovie(detail, providers: providers)
                } catch {
                    movie = service.mapToMovie(result)
                }
                onMovieAdded(movie)
            }
        }
    }

    // MARK: - Helpers

    private func isAlreadyAdded(id: Int, mediaType: MediaType) -> Bool {
        let stringID = String(id)
        let existingIDs = mediaType == .tvShow ? existingTVShowIDs : existingMovieIDs
        return existingIDs.contains(stringID) || addedIDs.contains(MediaIDKey.make(mediaType, stringID))
    }
}
