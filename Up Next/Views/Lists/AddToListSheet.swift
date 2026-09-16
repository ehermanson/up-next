import SwiftUI

struct AddToListSheet: View {
    let viewModel: CustomListViewModel
    let movie: Movie?
    let tvShow: TVShow?
    @Environment(\.dismiss) private var dismiss

    private var mediaID: String? {
        movie?.id ?? tvShow?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.customLists.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "No lists yet",
                        subtitle: "Create a list from the My Lists tab first."
                    )
                    .background(AppBackground())
                } else {
                    List {
                        ForEach(viewModel.customLists, id: \.id) { list in
                            let isInList = mediaID.map { viewModel.containsItem(mediaID: $0, in: list) } ?? false
                            Button {
                                toggleItem(in: list, isInList: isInList)
                            } label: {
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(isInList ? "In list" : "Not in list")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .background(AppBackground())
                }
            }
            .navigationTitle("Add to List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggleItem(in list: CustomList, isInList: Bool) {
        if isInList {
            if let mediaID, let item = list.items?.first(where: { $0.media?.id == mediaID }) {
                viewModel.removeItem(item, from: list)
            }
        } else {
            viewModel.addItem(movie: movie, tvShow: tvShow, to: list)
        }
    }
}
