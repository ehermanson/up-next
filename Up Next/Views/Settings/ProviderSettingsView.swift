import SwiftUI

struct ProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [TMDBWatchProviderInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let settings = ProviderSettings.shared

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
    ]

    @ScaledMetric private var errorIconSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    descriptionSection

                    if isLoading {
                        loadingView
                    } else if let error = errorMessage {
                        errorView(message: error)
                    } else {
                        providerGrid
                    }

                    TMDBAttributionView()
                        .padding(.top, 16)

                    #if DEBUG
                    debugSection
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AppBackground())
            .navigationTitle("Your Streaming Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadProviders()
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select the streaming services you subscribe to. Your selections are highlighted first on library cards.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading providers...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: errorIconSize))
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await loadProviders()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Provider Grid

    private var providerGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(providers) { provider in
                ProviderGridCell(
                    provider: provider,
                    isSelected: settings.selectedProviderIDs.contains(provider.id)
                ) {
                    settings.toggleProvider(provider.id)
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: - Data Loading

    private func loadProviders() async {
        isLoading = true
        errorMessage = nil

        do {
            providers = try await TMDBService.shared.fetchWatchProviders()
            isLoading = false
        } catch {
            errorMessage = "Unable to load streaming services. Please check your connection and try again."
            isLoading = false
        }
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.vertical, 8)

            Text("Debug Options")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                settings.selectedProviderIDs = []
                dismiss()
            } label: {
                Label("Reset Provider Selection", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(.top, 24)
    }
    #endif
}

// MARK: - Provider Grid Cell

private struct ProviderGridCell: View {
    let provider: TMDBWatchProviderInfo
    let isSelected: Bool
    let onTap: () -> Void

    @ScaledMetric private var badgeSize: CGFloat = 20

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    providerLogo

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: badgeSize))
                            .foregroundStyle(.white, .green)
                            .offset(x: 4, y: 4)
                    }
                }

                Text(provider.providerName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .cellSurface(cornerRadius: DesignTokens.Radius.control, tint: isSelected ? .accentColor : nil)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityLabel(provider.providerName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var providerLogo: some View {
        Group {
            if let logoURL = TMDBService.shared.imageURL(path: provider.logoPath, size: .w92) {
                CachedAsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        placeholderLogo
                    }
                }
            } else {
                placeholderLogo
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.cell))
        .background(Color.white.opacity(0.85), in: .rect(cornerRadius: DesignTokens.Radius.cell))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.cell)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
    }

    private var placeholderLogo: some View {
        Image(systemName: "play.tv")
            .font(.title2)
            .foregroundStyle(.gray)
    }
}
