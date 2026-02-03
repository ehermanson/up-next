import SwiftData
import SwiftUI

struct MediaDetailView: View {
    @Binding var listItem: ListItem
    let dismiss: () -> Void
    let onRemove: () -> Void
    var onSeasonCountChanged: ((ListItem, Int?) -> Void)?
    var customListViewModel: CustomListViewModel?

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false
    @State private var showingHiddenProviders = false
    @State private var showingTMDBPage = false
    @State private var showingAddToList = false

    private let service = TMDBService.shared

    private var tmdbURL: URL? {
        guard let media = listItem.media else { return nil }
        let type = listItem.tvShow != nil ? "tv" : "movie"
        return URL(string: "https://www.themoviedb.org/\(type)/\(media.id)")
    }

    private var visibleNetworks: [Network] {
        (listItem.media?.networks ?? []).filter { !ProviderSettings.shared.isHidden($0.id) }
    }

    private var hiddenNetworks: [Network] {
        (listItem.media?.networks ?? []).filter { ProviderSettings.shared.isHidden($0.id) }
    }

    private var needsFullDetails: Bool {
        guard let media = listItem.media, Int(media.id) != nil else { return false }

        if let tvShow = listItem.tvShow {
            if tvShow.numberOfSeasons == nil { return true }
            if tvShow.cast.isEmpty { return true }
            if tvShow.genres.isEmpty { return true }
            if tvShow.providerCategories.isEmpty { return true }
            return false
        }

        if let movie = listItem.movie {
            if movie.runtime == nil { return true }
            if movie.cast.isEmpty { return true }
            if movie.genres.isEmpty { return true }
            if movie.releaseDate == nil || movie.releaseDate?.isEmpty == true { return true }
            if movie.providerCategories.isEmpty { return true }
            return false
        }

        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HeaderImageView(imageURL: listItem.media?.thumbnailURL)

                    GlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(listItem.media?.title ?? "")
                                .font(.title)
                                .fontWeight(.bold)

                            MetadataRow(listItem: listItem)

                            GenreSection(genres: listItem.media?.genres ?? [])

                            DetailProviderRow(
                                visibleNetworks: visibleNetworks,
                                hiddenNetworks: hiddenNetworks,
                                providerCategories: listItem.media?.providerCategories ?? [:],
                                showingHiddenProviders: $showingHiddenProviders
                            )

                            Divider().padding(.vertical, 4)

                            DescriptionSection(
                                isLoading: isLoadingDetails,
                                descriptionText: listItem.media?.descriptionText,
                                errorMessage: detailError)

                            Divider().padding(.vertical, 4)

                            CastSection(
                                cast: listItem.media?.cast ?? [],
                                castImagePaths: listItem.media?.castImagePaths ?? [],
                                castCharacters: listItem.media?.castCharacters ?? []
                            )

                            if listItem.tvShow != nil, let total = listItem.tvShow?.numberOfSeasons, total > 0 {
                                Divider().padding(.vertical, 4)
                                SeasonChecklistCard(listItem: $listItem)
                            }

                            Divider().padding(.vertical, 4)

                            WatchedToggleCard(listItem: $listItem)

                            if let customListVM = customListViewModel, !customListVM.customLists.isEmpty {
                                Divider().padding(.vertical, 4)

                                Button {
                                    showingAddToList = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "tray.full")
                                            .font(.body)
                                        Text("Add to List")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .glassEffect(.regular.tint(.indigo.opacity(0.15)).interactive(), in: .rect(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .sheet(isPresented: $showingAddToList) {
                                    AddToListSheet(
                                        viewModel: customListVM,
                                        movie: listItem.movie,
                                        tvShow: listItem.tvShow
                                    )
                                }
                            }

                            if let tmdbURL {
                                Divider().padding(.vertical, 4)

                                Button {
                                    showingTMDBPage = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "film")
                                            .font(.body)
                                        Text("View on TMDB")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .sheet(isPresented: $showingTMDBPage) {
                                    SafariView(url: tmdbURL)
                                        .ignoresSafeArea()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    }
                    .padding(.horizontal, 12)
                    .offset(y: -40)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(AppBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) {
                        isConfirmingRemoval = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .accessibilityLabel("Remove from list")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("Done")
                    }
                }
            }
            .task {
                if needsFullDetails {
                    await fetchFullDetails()
                }
            }
            .alert("Remove from list?", isPresented: $isConfirmingRemoval) {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete this title from your watch list.")
            }
        }
    }

    @MainActor
    private func fetchFullDetails() async {
        guard let media = listItem.media,
            let id = Int(media.id)
        else { return }

        isLoadingDetails = true
        detailError = nil

        do {
            if let tvShow = listItem.tvShow {
                let previousSeasonCount = tvShow.numberOfSeasons
                async let detailTask = service.getTVShowDetails(id: id)
                async let providersTask = service.getTVShowWatchProviders(id: id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                let updatedTVShow = service.mapToTVShow(detail, providers: providers)

                tvShow.numberOfSeasons = updatedTVShow.numberOfSeasons
                tvShow.numberOfEpisodes = updatedTVShow.numberOfEpisodes
                tvShow.descriptionText = updatedTVShow.descriptionText
                tvShow.cast = updatedTVShow.cast
                tvShow.castImagePaths = updatedTVShow.castImagePaths
                tvShow.castCharacters = updatedTVShow.castCharacters
                tvShow.genres = updatedTVShow.genres
                tvShow.networks = updatedTVShow.networks
                tvShow.providerCategories = updatedTVShow.providerCategories
                tvShow.seasonEpisodeCounts = updatedTVShow.seasonEpisodeCounts
                if updatedTVShow.thumbnailURL != nil {
                    tvShow.thumbnailURL = updatedTVShow.thumbnailURL
                }

                if let newCount = updatedTVShow.numberOfSeasons,
                   previousSeasonCount != nil,
                   newCount > (previousSeasonCount ?? 0) {
                    onSeasonCountChanged?(listItem, previousSeasonCount)
                }
            } else if let movie = listItem.movie {
                async let detailTask = service.getMovieDetails(id: id)
                async let providersTask = service.getMovieWatchProviders(id: id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                let updatedMovie = service.mapToMovie(detail, providers: providers)

                movie.runtime = updatedMovie.runtime
                movie.descriptionText = updatedMovie.descriptionText
                movie.cast = updatedMovie.cast
                movie.castImagePaths = updatedMovie.castImagePaths
                movie.castCharacters = updatedMovie.castCharacters
                movie.genres = updatedMovie.genres
                movie.networks = updatedMovie.networks
                movie.providerCategories = updatedMovie.providerCategories
                movie.releaseDate = updatedMovie.releaseDate
                if updatedMovie.thumbnailURL != nil {
                    movie.thumbnailURL = updatedMovie.thumbnailURL
                }
            }
        } catch {
            detailError = error.localizedDescription
        }

        isLoadingDetails = false
    }

}

private struct DetailProviderRow: View {
    let visibleNetworks: [Network]
    let hiddenNetworks: [Network]
    let providerCategories: [Int: String]
    @Binding var showingHiddenProviders: Bool
    @State private var tooltipNetworkID: Int?

    private let logoSize: CGFloat = 44

    private var hasCategories: Bool {
        !providerCategories.isEmpty
    }

    private var streamNetworks: [Network] {
        visibleNetworks.filter { providerCategories[$0.id] == "stream" }
    }

    private var adsNetworks: [Network] {
        visibleNetworks.filter { providerCategories[$0.id] == "ads" }
    }

    private var rentOrBuyNetworks: [Network] {
        visibleNetworks.filter { providerCategories[$0.id] == "rent" || providerCategories[$0.id] == "buy" }
    }

    var body: some View {
        if visibleNetworks.isEmpty && !hiddenNetworks.isEmpty {
            Button {
                showingHiddenProviders = true
            } label: {
                Text("Available on \(hiddenNetworks.count) provider\(hiddenNetworks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .popover(isPresented: $showingHiddenProviders) {
                HiddenProvidersPopover(networks: hiddenNetworks, providerCategories: providerCategories)
            }
        } else if !visibleNetworks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if hasCategories {
                    providerSection("Stream", networks: streamNetworks)
                    providerSection("Free with Ads", networks: adsNetworks)
                    providerSection("Rent or Buy", networks: rentOrBuyNetworks)
                } else {
                    providerLogoRow(networks: visibleNetworks)
                }

                if !hiddenNetworks.isEmpty {
                    Button {
                        showingHiddenProviders = true
                    } label: {
                        Text("+\(hiddenNetworks.count) hidden provider\(hiddenNetworks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .popover(isPresented: $showingHiddenProviders) {
                        HiddenProvidersPopover(networks: hiddenNetworks, providerCategories: providerCategories)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ title: String, networks: [Network]) -> some View {
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                providerLogoRow(networks: networks)
            }
        }
    }

    private func providerLogoRow(networks: [Network]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(networks, id: \.id) { network in
                    providerLogo(for: network)
                        .onTapGesture {
                            tooltipNetworkID = tooltipNetworkID == network.id ? nil : network.id
                        }
                        .popover(isPresented: Binding(
                            get: { tooltipNetworkID == network.id },
                            set: { if !$0 { tooltipNetworkID = nil } }
                        )) {
                            Text(network.name)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .presentationCompactAdaptation(.popover)
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func providerLogo(for network: Network) -> some View {
        Group {
            if let logoURL = TMDBService.shared.imageURL(path: network.logoPath, size: .w92) {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(4)
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .frame(width: logoSize, height: logoSize)
        .background(Color.white.opacity(0.85), in: .rect(cornerRadius: logoSize * 0.19))
        .glassEffect(.regular, in: .rect(cornerRadius: logoSize * 0.19))
    }
}

private struct HiddenProvidersPopover: View {
    let networks: [Network]
    let providerCategories: [Int: String]

    private var hasCategories: Bool { !providerCategories.isEmpty }

    private func networksFor(_ categories: Set<String>) -> [Network] {
        networks.filter { categories.contains(providerCategories[$0.id] ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hidden Providers")
                .font(.subheadline)
                .fontWeight(.semibold)

            if hasCategories {
                hiddenSection("Stream", networks: networksFor(["stream"]))
                hiddenSection("Free with Ads", networks: networksFor(["ads"]))
                hiddenSection("Rent or Buy", networks: networksFor(["rent", "buy"]))
            } else {
                ForEach(networks, id: \.id) { network in
                    hiddenProviderRow(network)
                }
            }

            Text("Update your providers in Settings")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func hiddenSection(_ title: String, networks: [Network]) -> some View {
        if !networks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                ForEach(networks, id: \.id) { network in
                    hiddenProviderRow(network)
                }
            }
        }
    }

    private func hiddenProviderRow(_ network: Network) -> some View {
        HStack(spacing: 10) {
            if let logoURL = TMDBService.shared.imageURL(path: network.logoPath, size: .w92) {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(3)
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.85), in: .rect(cornerRadius: 6))
            }
            Text(network.name)
                .font(.subheadline)
        }
    }
}

private struct MetadataRow: View {
    let listItem: ListItem

    var body: some View {
        HStack(spacing: 8) {
            if let tvShow = listItem.tvShow {
                if let seasons = tvShow.numberOfSeasons {
                    MetadataPill(text: "\(seasons) Season\(seasons == 1 ? "" : "s")")
                }
                if let episodes = tvShow.numberOfEpisodes {
                    MetadataPill(text: "\(episodes) Episodes")
                }
            } else if let movie = listItem.movie {
                if let year = movie.releaseYear {
                    MetadataPill(text: year)
                }
                if let runtime = movie.runtime {
                    MetadataPill(text: "\(runtime) min")
                }
            }
        }
    }
}

private struct MetadataPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct WatchedToggleCard: View {
    @Binding var listItem: ListItem

    private var seasonSubtitle: String? {
        guard let tvShow = listItem.tvShow,
              let total = tvShow.numberOfSeasons, total > 0
        else { return nil }
        let count = listItem.watchedSeasons.count
        if listItem.isWatched {
            return "Watched"
        } else if count > 0 {
            return "\(count) of \(total) seasons"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listItem.isWatched ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(listItem.isWatched ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mark as Watched")
                    .font(.headline)
                if let subtitle = seasonSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if listItem.isWatched {
                    Text("Watched")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { listItem.isWatched },
                set: { newValue in
                    if let tvShow = listItem.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                        if newValue {
                            listItem.watchedSeasons = Array(1...total)
                        } else {
                            listItem.watchedSeasons = []
                        }
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date() : nil
                    } else {
                        listItem.isWatched = newValue
                        listItem.watchedAt = newValue ? Date() : nil
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .glassEffect(.regular.tint(listItem.isWatched ? .green.opacity(0.1) : .clear), in: .rect(cornerRadius: 20))
    }
}

private struct SeasonChecklistCard: View {
    @Binding var listItem: ListItem

    private var totalSeasons: Int {
        listItem.tvShow?.numberOfSeasons ?? 0
    }

    private var episodeCounts: [Int] {
        listItem.tvShow?.seasonEpisodeCounts ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.headline)

            VStack(spacing: 6) {
                ForEach(1...max(totalSeasons, 1), id: \.self) { season in
                    seasonRow(season: season)
                }
            }
        }
    }

    private func seasonRow(season: Int) -> some View {
        let isWatched = listItem.watchedSeasons.contains(season)
        let episodeCount = season <= episodeCounts.count ? episodeCounts[season - 1] : nil

        return Button {
            if isWatched {
                listItem.watchedSeasons.removeAll { $0 == season }
            } else {
                listItem.watchedSeasons.append(season)
            }
            listItem.syncWatchedStateFromSeasons()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isWatched ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Season \(season)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if let count = episodeCount, count > 0 {
                        Text("\(count) episode\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(isWatched ? .green.opacity(0.1) : .indigo.opacity(0.07)).interactive(), in: .capsule)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderImageView: View {
    let imageURL: URL?

    var body: some View {
        Group {
            if let imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 350)
                    case .success(let image):
                        ZStack(alignment: .bottom) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 350)
                                .clipped()

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.black.opacity(0.3), location: 0.4),
                                    .init(color: Color.black.opacity(0.8), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    case .failure:
                        Color.gray.frame(height: 350)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Color.gray.frame(height: 350)
            }
        }
    }
}

private struct DescriptionSection: View {
    let isLoading: Bool
    let descriptionText: String?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading details...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let descriptionText, !descriptionText.isEmpty {
                Text(descriptionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GenreSection: View {
    let genres: [String]

    var body: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct CastSection: View {
    let cast: [String]
    let castImagePaths: [String]
    let castCharacters: [String]

    private let imageSize: CGFloat = 64
    private let itemWidth: CGFloat = 80

    var body: some View {
        if cast.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(cast.prefix(10).enumerated()), id: \.offset) { index, member in
                            castItem(index: index, name: member)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func castItem(index: Int, name: String) -> some View {
        VStack(spacing: 6) {
            castImage(index: index)
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())

            Text(name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            let character = index < castCharacters.count ? castCharacters[index] : ""
            if !character.isEmpty {
                Text(character)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: itemWidth)
    }

    @ViewBuilder
    private func castImage(index: Int) -> some View {
        let path = index < castImagePaths.count ? castImagePaths[index] : ""
        if let url = TMDBService.shared.imageURL(path: path.isEmpty ? nil : path, size: .w185) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    castPlaceholder
                }
            }
        } else {
            castPlaceholder
        }
    }

    private var castPlaceholder: some View {
        Image(systemName: "person.fill")
            .font(.title2)
            .foregroundStyle(.tertiary)
            .frame(width: imageSize, height: imageSize)
            .glassEffect(.regular, in: .circle)
    }
}

// MARK: - Preview

private enum MediaDetailViewPreviewData {
    static let user = UserIdentity(id: "preview-user", displayName: "Preview User")
    static let list = MediaList(name: "My Watchlist", createdBy: user, createdAt: Date())

    static let netflix = Network(
        id: 213,
        name: "Netflix",
        logoPath: "/wwemzKWzjKYJFfCeiB57q3r4Bcm.png",
        originCountry: "US"
    )

    static let hbo = Network(
        id: 49,
        name: "HBO",
        logoPath: "/tuomPhY2UtuPTqqFnKMVHvSb724.png",
        originCountry: "US"
    )

    static func movieItem() -> ListItem {
        let movie = Movie(
            id: "603692",
            title: "John Wick: Chapter 4",
            thumbnailURL: URL(
                string: "https://image.tmdb.org/t/p/w500/vZloFAK7NmvMGKE7VkF5UHaz0I.jpg"),
            networks: [netflix],
            descriptionText:
                "With the price on his head ever increasing, John Wick uncovers a path to defeating the High Table.",
            cast: ["Keanu Reeves", "Donnie Yen", "Bill Skarsgard", "Ian McShane"],
            releaseDate: "2023-03-24",
            runtime: 169
        )

        return ListItem(
            movie: movie,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: false,
            watchedAt: nil,
            order: 0
        )
    }

    static func tvShowItem() -> ListItem {
        let show = TVShow(
            id: "1399",
            title: "Game of Thrones",
            thumbnailURL: URL(
                string: "https://image.tmdb.org/t/p/w500/u3bZgnGQ9T01sWNhyveQz0wH0Hl.jpg"),
            networks: [hbo],
            descriptionText:
                "Nine noble families wage war against each other to gain control over the mythical land of Westeros.",
            cast: ["Emilia Clarke", "Kit Harington", "Peter Dinklage", "Lena Headey"],
            numberOfSeasons: 8,
            numberOfEpisodes: 73
        )

        return ListItem(
            tvShow: show,
            list: list,
            addedBy: user,
            addedAt: Date(),
            isWatched: true,
            watchedAt: Date(),
            order: 1
        )
    }
}

private struct MediaDetailPreviewContainer: View {
    @State var listItem: ListItem

    var body: some View {
        MediaDetailView(
            listItem: $listItem,
            dismiss: {},
            onRemove: {}
        )
    }
}

#Preview("Movie") {
    MediaDetailPreviewContainer(listItem: MediaDetailViewPreviewData.movieItem())
}

#Preview("TV Show") {
    MediaDetailPreviewContainer(listItem: MediaDetailViewPreviewData.tvShowItem())
}
