import SwiftUI

struct CreateListView: View {
    let viewModel: CustomListViewModel
    var existingList: CustomList?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    private var isEditing: Bool { existingList != nil }
    private let cardRadius: CGFloat = 24

    init(viewModel: CustomListViewModel, existingList: CustomList? = nil) {
        self.viewModel = viewModel
        self.existingList = existingList
        // Seeded here (not `onAppear`) so the fields never flash empty before filling in on edit.
        _name = State(initialValue: existingList?.name ?? "")
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

    /// Editing shows the collection's own mosaic; a new collection shows the empty grid it will
    /// fill in, so the sheet previews what the row will look like.
    private var mosaicURLs: [URL?] {
        guard let existingList else { return [] }
        return viewModel.visibleItems(in: existingList)
            .sorted { $0.addedAt < $1.addedAt }
            .prefix(4)
            .map { $0.media?.thumbnailURL }
    }

    /// Tappable name starters for a new collection — the sheet's only other content once the
    /// icon picker went (the poster mosaic identifies a collection now). A holiday leads in the
    /// months before it; names the user already has are left out.
    private var nameIdeas: [String] {
        let seasonal: [String] = switch Calendar.current.component(.month, from: .now) {
        case 8, 9: ["Halloween"]
        case 10: ["Halloween", "Holiday Movies"]
        case 11, 12: ["Holiday Movies"]
        default: []
        }
        let ideas = seasonal + [
            "Date Night", "Family Movie Night", "Comfort Rewatches", "Award Winners",
            "Watch Together", "Classics", "Documentaries", "Guilty Pleasures",
        ]
        return ideas.filter { idea in
            !viewModel.customLists.contains { $0.name.localizedCaseInsensitiveCompare(idea) == .orderedSame }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        PosterMosaicView(posterURLs: mosaicURLs, size: 80)

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

                        Text("Titles in a collection stay out of Up Next, and watching them here doesn’t change your Movies or TV Shows tabs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .cardSurface(cornerRadius: cardRadius)
                    .padding(.horizontal, 12)

                    if !isEditing, !nameIdeas.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ideas")
                                .font(.headline)
                                .padding(.horizontal, 4)

                            FlowLayout(spacing: 8) {
                                ForEach(nameIdeas, id: \.self) { idea in
                                    Button {
                                        name = idea
                                    } label: {
                                        // Not `Chip`: that's a caption-sized label, too small a
                                        // target for something you tap.
                                        Text(idea)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(trimmedName == idea ? .primary : .secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .chipSurface(tint: trimmedName == idea ? .accentColor : nil)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .cardSurface(cornerRadius: cardRadius)
                        .padding(.horizontal, 12)
                    }
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
            viewModel.renameList(existing, to: trimmedName)
        } else {
            viewModel.createList(name: trimmedName)
        }
        dismiss()
    }
}
