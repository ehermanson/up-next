import SwiftUI

/// Streaming-service picker. Presented two ways: as the sheet's own root during first-launch
/// onboarding (`isRoot == true`, owns its `NavigationStack` + Done button) and pushed from
/// `SettingsView`'s "Streaming Services" row or Discover's "Choose your services" chip
/// (`isRoot == false`, the presenter already supplies navigation chrome).
struct ProviderSettingsView: View {
    var isRoot: Bool = true

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
        if isRoot {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppBackground())
        .navigationTitle("Streaming Services")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProviders()
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select the streaming services you subscribe to. They're highlighted on your cards and used to filter Discover and your watchlist.")
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
}

// MARK: - Region Picker

/// Dedicated region list pushed from `SettingsView`'s Region row. A menu can't hold ~100 regions
/// legibly, so this gives the picker its own searchable screen instead.
struct RegionPickerView: View {
    let regions: [TMDBWatchProviderRegion]
    let isLoading: Bool
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        List {
            Section {
                automaticRow
            }

            Section("All Regions") {
                if regions.isEmpty && isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if regions.isEmpty {
                    EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load regions")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredRegions) { region in
                        regionRow(region)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .listStyle(.plain)
        .navigationTitle("Region")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search regions")
    }

    private var automaticRow: some View {
        Button {
            selection = nil
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic")
                        .foregroundStyle(.primary)
                    Text("Uses your device's region (\(deviceRegionName))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selection == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .listRowBackground(Color.clear)
    }

    private func regionRow(_ region: TMDBWatchProviderRegion) -> some View {
        Button {
            selection = region.iso31661
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.englishName)
                        .foregroundStyle(.primary)
                    if region.nativeName != region.englishName {
                        Text(region.nativeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if selection == region.iso31661 {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .listRowBackground(Color.clear)
    }

    private var deviceRegionName: String {
        let code = ProviderSettings.deviceRegion
        return regions.first { $0.iso31661 == code }?.englishName
            ?? Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Case- and diacritic-insensitive match on English name, native name, or ISO code.
    private var filteredRegions: [TMDBWatchProviderRegion] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return regions }
        return regions.filter { region in
            region.englishName.localizedStandardContains(query)
                || region.nativeName.localizedStandardContains(query)
                || region.iso31661.localizedStandardContains(query)
        }
    }
}

// MARK: - Provider Grid Cell

private struct ProviderGridCell: View {
    let provider: TMDBWatchProviderInfo
    let isSelected: Bool
    let onTap: () -> Void

    @ScaledMetric private var badgeSize: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            .transition(reduceMotion ? .identity : Motion.checkPop)
                            .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
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
        // A springy pop when a service is picked — the selection is the whole point of this screen.
        .animation(reduceMotion ? nil : Motion.pop, value: isSelected)
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
