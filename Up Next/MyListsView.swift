import SwiftUI

struct MyListsView: View {
    let viewModel: CustomListViewModel
    @State private var showingCreateList = false
    @State private var editingList: CustomList?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.customLists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, height: 80)
                            .glassEffect(.regular, in: .circle)
                        Text("No lists yet")
                            .font(.title3)
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                        Text("Create a collection to organize your favorites.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                            Text("\(list.items.count) item\(list.items.count == 1 ? "" : "s")")
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
                                        viewModel.deleteList(list)
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
        }
    }
}
