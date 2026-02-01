//
//  ContentView.swift
//  Watch List
//
//  Created by Eric Hermanson on 12/12/25.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    private enum MediaTab: Hashable {
        case tvShows
        case movies
    }

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MediaLibraryViewModel()

    @State private var expandedTVShowID: String? = nil
    @State private var expandedMovieID: String? = nil
    @State private var selectedTab: MediaTab = .tvShows
    @State private var activeSearchMediaType: MediaType?
    @State private var selectedTVGenre: String? = nil
    @State private var selectedMovieGenre: String? = nil
    @State private var selectedTVProviderCategory: String? = nil
    @State private var selectedMovieProviderCategory: String? = nil
    @State private var showingSettings = false

    private var selectedTVShow: ListItem? {
        guard let id = expandedTVShowID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    private var selectedMovie: ListItem? {
        guard let id = expandedMovieID else { return nil }
        return viewModel.movies.first(where: { $0.media?.id == id })
    }

    private var availableTVGenres: [String] {
        Array(Set(viewModel.unwatchedTVShows.flatMap { $0.media?.genres ?? [] })).sorted()
    }

    private var availableMovieGenres: [String] {
        Array(Set(viewModel.unwatchedMovies.flatMap { $0.media?.genres ?? [] })).sorted()
    }

    private var availableTVProviderCategories: [String] {
        providerCategoryLabels(from: viewModel.unwatchedTVShows)
    }

    private var availableMovieProviderCategories: [String] {
        providerCategoryLabels(from: viewModel.unwatchedMovies)
    }

    private var filteredUnwatchedTVShows: [ListItem] {
        filterItems(viewModel.unwatchedTVShows, genre: selectedTVGenre, providerCategory: selectedTVProviderCategory)
    }

    private var filteredUnwatchedMovies: [ListItem] {
        filterItems(viewModel.unwatchedMovies, genre: selectedMovieGenre, providerCategory: selectedMovieProviderCategory)
    }

    private func providerCategoryLabels(from items: [ListItem]) -> [String] {
        var rawCategories = Set<String>()
        for item in items {
            guard let categories = item.media?.providerCategories else { continue }
            for category in categories.values {
                rawCategories.insert(category)
            }
        }
        var labels: [String] = []
        if rawCategories.contains("stream") { labels.append("Stream") }
        if rawCategories.contains("ads") { labels.append("Free with Ads") }
        if rawCategories.contains("rent") || rawCategories.contains("buy") { labels.append("Rent or Buy") }
        return labels
    }

    private func filterItems(_ items: [ListItem], genre: String?, providerCategory: String?) -> [ListItem] {
        var result = items
        if let genre {
            result = result.filter { $0.media?.genres.contains(genre) == true }
        }
        if let providerCategory {
            let rawCategories: Set<String>
            switch providerCategory {
            case "Stream": rawCategories = ["stream"]
            case "Free with Ads": rawCategories = ["ads"]
            case "Rent or Buy": rawCategories = ["rent", "buy"]
            default: rawCategories = []
            }
            result = result.filter { item in
                guard let categories = item.media?.providerCategories.values else { return false }
                return categories.contains(where: { rawCategories.contains($0) })
            }
        }
        return result
    }

    private var allProviderInfo: [ProviderInfo] {
        var counts: [Int: (name: String, logoPath: String?, count: Int)] = [:]
        for item in viewModel.tvShows + viewModel.movies {
            for network in item.media?.networks ?? [] {
                if let existing = counts[network.id] {
                    counts[network.id] = (existing.name, existing.logoPath, existing.count + 1)
                } else {
                    counts[network.id] = (network.name, network.logoPath, 1)
                }
            }
        }
        return counts.map { ProviderInfo(id: $0.key, name: $0.value.name, logoPath: $0.value.logoPath, titleCount: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("TV Shows", systemImage: "tv", value: .tvShows) {
                tvShowsTab
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                moviesTab
            }
        }
        .overlay(alignment: .bottomTrailing) {
            addButton
                .padding(.trailing, 28)
                .padding(.bottom, -6)
        }
        .sheet(isPresented: $showingSettings) {
            ProviderSettingsView(allProviders: allProviderInfo)
        }
        .sheet(item: $activeSearchMediaType) { mediaType in
            SearchView(
                mediaType: mediaType,
                existingIDs: existingIDs(for: mediaType),
                onTVShowAdded: { tvShow in
                    viewModel.addTVShow(tvShow)
                },
                onMovieAdded: { movie in
                    viewModel.addMovie(movie)
                }
            )
        }
        .task {
            await viewModel.configure(modelContext: modelContext)
        }
        .onChange(of: availableTVGenres) {
            if let genre = selectedTVGenre, !availableTVGenres.contains(genre) {
                selectedTVGenre = nil
            }
        }
        .onChange(of: availableMovieGenres) {
            if let genre = selectedMovieGenre, !availableMovieGenres.contains(genre) {
                selectedMovieGenre = nil
            }
        }
        .onChange(of: availableTVProviderCategories) {
            if let cat = selectedTVProviderCategory, !availableTVProviderCategories.contains(cat) {
                selectedTVProviderCategory = nil
            }
        }
        .onChange(of: availableMovieProviderCategories) {
            if let cat = selectedMovieProviderCategory, !availableMovieProviderCategories.contains(cat) {
                selectedMovieProviderCategory = nil
            }
        }
    }

    private var tvShowsTab: some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            filteredUnwatchedItems: filteredUnwatchedTVShows,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedTVShowID,
            availableGenres: availableTVGenres,
            selectedGenre: $selectedTVGenre,
            availableProviderCategories: availableTVProviderCategories,
            selectedProviderCategory: $selectedTVProviderCategory,
            navigationTitle: "TV Shows",
            subtitleProvider: { item in
                guard let tvShow = item.tvShow else { return nil }
                var parts: [String] = []

                // Show "Next Season: S{next}" for partially-watched multi-season shows
                if !item.watchedSeasons.isEmpty,
                   let total = tvShow.numberOfSeasons, total > 1,
                   let next = item.nextSeasonToWatch {
                    let remaining = total - item.watchedSeasons.count
                    if remaining > 1 {
                        parts.append("Next Season: S\(next) (\(remaining) left)")
                    } else {
                        parts.append("Next Season: S\(next)")
                    }
                } else if let summary = tvShow.seasonsEpisodesSummary {
                    parts.append(summary)
                }

                if !tvShow.genres.isEmpty {
                    parts.append(tvShow.genres.prefix(2).joined(separator: ", "))
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            },
            onItemExpanded: { id in
                expandedTVShowID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .tvShow)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .tvShow)
            },
            onSearchTapped: nil,
            onSettingsTapped: { showingSettings = true }
        )
        .sheet(
            item: Binding(
                get: { selectedTVShow },
                set: { _ in expandedTVShowID = nil }
            )
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item, in: $viewModel.tvShows),
                dismiss: {
                    expandedTVShowID = nil
                    viewModel.persistChanges(for: .tvShow)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedTVShowID = nil
                        viewModel.removeItem(withID: id, mediaType: .tvShow)
                    }
                },
                onSeasonCountChanged: { listItem, previousCount in
                    viewModel.handleSeasonCountUpdate(for: listItem, previousSeasonCount: previousCount)
                }
            )
        }
    }

    private var moviesTab: some View {
        MediaListView(
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            filteredUnwatchedItems: filteredUnwatchedMovies,
            watchedItems: $viewModel.watchedMovies,
            expandedItemID: $expandedMovieID,
            availableGenres: availableMovieGenres,
            selectedGenre: $selectedMovieGenre,
            availableProviderCategories: availableMovieProviderCategories,
            selectedProviderCategory: $selectedMovieProviderCategory,
            navigationTitle: "Movies",
            subtitleProvider: { item in
                movieSubtitle(for: item)
            },
            onItemExpanded: { id in
                expandedMovieID = id
            },
            onWatchedToggled: {
                viewModel.persistChanges(for: .movie)
            },
            onOrderChanged: {
                viewModel.updateOrderAfterUnwatchedMove(mediaType: .movie)
            },
            onSearchTapped: nil,
            onSettingsTapped: { showingSettings = true }
        )
        .sheet(
            item: Binding(
                get: { selectedMovie },
                set: { _ in expandedMovieID = nil }
            )
        ) { item in
            MediaDetailView(
                listItem: binding(forItem: item, in: $viewModel.movies),
                dismiss: {
                    expandedMovieID = nil
                    viewModel.persistChanges(for: .movie)
                },
                onRemove: {
                    if let id = item.media?.id {
                        expandedMovieID = nil
                        viewModel.removeItem(withID: id, mediaType: .movie)
                    }
                }
            )
        }
    }

    private var addButton: some View {
        Button {
            activeSearchMediaType = selectedTab == .tvShows ? .tvShow : .movie
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .glassEffect(.regular.tint(.indigo.opacity(0.5)).interactive(), in: .circle)
        }
        .shadow(color: Color.indigo.opacity(0.3), radius: 12, x: 0, y: 6)
        .accessibilityLabel("Add \(selectedTab == .tvShows ? "TV show" : "movie")")
    }

    private func binding(forItem item: ListItem, in array: Binding<[ListItem]>) -> Binding<ListItem>
    {
        Binding(
            get: {
                array.wrappedValue.first(where: { $0.media?.id == item.media?.id }) ?? item
            },
            set: { newValue in
                guard
                    let id = item.media?.id,
                    let index = array.wrappedValue.firstIndex(where: { $0.media?.id == id })
                else { return }
                array.wrappedValue[index] = newValue
            }
        )
    }

    private func existingIDs(for mediaType: MediaType) -> Set<String> {
        let items = mediaType == .tvShow ? viewModel.tvShows : viewModel.movies
        return Set(items.compactMap { $0.media?.id })
    }

    private func movieSubtitle(for item: ListItem) -> String? {
        guard let movie = item.movie else { return nil }

        var lines: [String] = []
        var meta: [String] = []
        if let year = movie.releaseYear {
            meta.append(year)
        }
        if let runtime = movie.runtime {
            meta.append("\(runtime) min")
        }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " \u{2022} "))
        }
        if !movie.genres.isEmpty {
            lines.append(movie.genres.prefix(2).joined(separator: ", "))
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

#Preview {
    ContentView()
}
