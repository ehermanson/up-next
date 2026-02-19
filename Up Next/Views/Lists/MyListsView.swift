import SwiftUI

struct MyListsView: View {
    let viewModel: CustomListViewModel
    @State private var showingCreateList = false
    @State private var editingList: CustomList?
    @State private var navigationPath = NavigationPath()
    @State private var listToDelete: CustomList?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.customLists.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "No lists yet",
                        subtitle: "Create a collection to organize your favorites."
                    ) {
                        Button {
                            showingCreateList = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Create List")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.tint(.indigo.opacity(0.3)).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(AppBackground())
                } else {
                    GlassEffectContainer(spacing: 8) {
                        List {
                            ForEach(viewModel.customLists, id: \.id) { list in
                                Button {
                                    viewModel.activeListID = list.id
                                    navigationPath.append(list.id)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: list.iconName)
                                            .font(.title2)
                                            .frame(width: 48, height: 48)
                                            .glassEffect(.regular.tint(.indigo.opacity(0.15)), in: .rect(cornerRadius: 12))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(list.name)
                                                .font(.body)
                                                .fontWeight(.medium)
                                            Text("\(list.items?.count ?? 0) item\((list.items?.count ?? 0) == 1 ? "" : "s")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 20))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        listToDelete = list
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        editingList = list
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .background(AppBackground())
                }
            }
            .navigationTitle("My Lists")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreateList = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { listID in
                if let list = viewModel.customLists.first(where: { $0.id == listID }) {
                    CustomListDetailView(viewModel: viewModel, list: list)
                        .onDisappear {
                            if navigationPath.isEmpty {
                                viewModel.activeListID = nil
                            }
                        }
                }
            }
            .sheet(isPresented: $showingCreateList) {
                CreateListView(viewModel: viewModel)
            }
            .sheet(item: $editingList) { list in
                CreateListView(viewModel: viewModel, existingList: list)
            }
            .alert(
                "Delete List",
                isPresented: Binding(
                    get: { listToDelete != nil },
                    set: { if !$0 { listToDelete = nil } }
                ),
                presenting: listToDelete
            ) { list in
                Button("Delete", role: .destructive) {
                    viewModel.deleteList(list)
                    listToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    listToDelete = nil
                }
            } message: { list in
                Text("Are you sure you want to delete \"\(list.name)\"? This action cannot be undone.")
            }
        }
    }
}
