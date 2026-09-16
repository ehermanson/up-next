import SwiftData
import SwiftUI

struct MyListsView: View {
    let viewModel: CustomListViewModel

    @Environment(ToastState.self) private var toast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingCreateList = false
    @State private var editingList: CustomList?
    @State private var navigationPath = NavigationPath()
    @State private var listToDelete: CustomList?
    /// Owned here so regular width can pin it in the detail column; compact hands it back to
    /// `CustomListDetailView`, which presents it as a sheet.
    @State private var selectedItem: CustomListItem?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // The collections → collection push stays inside the sidebar; the detail column
                // shows whichever title is selected.
                NavigationSplitView {
                    collectionsColumn(pinsSelection: true)
                        // The column already has the list's own title bar; SwiftUI's automatic
                        // toggle would sit at its trailing edge next to New Collection.
                        .toolbar(removing: .sidebarToggle)
                        // Fills the column edge to edge, bar area included — the list's own
                        // `.background(AppBackground())` stops below the navigation bar.
                        .containerBackground(for: .navigation) { AppBackground() }
                        .navigationSplitViewColumnWidth(min: 360, ideal: 440, max: 560)
                } detail: {
                    itemDetailColumn
                        .containerBackground(for: .navigation) { AppBackground() }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                collectionsColumn(pinsSelection: false)
            }
        }
        // A pinned selection must not reappear as a sheet after the window is resized.
        .onChange(of: horizontalSizeClass) { _, _ in
            selectedItem = nil
        }
    }

    /// `pinsSelection` is true only in the regular-width split layout: the detail column pins the
    /// selection, so `CustomListDetailView` must not also present it as a sheet.
    private func collectionsColumn(pinsSelection: Bool) -> some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.customLists.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "No collections yet",
                        subtitle: "Collections like Christmas Movies or Shows for the Kids. They stay out of Up Next until you want them."
                    ) {
                        Button {
                            showingCreateList = true
                        } label: {
                            Label("Create Collection", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .background(AppBackground())
                } else {
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
                                        .cellSurface(tint: .accentColor)

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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .cardSurface()
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
                                .tint(.accentColor)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .padding(.horizontal, 12)
                    .background(AppBackground())
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Collection", systemImage: "plus") {
                        showingCreateList = true
                    }
                }
            }
            .navigationDestination(for: UUID.self) { listID in
                if let list = viewModel.customLists.first(where: { $0.id == listID }) {
                    CustomListDetailView(
                        viewModel: viewModel,
                        list: list,
                        selectedItem: $selectedItem,
                        pinsSelection: pinsSelection
                    )
                    .onDisappear {
                        if navigationPath.isEmpty {
                            viewModel.activeListID = nil
                            selectedItem = nil
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
                "Delete Collection",
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

    // MARK: - Detail column

    /// The pinned counterpart of `CustomListDetailView`'s sheet. `item.customList` is the SwiftData
    /// inverse of `CustomList.items`, so the column always knows which collection it's scoped to.
    @ViewBuilder
    private var itemDetailColumn: some View {
        if let item = selectedItem, let list = item.customList {
            CustomListItemDetailSheet(
                item: item,
                list: list,
                listViewModel: viewModel,
                onRemove: {
                    viewModel.removeWithUndo(
                        item,
                        from: list,
                        toast: toast,
                        animation: CustomListViewModel.rowAnimation
                    )
                    selectedItem = nil
                },
                dismiss: { selectedItem = nil },
                presentedInColumn: true
            )
            // Switching rows must rebuild the sheet so its transient `ListItem` is rebound.
            .id(item.persistentModelID)
        } else {
            EmptyStateView(icon: "tray.full", title: "Select a title")
                .background(AppBackground())
        }
    }
}
