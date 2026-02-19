import SwiftUI

struct DiscoverView: View {
    let existingTVShowIDs: Set<String>
    let existingMovieIDs: Set<String>
    let onTVShowAdded: (TVShow) -> Void
    let onMovieAdded: (Movie) -> Void
    var onItemAdded: ((String) -> Void)?

    @State private var viewModel = DiscoverViewModel()
    @State private var addedIDs: Set<String> = []
    @State private var detailListItem: ListItem?

    private let service = TMDBService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    mediaTypePicker
                    carouselSections
                    browseAllSection
                }
                .padding(.bottom, 20)
            }
            .background(AppBackground())
            .navigationTitle("Discover")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .task {
            await viewModel.initialLoad()
        }
        .sheet(item: $detailListItem) { item in
            MediaDetailView(
                listItem: detailBinding(for: item),
                dismiss: { detailListItem = nil },
                onRemove: { detailListItem = nil },
                onAdd: {
                    addFromDetail(item)
                },
                existingIDs: existingTVShowIDs.union(existingMovieIDs).union(addedIDs),
                onTVShowAdded: { onTVShowAdded($0) },
                onMovieAdded: { onMovieAdded($0) },
                onItemAdded: onItemAdded
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
                .fontDesign(.rounded)
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
                .clipShape(.rect(cornerRadius: 12))
                .onTapGesture { openDetail(for: item) }

                Button {
                    if !added { addItem(item) }
                } label: {
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(added ? .green : .white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .fontDesign(.rounded)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .onTapGesture { openDetail(for: item) }

            if let vote = item.voteAverage, vote > 0 {
                StarRatingLabel(vote: vote)
            }
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 140, height: 210)
    }

    private var carouselShimmer: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 120, height: 20)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.08))
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
                .fontDesign(.rounded)
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
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.caption)
                            Text(viewModel.selectedGenre?.name ?? "All Genres")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(
                            viewModel.selectedGenre != nil
                                ? .regular.tint(.indigo.opacity(0.4))
                                : .regular,
                            in: .capsule
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(DiscoverViewModel.SortOption.allCases, id: \.self) { option in
                        Button {
                            viewModel.selectedSort = option
                        } label: {
                            Text(option.rawValue)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(
                                    viewModel.selectedSort == option
                                        ? .regular.tint(.indigo.opacity(0.4))
                                        : .regular,
                                    in: .capsule
                                )
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
        GlassEffectContainer(spacing: 8) {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.browseItems) { item in
                    browseRow(item)
                }

                if viewModel.isBrowseLoading {
                    ProgressView()
                        .tint(.white)
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
        }
        .padding(.horizontal, 16)
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
        let stringID = media.id
        guard !addedIDs.contains(stringID) else { return }
        addedIDs.insert(stringID)
        onItemAdded?(media.title)

        if let tvShow = item.tvShow {
            onTVShowAdded(tvShow)
        } else if let movie = item.movie {
            onMovieAdded(movie)
        }
    }

    // MARK: - Add Directly

    private func addItem(_ item: DiscoverViewModel.DiscoverItem) {
        let stringID = String(item.tmdbId)
        guard !addedIDs.contains(stringID) else { return }
        addedIDs.insert(stringID)
        onItemAdded?(item.title)

        Task {
            switch item {
            case .tvShow(let result):
                let tvShow: TVShow
                do {
                    async let detailTask = service.getTVShowDetails(id: result.id)
                    async let providersTask = service.getTVShowWatchProviders(id: result.id)
                    let detail = try await detailTask
                    let providers = try await providersTask
                    tvShow = service.mapToTVShow(detail, providers: providers)
                } catch {
                    tvShow = service.mapToTVShow(result)
                }
                onTVShowAdded(tvShow)
            case .movie(let result):
                let movie: Movie
                do {
                    async let detailTask = service.getMovieDetails(id: result.id)
                    async let providersTask = service.getMovieWatchProviders(id: result.id)
                    let detail = try await detailTask
                    let providers = try await providersTask
                    movie = service.mapToMovie(detail, providers: providers)
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
        return existingIDs.contains(stringID) || addedIDs.contains(stringID)
    }
}
