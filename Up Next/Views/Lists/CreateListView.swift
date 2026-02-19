import SwiftUI

struct CreateListView: View {
    let viewModel: CustomListViewModel
    var existingList: CustomList?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var iconName: String = "list.bullet"

    private var isEditing: Bool { existingList != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: 16) {
                            Image(systemName: iconName)
                                .font(.system(size: 40))
                                .foregroundStyle(.indigo)
                                .frame(width: 80, height: 80)
                                .glassEffect(.regular.tint(.indigo.opacity(0.15)), in: .circle)

                            TextField("List Name", text: $name)
                                .font(.title3)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    }
                    .padding(.horizontal, 12)

                    GlassEffectContainer(spacing: 0) {
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
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 16)
            }
            .background(AppBackground())
            .navigationTitle(isEditing ? "Edit List" : "New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
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
