import SwiftUI

struct CreateListView: View {
    let viewModel: CustomListViewModel
    var existingList: CustomList?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var iconName: String
    @FocusState private var isNameFocused: Bool

    private var isEditing: Bool { existingList != nil }
    private let cardRadius: CGFloat = 24
    @ScaledMetric private var iconSize: CGFloat = 40

    init(viewModel: CustomListViewModel, existingList: CustomList? = nil) {
        self.viewModel = viewModel
        self.existingList = existingList
        // Seeded here (not `onAppear`) so the fields never flash empty before filling in on edit.
        _name = State(initialValue: existingList?.name ?? "")
        _iconName = State(initialValue: existingList?.iconName ?? "list.bullet")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A soft nudge, not a block — collections are allowed to share a name (e.g. two "Favorites").
    private var duplicateNameHint: String? {
        guard !trimmedName.isEmpty else { return nil }
        let hasDuplicate = viewModel.customLists.contains {
            $0 !== existingList && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
        return hasDuplicate ? "You already have a collection named \u{201C}\(trimmedName)\u{201D}." : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Image(systemName: iconName)
                            .font(.system(size: iconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 80, height: 80)
                            .cellSurface(cornerRadius: 40)

                        TextField("Collection Name", text: $name)
                            .font(.title3)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .cellSurface(cornerRadius: DesignTokens.Radius.control)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .onSubmit(commit)

                        if let duplicateNameHint {
                            Text(duplicateNameHint)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }

                        Text("Titles in a collection stay out of Up Next, and watching them here doesn't change your Movies or TV Shows tabs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .cardSurface(cornerRadius: cardRadius)
                    .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Icon")
                            .font(.headline)
                            .padding(.horizontal, 4)

                        SFSymbolPickerGrid(selectedSymbol: $iconName)
                    }
                    .padding(20)
                    .cardSurface(cornerRadius: cardRadius)
                    .padding(.horizontal, 12)
                }
                .padding(.top, 16)
            }
            .background(AppBackground())
            .navigationTitle(isEditing ? "Edit Collection" : "New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create", action: commit)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { isNameFocused = true }
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        if let existing = existingList {
            viewModel.updateList(existing, name: trimmedName, iconName: iconName)
        } else {
            viewModel.createList(name: trimmedName, iconName: iconName)
        }
        dismiss()
    }
}
