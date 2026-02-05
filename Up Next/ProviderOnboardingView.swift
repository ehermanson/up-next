import SwiftUI

struct ProviderOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var providers: [TMDBWatchProviderInfo] = []
    @State private var selectedProviderIDs: Set<Int> = []
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
                    headerSection

                    if isLoading {
                        loadingView
                    } else if let error = errorMessage {
                        errorView(message: error)
                    } else {
                        providerGrid
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .safeAreaInset(edge: .bottom) {
                buttonSection
            }
            .background(AppBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await loadProviders()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
                .frame(width: 88, height: 88)
                .glassEffect(.regular.tint(.indigo.opacity(0.15)), in: .circle)

            Text("Set Up Your Streaming Services")
                .font(.title2)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .multilineTextAlignment(.center)

            Text("Select your services to see where you can watch at a glance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 16)
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
                ProviderGridItem(
                    provider: provider,
                    isSelected: selectedProviderIDs.contains(provider.id)
                ) {
                    toggleProvider(provider.id)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))
    }

    // MARK: - Buttons

    private var buttonSection: some View {
        VStack(spacing: 12) {
            Button {
                saveAndDismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .fontDesign(.rounded)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(isLoading)

            Button {
                skipAndDismiss()
            } label: {
                Text("Skip")
                    .font(.subheadline)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
    }

    // MARK: - Actions

    private func toggleProvider(_ id: Int) {
        if selectedProviderIDs.contains(id) {
            selectedProviderIDs.remove(id)
        } else {
            selectedProviderIDs.insert(id)
        }
    }

    private func loadProviders() async {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedProviders = try await TMDBService.shared.fetchWatchProviders()
            providers = fetchedProviders
            isLoading = false
        } catch {
            errorMessage = "Unable to load streaming services. Please check your connection and try again."
            isLoading = false
        }
    }

    private func saveAndDismiss() {
        settings.selectProviders(selectedProviderIDs)
        settings.hasCompletedOnboarding = true
        dismiss()
    }

    private func skipAndDismiss() {
        settings.hasCompletedOnboarding = true
        dismiss()
    }
}

// MARK: - Provider Grid Item

private struct ProviderGridItem: View {
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
