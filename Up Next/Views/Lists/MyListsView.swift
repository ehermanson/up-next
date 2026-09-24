import SwiftUI

struct MyListsView: View {
    let viewModel: CustomListViewModel
    var onSettingsTapped: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingCreateList = false
    /// A collection just made in the create sheet, opened once the sheet has finished dismissing
    /// (pushing mid-dismiss animates both at once).
    @State private var createdListID: UUID?
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
                    .background(AppBackground(drifts: true))
                } else {
                    List {
                        ForEach(viewModel.customLists, id: \.id) { list in
                            MyListsRow(viewModel: viewModel, list: list) {
                                viewModel.activeListID = list.id
                                navigationPath.append(list.id)
                            }
                            .listRowInsets(EdgeInsets(
                                top: 6,
                                leading: DesignTokens.Spacing.screenInset,
                                bottom: 6,
                                trailing: DesignTokens.Spacing.screenInset
                            ))
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
                    // One row card stretched across an iPad reads as a banner; cap the column and
                    // center it, letting the background still fill the window.
                    .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
                    .frame(maxWidth: .infinity)
                    .background(AppBackground(drifts: true))
                }
            }
            .navigationTitle("Collections")
            .tabRootNavigationBar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Collection", systemImage: "plus") {
                        showingCreateList = true
                    }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    SettingsToolbarButton(action: onSettingsTapped)
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
                } else {
                    // The partner deleted this collection (or stopped sharing) while it was on
                    // screen or in the nav stack — the id no longer resolves to anything.
                    EmptyStateView(icon: "tray", title: "This Collection Was Removed")
                        .background(AppBackground())
                }
            }
            .sheet(isPresented: $showingCreateList, onDismiss: openCreatedList) {
                CreateListView(viewModel: viewModel) { createdListID = $0.id }
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
                Text("Are you sure you want to delete \u{201C}\(list.name)\u{201D}? This action cannot be undone.")
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

    private func openCreatedList() {
        guard let id = createdListID else { return }
        createdListID = nil
        viewModel.activeListID = id
        navigationPath.append(id)
    }
}

/// One row in the collections overview. `@ObservedObject` so a rename on this `NSManagedObject`
/// re-renders the row — unlike SwiftData's `@Model`, Core Data objects don't republish view
/// updates unless something observes them. A child `CustomListItem` changing (add/remove) doesn't
/// republish `list` either, so the mosaic reads `viewModel.changeToken` to stay in sync.
private struct MyListsRow: View {
    let viewModel: CustomListViewModel
    @ObservedObject var list: CustomList
    let action: () -> Void

    /// First four items, ordered like the detail view's unwatched section (oldest add first).
    /// Touching `viewModel.changeToken` (bumped on every mutation) is what makes this recompute
    /// when a sibling row's `CustomListItem` is added/removed — see CLAUDE.md's Collections UI note.
    private var mosaicItems: [CustomListItem] {
        viewModel.visibleItems(in: list).sorted { $0.addedAt < $1.addedAt }.prefix(4).map { $0 }
    }

    /// `visibleItems(in:)`, not `list.items?.count`, so a pending swipe-delete (Undo window)
    /// disappears from the count immediately instead of lagging behind the mosaic/detail view.
    private var itemCount: Int { viewModel.visibleItems(in: list).count }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                PosterMosaicView(posterURLs: mosaicItems.map { $0.media?.thumbnailURL }, size: 64)

                VStack(alignment: .leading, spacing: 3) {
                    Text(list.name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text("\(itemCount) title\(itemCount == 1 ? "" : "s")")
                        .font(.caption)
                        .fontDesign(.rounded)
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
    }
}
