import SwiftUI

struct CreateListView: View {
    let viewModel: CustomListViewModel
    var existingList: CustomList?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var iconName: String = "list.bullet"

    private var isEditing: Bool { existingList != nil }
    private let cardRadius: CGFloat = 24
    @ScaledMetric private var iconSize: CGFloat = 40

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Image(systemName: iconName)
                            .font(.system(size: iconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 80, height: 80)
                            .background(.fill.tertiary, in: .circle)

                        TextField("Collection Name", text: $name)
                            .font(.title3)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.fill.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.control))

                        Text("Titles in a collection stay out of Up Next. Mark one watched and it shows up in your Watched history.")
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

                        ScrollView {
                            SFSymbolPickerGrid(selectedSymbol: $iconName)
                                .padding(.bottom, 8)
                        }
                        .frame(maxHeight: 400)
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
                    Button(isEditing ? "Save" : "Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if let existing = existingList {
                            viewModel.updateList(existing, name: trimmed, iconName: iconName)
                        } else {
                            viewModel.createList(name: trimmed, iconName: iconName)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let existing = existingList {
                    name = existing.name
                    iconName = existing.iconName
                }
            }
        }
    }
}
