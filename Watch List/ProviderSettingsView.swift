import SwiftUI

struct ProviderSettingsView: View {
    let allProviders: [ProviderInfo]
    @Environment(\.dismiss) private var dismiss

    private let settings = ProviderSettings.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(allProviders) { provider in
                    ProviderRow(
                        provider: provider,
                        isVisible: !provider.allIDs.contains(where: { settings.isHidden($0) })
                    ) {
                        let ids = provider.allIDs.isEmpty ? Set([provider.id]) : provider.allIDs
                        let shouldHide = !ids.contains(where: { settings.isHidden($0) })
                        settings.setHidden(shouldHide, for: ids)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(AppBackground())
            .navigationTitle("Providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ProviderInfo: Identifiable {
    let id: Int
    let name: String
    let logoPath: String?
    let titleCount: Int
    /// All provider IDs that share this display name (for grouped duplicates like HBO / HBO Max)
    var allIDs: Set<Int> = []
}

private struct ProviderRow: View {
    let provider: ProviderInfo
    let isVisible: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            providerLogo
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body)
                    .fontDesign(.rounded)
                Text("\(provider.titleCount) title\(provider.titleCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.white.opacity(0.05))
    }

    private var providerLogo: some View {
        Group {
            if let logoURL = TMDBService.shared.imageURL(path: provider.logoPath, size: .w92) {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .empty:
                        Color.gray.opacity(0.1)
                    case .success(let image):
                        image.resizable().scaledToFit().padding(4)
                    case .failure:
                        Color.gray.opacity(0.1)
                    @unknown default:
                        Color.gray.opacity(0.1)
                    }
                }
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .frame(width: 36, height: 36)
        .background(Color.white.opacity(0.85), in: .rect(cornerRadius: 7))
        .glassEffect(.regular, in: .rect(cornerRadius: 7))
    }
}
