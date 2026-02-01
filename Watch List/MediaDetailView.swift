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

    private var needsFullDetails: Bool {
        guard let media = listItem.media, Int(media.id) != nil else { return false }

        if let tvShow = listItem.tvShow {
            if tvShow.numberOfSeasons == nil { return true }
            if tvShow.cast.isEmpty { return true }
            if tvShow.genres.isEmpty { return true }
            return false
        }

        if let movie = listItem.movie {
            if movie.runtime == nil { return true }
            if movie.cast.isEmpty { return true }
            if movie.genres.isEmpty { return true }
            if movie.releaseDate == nil || movie.releaseDate?.isEmpty == true { return true }
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

                            ScrollView(.horizontal) {
                                NetworkLogosView(
                                    networks: listItem.media?.networks ?? [],
                                    maxVisible: .max,
                                    logoSize: 44
                                )
                            }
                            .scrollIndicators(.hidden)

                            Divider().padding(.vertical, 4)

                            DescriptionSection(
                                isLoading: isLoadingDetails,
                                descriptionText: listItem.media?.descriptionText,
                                errorMessage: detailError)

                            Divider().padding(.vertical, 4)

                            CastSection(cast: listItem.media?.cast ?? [])

                            Divider().padding(.vertical, 4)

                            WatchedToggleCard(listItem: $listItem)
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
                let detail = try await service.getTVShowDetails(id: id)
                let updatedTVShow = service.mapToTVShow(detail)

                tvShow.numberOfSeasons = updatedTVShow.numberOfSeasons
                tvShow.numberOfEpisodes = updatedTVShow.numberOfEpisodes
                tvShow.descriptionText = updatedTVShow.descriptionText
                tvShow.cast = updatedTVShow.cast
                tvShow.genres = updatedTVShow.genres
                tvShow.networks = updatedTVShow.networks
                if updatedTVShow.thumbnailURL != nil {
                    tvShow.thumbnailURL = updatedTVShow.thumbnailURL
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
                movie.genres = updatedMovie.genres
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listItem.isWatched ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(listItem.isWatched ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mark as Watched")
                    .font(.headline)
                if listItem.isWatched {
                    Text("Watched")
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { listItem.isWatched },
                set: { newValue in
                    listItem.isWatched = newValue
                    listItem.watchedAt = newValue ? Date() : nil
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .glassEffect(.regular.tint(listItem.isWatched ? .green.opacity(0.1) : .clear), in: .rect(cornerRadius: 20))
    }
}

private struct HeaderImageView: View {
    let imageURL: URL?

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
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

    var body: some View {
        if cast.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(cast.prefix(10), id: \.self) { member in
                            Text(member)
                                .font(.subheadline)
                                            .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(.white.opacity(0.05)), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
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
