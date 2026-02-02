import SwiftUI

struct CustomListDetailView: View {
    let viewModel: CustomListViewModel
    let list: CustomList
    @State private var showingAddItems = false
    @State private var selectedItem: CustomListItem?

    var body: some View {
        Group {
            if list.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: list.iconName)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, height: 80)
                        .glassEffect(.regular, in: .circle)
                    Text("No items yet")
                        .font(.title3)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                    Button {
                        showingAddItems = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("Add Items")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(.indigo.opacity(0.3)).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppBackground())
            } else {
                GlassEffectContainer(spacing: 8) {
                    List {
                        ForEach(list.items.sorted(by: { $0.addedAt < $1.addedAt }), id: \.persistentModelID) { item in
                            CustomListItemRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedItem = item
                                }
                        }
                        .onDelete { offsets in
                            let sorted = list.items.sorted(by: { $0.addedAt < $1.addedAt })
                            for index in offsets {
                                viewModel.removeItem(sorted[index], from: list)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
                .background(AppBackground())
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddItems = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddItems) {
            CustomListSearchView(viewModel: viewModel, list: list, isPresented: $showingAddItems)
        }
        .sheet(item: $selectedItem) { item in
            CustomListItemDetailView(item: item)
        }
    }
}

private struct CustomListItemDetailView: View {
    let item: CustomListItem
    @Environment(\.dismiss) private var dismiss

    @State private var isLoadingDetails = false
    @State private var detailError: String?

    private let service = TMDBService.shared

    private var needsFullDetails: Bool {
        guard let media = item.media, Int(media.id) != nil else { return false }
        if let tvShow = item.tvShow {
            if tvShow.cast.isEmpty || tvShow.genres.isEmpty { return true }
            return false
        }
        if let movie = item.movie {
            if movie.cast.isEmpty || movie.genres.isEmpty { return true }
            return false
        }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerImage

                    GlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.media?.title ?? "")
                                .font(.title)
                                .fontWeight(.bold)

                            metadataRow

                            genreSection

                            Divider().padding(.vertical, 4)

                            descriptionSection

                            Divider().padding(.vertical, 4)

                            castSection
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if needsFullDetails {
                    await fetchFullDetails()
                }
            }
        }
    }

    @ViewBuilder
    private var headerImage: some View {
        if let imageURL = item.media?.thumbnailURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView().frame(height: 350)
                case .success(let image):
                    ZStack(alignment: .bottom) {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity).frame(height: 350).clipped()
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: Color.black.opacity(0.3), location: 0.4),
                                .init(color: Color.black.opacity(0.8), location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
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

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 8) {
            if let tvShow = item.tvShow {
                if let seasons = tvShow.numberOfSeasons {
                    metadataPill("\(seasons) Season\(seasons == 1 ? "" : "s")")
                }
                if let episodes = tvShow.numberOfEpisodes {
                    metadataPill("\(episodes) Episodes")
                }
            } else if let movie = item.movie {
                if let year = movie.releaseYear {
                    metadataPill(year)
                }
                if let runtime = movie.runtime {
                    metadataPill("\(runtime) min")
                }
            }
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var genreSection: some View {
        let genres = item.media?.genres ?? []
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

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(.headline)
            if isLoadingDetails {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading details...").font(.body).foregroundStyle(.secondary)
                }
            } else if let error = detailError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.body).foregroundStyle(.secondary)
                }
            } else if let desc = item.media?.descriptionText, !desc.isEmpty {
                Text(desc).font(.body).foregroundStyle(.secondary)
            } else {
                Text("No description available.").font(.body).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var castSection: some View {
        let cast = item.media?.cast ?? []
        let castImagePaths = item.media?.castImagePaths ?? []
        let castCharacters = item.media?.castCharacters ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast").font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(cast.prefix(10).enumerated()), id: \.offset) { index, member in
                            VStack(spacing: 6) {
                                castImage(path: index < castImagePaths.count ? castImagePaths[index] : "")
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                                Text(member)
                                    .font(.caption).fontWeight(.medium)
                                    .lineLimit(2).multilineTextAlignment(.center)
                                let character = index < castCharacters.count ? castCharacters[index] : ""
                                if !character.isEmpty {
                                    Text(character)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                            }
                            .frame(width: 80)
                        }
                    }
                    .padding(.horizontal, 1).padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func castImage(path: String) -> some View {
        if let url = service.imageURL(path: path.isEmpty ? nil : path, size: .w185) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
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
            .font(.title2).foregroundStyle(.tertiary)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .circle)
    }

    @MainActor
    private func fetchFullDetails() async {
        guard let media = item.media, let id = Int(media.id) else { return }
        isLoadingDetails = true
        detailError = nil

        do {
            if let tvShow = item.tvShow {
                let detail = try await service.getTVShowDetails(id: id)
                let updated = service.mapToTVShow(detail)
                tvShow.numberOfSeasons = updated.numberOfSeasons
                tvShow.numberOfEpisodes = updated.numberOfEpisodes
                tvShow.descriptionText = updated.descriptionText
                tvShow.cast = updated.cast
                tvShow.castImagePaths = updated.castImagePaths
                tvShow.castCharacters = updated.castCharacters
                tvShow.genres = updated.genres
            } else if let movie = item.movie {
                async let detailTask = service.getMovieDetails(id: id)
                async let providersTask = service.getMovieWatchProviders(id: id, countryCode: "US")
                let detail = try await detailTask
                let providers = try await providersTask
                let updated = service.mapToMovie(detail, providers: providers)
                movie.runtime = updated.runtime
                movie.descriptionText = updated.descriptionText
                movie.cast = updated.cast
                movie.castImagePaths = updated.castImagePaths
                movie.castCharacters = updated.castCharacters
                movie.genres = updated.genres
                movie.releaseDate = updated.releaseDate
            }
        } catch {
            detailError = error.localizedDescription
        }

        isLoadingDetails = false
    }
}

private struct CustomListItemRow: View {
    let item: CustomListItem
    private let service = TMDBService.shared

    var body: some View {
        HStack(spacing: 12) {
            posterImage
                .frame(width: 60, height: 90)
                .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.media?.title ?? "Unknown")
                    .font(.headline)
                    .fontDesign(.rounded)
                    .lineLimit(2)

                if let tvShow = item.tvShow, let summary = tvShow.seasonsEpisodesSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let movie = item.movie {
                    movieMetadataText(movie: movie)
                }

                if let genres = item.media?.genres, !genres.isEmpty {
                    Text(genres.prefix(2).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(10)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func movieMetadataText(movie: Movie) -> some View {
        let parts = [movie.releaseYear, movie.runtime.map { "\($0) min" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " \u{2022} "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let url = item.media?.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Color.gray.opacity(0.3))
                }
            }
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
        }
    }
}
