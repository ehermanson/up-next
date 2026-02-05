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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadProviders()
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select the streaming services you subscribe to. Only these will appear on your library items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 16))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
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
                .font(.system(size: 36))
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
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))
    }

    // MARK: - Data Loading

    private func loadProviders() async {
        isLoading = true
        errorMessage = nil

        do {
            providers = try await TMDBService.shared.fetchWatchProviders()
            isLoading = false
        } catch {
            #if DEBUG
            print("❌ Failed to load providers: \(error)")
            #endif
            errorMessage = "Unable to load streaming services. Please check your connection and try again."
            isLoading = false
        }
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        VStack(spacing: 12) {
            Divider()
                .background(Color.white.opacity(0.2))
                .padding(.vertical, 8)

            Text("Debug Options")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                settings.hasCompletedOnboarding = false
                settings.selectedProviderIDs = []
                dismiss()
            } label: {
                Label("Reset Onboarding", systemImage: "arrow.counterclockwise")
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

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    providerLogo

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, .green)
                            .offset(x: 4, y: 4)
                    }
                }

                Text(provider.providerName)
                    .font(.caption2)
                    .fontDesign(.rounded)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .glassEffect(
                isSelected
                    ? .regular.tint(.indigo.opacity(0.3))
                    : .regular.tint(.white.opacity(0.05)),
                in: .rect(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
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
        .clipShape(.rect(cornerRadius: 12))
        .background(Color.white.opacity(0.85), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.indigo : Color.clear,
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
