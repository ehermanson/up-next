import SwiftUI

struct AddToListSheet: View {
    let viewModel: CustomListViewModel
    let movie: Movie?
    let tvShow: TVShow?
    @Environment(\.dismiss) private var dismiss

    @State private var showingCreateList = false

    private var mediaID: String? {
        movie?.id ?? tvShow?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.customLists.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "No collections yet",
                        subtitle: "Collections are for themed groups \u{2014} Christmas movies, kids' shows, comfort watches."
                    ) {
                        Button {
                            showingCreateList = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    .background(AppBackground())
                } else {
                    List {
                        ForEach(viewModel.customLists, id: \.id) { list in
                            let isInList = mediaID.map { viewModel.containsItem(mediaID: $0, mediaType: movie != nil ? .movie : .tvShow, in: list) } ?? false
                            AddToListRow(list: list, isInList: isInList) {
                                toggleItem(in: list, isInList: isInList)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .background(AppBackground())
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !viewModel.customLists.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New Collection", systemImage: "plus") {
                            showingCreateList = true
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCreateList) {
                CreateListView(viewModel: viewModel)
            }
        }
    }

    private func toggleItem(in list: CustomList, isInList: Bool) {
        if isInList {
            if let mediaID, let item = viewModel.item(mediaID: mediaID, mediaType: movie != nil ? .movie : .tvShow, in: list) {
                viewModel.removeItem(item, from: list)
            }
        } else {
            viewModel.addItem(movie: movie, tvShow: tvShow, to: list)
        }
    }
}

/// One row in the "Add to Collection" sheet. `@ObservedObject` so a rename picked up while the
/// sheet is open re-renders — `NSManagedObject` doesn't republish view updates on its own.
private struct AddToListRow: View {
    @ObservedObject var list: CustomList
    let isInList: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: list.iconName)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .cellSurface(tint: .accentColor)

                Text(list.name)
                    .font(.body)
                    .fontWeight(.medium)

                Spacer()

                if isInList {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInList ? "In collection" : "Not in collection")
    }
}
