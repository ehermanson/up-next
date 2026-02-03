import SwiftData
import SwiftUI

struct MediaDetailView: View {
    @Binding var listItem: ListItem
    let dismiss: () -> Void
    let onRemove: () -> Void

    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var isConfirmingRemoval = false

    private let service = TMDBService.shared

    // Check if we need to fetch full details
    private var needsFullDetails: Bool {
        guard let media = listItem.media else { return false }

        // Ensure id is a valid Int
        _ = Int(media.id)

        if let tvShow = listItem.tvShow {
            let missingSeasons = (tvShow.numberOfSeasons == nil)
            let missingCast = tvShow.cast.isEmpty
            if missingSeasons { return true }
            if missingCast { return true }
            return false
        }

        if let movie = listItem.movie {
            let missingRuntime = (movie.runtime == nil)
            let missingCast = movie.cast.isEmpty
            let missingReleaseDate =
                (movie.releaseDate == nil || movie.releaseDate?.isEmpty == true)
            if missingRuntime { return true }
            if missingCast { return true }
            if missingReleaseDate { return true }
            return false
        }

        return false
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    HeaderImageView(
                        imageURL: listItem.media?.thumbnailURL,
                        title: listItem.media?.title ?? ""
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        if let summary = listItem.tvShow?.seasonsEpisodesSummary {
                            Text(summary)
                                .font(.title3)
                                .foregroundColor(.secondary)
                        } else if let movie = listItem.movie, let meta = movieMeta(from: movie) {
                            Text(meta)
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }

                        NetworkLogosView(networks: listItem.media?.networks ?? [])

                        Divider().padding(.vertical, 4)

                        DescriptionSection(
                            isLoading: isLoadingDetails,
                            descriptionText: listItem.media?.descriptionText)

                        Divider().padding(.vertical, 4)

                        CastSection(cast: listItem.media?.cast ?? [])

                        Divider().padding(.vertical, 4)

                        Toggle(
                            isOn: Binding(
                                get: { listItem.isWatched },
                                set: { newValue in
                                    listItem.isWatched = newValue
                                    if newValue {
                                        listItem.watchedAt = Date()
                                    } else {
                                        listItem.watchedAt = nil
                                    }
                                }
                            )
                        ) {
                            Text("Mark as Watched")
                                .font(.headline)
                        }
                        .padding(.top)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle(listItem.media?.title ?? "")
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
                let detail = try await service.getTVShowDetails(id: id)
                let updatedTVShow = await service.mapToTVShow(detail)

                // Update the existing TVShow with full details
                tvShow.numberOfSeasons = updatedTVShow.numberOfSeasons
                tvShow.numberOfEpisodes = updatedTVShow.numberOfEpisodes
                tvShow.descriptionText = updatedTVShow.descriptionText
                tvShow.cast = updatedTVShow.cast
                tvShow.networks = updatedTVShow.networks
                if updatedTVShow.thumbnailURL != nil {
                    tvShow.thumbnailURL = updatedTVShow.thumbnailURL
                }
            } else if let movie = listItem.movie {
                async let detailTask = service.getMovieDetails(id: id)
                async let providersTask = service.getMovieWatchProviders(id: id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                let updatedMovie = await service.mapToMovie(detail, providers: providers)

                // Update the existing Movie with full details
                movie.runtime = updatedMovie.runtime
                movie.descriptionText = updatedMovie.descriptionText
                movie.cast = updatedMovie.cast
                movie.networks = updatedMovie.networks
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

    private func movieMeta(from movie: Movie) -> String? {
        var parts: [String] = []
        if let year = movie.releaseYear {
            parts.append(year)
        }
        if let runtime = movie.runtime {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

private struct HeaderImageView: View {
    let imageURL: URL?
    let title: String

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 250)
                    case .success(let image):
                        ZStack(alignment: .bottom) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)

                            // Gradient overlay for readability
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.clear,
                                    Color.black.opacity(0.7),
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )

                            // Title at bottom
                            if !title.isEmpty {
                                Text(title)
                                    .font(.title2)
                                    .fontWeight(.black)
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 20)
                            }
                        }
                    case .failure:
                        ZStack(alignment: .bottom) {
                            Color.gray.frame(height: 250)

                            if !title.isEmpty {
                                Text(title)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 20)
                            }
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    Color.gray.frame(height: 250)

                    if !title.isEmpty {
                        Text(title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}

private struct DescriptionSection: View {
    let isLoading: Bool
    let descriptionText: String?

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
                        .foregroundColor(.secondary)
                }
            } else if let descriptionText, !descriptionText.isEmpty {
                Text(descriptionText)
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                Text(
                    "This is a placeholder for a detailed description, cast, or other information about this media item."
                )
                .font(.body)
                .foregroundColor(.secondary)
            }
        }
    }
}

private struct CastSection: View {
    let cast: [String]

    var body: some View {
        if cast.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cast.prefix(10), id: \.self) { member in
                            Text(member)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
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
            cast: ["Keanu Reeves", "Donnie Yen", "Bill Skarsgård", "Ian McShane"],
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
