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

    private var selectedTVShow: ListItem? {
        guard let id = expandedTVShowID else { return nil }
        return viewModel.tvShows.first(where: { $0.media?.id == id })
    }

    private var selectedMovie: ListItem? {
        guard let id = expandedMovieID else { return nil }
        return viewModel.movies.first(where: { $0.media?.id == id })
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
    }

    private var tvShowsTab: some View {
        MediaListView(
            allItems: $viewModel.tvShows,
            unwatchedItems: $viewModel.unwatchedTVShows,
            watchedItems: $viewModel.watchedTVShows,
            expandedItemID: $expandedTVShowID,
            navigationTitle: "TV Shows",
            subtitleProvider: { item in
                if let summary = item.tvShow?.seasonsEpisodesSummary {
                    return summary
                }
                return nil
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
            onSearchTapped: nil
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
                }
            )
        }
    }

    private var moviesTab: some View {
        MediaListView(
            allItems: $viewModel.movies,
            unwatchedItems: $viewModel.unwatchedMovies,
            watchedItems: $viewModel.watchedMovies,
            expandedItemID: $expandedMovieID,
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
            onSearchTapped: nil
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

        var parts: [String] = []
        if let year = movie.releaseYear {
            parts.append(year)
        }
        if let runtime = movie.runtime {
            parts.append("\(runtime) min")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
    }
}

#Preview {
    ContentView()
}
