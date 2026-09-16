import SwiftData
import SwiftUI

struct CustomListDetailView: View {
    let viewModel: CustomListViewModel
    let list: CustomList
    @State private var showingAddItems = false
    @State private var selectedItem: CustomListItem?
    @State private var itemToDelete: CustomListItem?

    var body: some View {
        Group {
            if list.items?.isEmpty ?? true {
                EmptyStateView(icon: list.iconName, title: "No items yet") {
                    Button {
                        showingAddItems = true
                    } label: {
                        Label("Add Items", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                .background(AppBackground())
            } else {
                List {
                    ForEach((list.items ?? []).sorted(by: { $0.addedAt < $1.addedAt }), id: \.persistentModelID) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            MediaCardView(
                                title: item.media?.title ?? "",
                                subtitle: customListSubtitle(for: item),
                                imageURL: item.media?.thumbnailURL,
                                networks: item.media?.networks ?? [],
                                providerCategories: item.media?.providerCategories ?? [:],
                                isWatched: false,
                                voteAverage: item.media?.voteAverage,
                                genres: item.media?.genres ?? []
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                itemToDelete = item
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .padding(.horizontal, 12)
                .background(AppBackground())
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Items", systemImage: "plus") {
                    showingAddItems = true
                }
            }
        }
        .toastOverlay()
        .sheet(isPresented: $showingAddItems) {
            WatchlistSearchView(
                context: .specificList(list),
                existingTVShowIDs: [],
                existingMovieIDs: [],
                onTVShowAdded: { _ in },
                onMovieAdded: { _ in },
                customListViewModel: viewModel
            )
        }
        .sheet(item: $selectedItem) { item in
            CustomListItemDetailView(item: item)
        }
        .alert(
            "Remove from List",
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button("Remove", role: .destructive) {
                viewModel.removeItem(item, from: list)
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: { item in
            Text("Are you sure you want to remove \"\(item.media?.title ?? "this item")\" from \"\(list.name)\"?")
        }
    }

    private func customListSubtitle(for item: CustomListItem) -> String? {
        if let tvShow = item.tvShow {
            return tvShow.seasonsEpisodesSummary
        } else if let movie = item.movie {
            let parts = [movie.releaseYear, movie.runtime.map { "\($0) min" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
        }
        return nil
    }
}

private struct CustomListItemDetailView: View {
    let item: CustomListItem
    @Environment(\.dismiss) private var dismiss

    @State private var isLoadingDetails = false
    @State private var detailError: String?

    private let service = TMDBService.shared

    private var backdropPath: String? {
        item.tvShow?.backdropPath ?? item.movie?.backdropPath
    }

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
                    HeaderImageView(
                        backdropPath: backdropPath,
                        posterURL: item.media?.thumbnailURL,
                        title: item.media?.title ?? ""
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        metadataRow

                        GenreSection(genres: item.media?.genres ?? [])

                        Divider().padding(.vertical, 4)

                        DescriptionSection(
                            isLoading: isLoadingDetails,
                            descriptionText: item.media?.descriptionText,
                            errorMessage: detailError)

                        Divider().padding(.vertical, 4)

                        CastSection(
                            cast: item.media?.cast ?? [],
                            castImagePaths: item.media?.castImagePaths ?? [],
                            castCharacters: item.media?.castCharacters ?? [])
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(AppBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await fetchFullDetails()
            }
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 8) {
            if let tvShow = item.tvShow {
                if let seasons = tvShow.numberOfSeasons {
                    Chip(text: "\(seasons) Season\(seasons == 1 ? "" : "s")")
                }
                if let episodes = tvShow.numberOfEpisodes {
                    Chip(text: "\(episodes) Episodes")
                }
            } else if let movie = item.movie {
                if let year = movie.releaseYear {
                    Chip(text: year)
                }
                if let runtime = movie.runtime {
                    Chip(text: "\(runtime) min")
                }
            }
        }
    }

    @MainActor
    private func fetchFullDetails() async {
        guard let media = item.media, let id = Int(media.id) else { return }
        // Always refresh (picks up backdrop/providers); only surface loading/errors when the
        // core details are actually missing, mirroring MediaDetailView.
        let showLoading = needsFullDetails
        if showLoading {
            isLoadingDetails = true
            detailError = nil
        }

        do {
            if let tvShow = item.tvShow {
                let detail = try await service.getTVShowDetails(id: id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                tvShow.update(from: await service.mapToTVShow(detail, providers: providers))
            } else if let movie = item.movie {
                let detail = try await service.getMovieDetails(id: id)
                let providers = detail.watchProviders?.results?[service.currentRegion]
                movie.update(from: await service.mapToMovie(detail, providers: providers))
            }
        } catch {
            if showLoading {
                detailError = error.localizedDescription
            }
        }

        isLoadingDetails = false
    }
}

