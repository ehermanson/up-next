import SwiftUI

struct MyListsView: View {
    let viewModel: CustomListViewModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingCreateList = false
    @State private var editingList: CustomList?
    @State private var navigationPath = NavigationPath()
    @State private var listToDelete: CustomList?
    #if DEBUG
    /// Screenshot mode (`--collection <name>`): pushed once, the first time the named collection
    /// exists — seeding creates it after this view may already be on screen.
    @State private var didOpenRequestedCollection = false
    #endif

    var body: some View {
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
                    // One row card stretched across an iPad reads as a banner; cap the column and
                    // center it, letting the background still fill the window.
                    .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
                    .frame(maxWidth: .infinity)
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
            #if DEBUG
            .onAppear { openRequestedCollectionIfNeeded() }
            .onChange(of: viewModel.customLists.map(\.name)) { openRequestedCollectionIfNeeded() }
            #endif
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

    #if DEBUG
    /// Screenshot mode only: drill into the collection named by `--collection` so the store
    /// screenshot shows a populated collection rather than the overview.
    private func openRequestedCollectionIfNeeded() {
        guard ScreenshotMode.isEnabled, !didOpenRequestedCollection,
              let name = ScreenshotMode.requestedCollectionName,
              let list = viewModel.customLists.first(where: { $0.name == name })
        else { return }
        didOpenRequestedCollection = true
        viewModel.activeListID = list.id
        navigationPath.append(list.id)
    }
    #endif
}
