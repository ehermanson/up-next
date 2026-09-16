import SwiftUI

struct DiscoverView: View {
    let existingTVShowIDs: Set<String>
    let existingMovieIDs: Set<String>
    let onTVShowAdded: (TVShow) -> Void
    let onMovieAdded: (Movie) -> Void

    @Environment(ToastState.self) private var toast
    @State private var viewModel = DiscoverViewModel()
    /// Type-namespaced IDs (see `MediaIDKey`) of titles added during this session.
    @State private var addedIDs: Set<String> = []
    @State private var detailListItem: ListItem?
    @State private var showingProviderSettings = false

    private let service = TMDBService.shared
    private let settings = ProviderSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    mediaTypePicker
                    providerFilterRow
                    carouselSections
                    browseAllSection
                }
                .padding(.bottom, 20)
            }
            .background(AppBackground())
            .navigationTitle("Discover")
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
        .sheet(isPresented: $showingProviderSettings) {
            ProviderSettingsView()
        }
        .sheet(item: $detailListItem) { item in
            MediaDetailView(
                listItem: detailBinding(for: item),
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
        }
    }

    // MARK: - Media Type Picker

    private var mediaTypePicker: some View {
        Picker("Media Type", selection: $viewModel.selectedMediaType) {
            ForEach(DiscoverViewModel.DiscoverMediaType.allCases, id: \.self) { type in
                Text(type.rawValue).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    // MARK: - Provider Filter Row

    private var providerFilterRow: some View {
        Group {
            if settings.hasSelectedProviders {
                Toggle(isOn: Bindable(settings).onlyMyServicesInDiscover) {
                    Label("On my services", systemImage: "checkmark.seal")
                }
                .tint(Color.accentColor)
            } else {
                Button {
                    showingProviderSettings = true
                } label: {
                    Label("Choose your streaming services", systemImage: "play.tv")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .padding(.horizontal, 16)
    }

    /// True when Discover results are currently narrowed to the user's selected services.
    private var providerFilterIsActive: Bool {
        settings.onlyMyServicesInDiscover && settings.hasSelectedProviders
    }

    // MARK: - Carousel Sections

    private var carouselSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            if viewModel.isCarouselLoading {
                carouselShimmer
            } else {
                carouselRow("Trending", items: viewModel.trendingItems)
                carouselRow("Top Rated", items: viewModel.topRatedItems)
                carouselRow("New Releases", items: viewModel.newReleasesItems)
            }
        }
    }

    private func carouselRow(_ title: String, items: [DiscoverViewModel.DiscoverItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        carouselCard(item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func carouselCard(_ item: DiscoverViewModel.DiscoverItem) -> some View {
        let added = isAlreadyAdded(id: item.tmdbId, mediaType: item.mediaType)

        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button { openDetail(for: item) } label: {
                    CachedAsyncImage(url: service.imageURL(path: item.posterPath)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 140, height: 210)
                                .clipped()
                        case .failure:
                            posterPlaceholder
                        case .empty:
                            posterPlaceholder
                        @unknown default:
                            posterPlaceholder
                        }
                    }
                    .frame(width: 140, height: 210)
                    .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterCard))
                }
                .buttonStyle(.plain)

                Button(added ? "Added" : "Add", systemImage: added ? "checkmark.circle.fill" : "plus.circle.fill") {
                    if !added { addItem(item) }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(added ? .green : .white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(6)
                .buttonStyle(.plain)
            }

            Button { openDetail(for: item) } label: {
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let vote = item.voteAverage, vote > 0 {
                StarRatingLabel(vote: vote)
            }
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .frame(width: 140, height: 210)
    }

    private var carouselShimmer: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .fill(.fill.quaternary)
                        .frame(width: 120, height: 20)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.posterCard)
                                    .fill(.fill.tertiary)
                                    .frame(width: 140, height: 210)
                            }
                        }
                        .padding(.horizontal, 16)
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
            Text("Browse All")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

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
                    }

                    ForEach(DiscoverViewModel.SortOption.allCases, id: \.self) { option in
                        Button {
                            viewModel.selectedSort = option
                        } label: {
                            Chip(text: option.rawValue, isEmphasized: viewModel.selectedSort == option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var browseList: some View {
        Group {
            if viewModel.browseItems.isEmpty && !viewModel.isBrowseLoading && providerFilterIsActive {
                EmptyStateView(
                    icon: "tv.slash",
                    title: "Nothing on your services",
                    subtitle: "Turn off \"On my services\" to see everything."
                )
                .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.browseItems) { item in
                        browseRow(item)
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
                .padding(.horizontal, 16)
            }
        }
    }

    private func browseRow(_ item: DiscoverViewModel.DiscoverItem) -> some View {
        SearchResultRowWithImage(
            title: item.title,
            overview: item.overview,
            posterPath: item.posterPath,
            mediaId: item.tmdbId,
            mediaType: item.mediaType,
            isAdded: isAlreadyAdded(id: item.tmdbId, mediaType: item.mediaType),
            onAdd: { addItem(item) },
            onTap: { openDetail(for: item) },
            voteAverage: item.voteAverage
        )
    }

    // MARK: - Detail Sheet

    private func openDetail(for item: DiscoverViewModel.DiscoverItem) {
        switch item {
        case .tvShow(let result):
            let tvShow = service.mapToTVShow(result)
            detailListItem = ListItem(tvShow: tvShow)
        case .movie(let result):
            let movie = service.mapToMovie(result)
            detailListItem = ListItem(movie: movie)
        }
    }

    private func detailBinding(for item: ListItem) -> Binding<ListItem> {
        Binding(
            get: { detailListItem ?? item },
            set: { detailListItem = $0 }
        )
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
