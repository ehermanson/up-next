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
    @State private var searchText = ""
    /// The full regional list runs to ~270 entries, most of them niche or long defunct (TMDB never
    /// retires a provider). Show the top of the region's priority order by default — search still
    /// reaches everything — and let the rest be asked for.
    @State private var showsAllProviders = false
    private static let featuredLimit = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let settings = ProviderSettings.shared

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
    ]

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

                if isRoot {
                    Text("You can change this anytime in Settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppBackground())
        .navigationTitle("Streaming Services")
        .navigationBarTitleDisplayMode(.inline)
        // ~270 services per region; nobody should scroll to the bottom to find Crunchyroll.
        .searchable(text: $searchText, prompt: "Search services")
        .task {
            await loadProviders()
        }
    }

    // MARK: - Filtering

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProviders: [TMDBWatchProviderInfo] {
        guard !trimmedQuery.isEmpty else { return providers }
        return providers.filter { $0.providerName.localizedStandardContains(trimmedQuery) }
    }

    /// The user's picks, in list order — pinned above everything else so they're one glance
    /// away instead of scattered through a 270-row grid. Hidden while searching.
    private var selectedProviders: [TMDBWatchProviderInfo] {
        providers.filter { settings.selectedProviderIDs.contains($0.id) }
    }

    /// Everything not already pinned above — a picked service shouldn't appear twice on one screen.
    private var unselectedProviders: [TMDBWatchProviderInfo] {
        providers.filter { !settings.selectedProviderIDs.contains($0.id) }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select the streaming services you subscribe to. They’re highlighted on your cards and used to filter Discover and your watchlist.")
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
            Text("Loading providers…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        EmptyStateView(
            icon: "wifi.exclamationmark",
            title: "Couldn’t load streaming services",
            subtitle: message
        ) {
            Button("Try Again") {
                Task { await loadProviders() }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Provider Grid

    @ViewBuilder
    private var providerGrid: some View {
        if trimmedQuery.isEmpty {
            let picked = selectedProviders
            if !picked.isEmpty {
                VStack(spacing: 8) {
                    SectionHeader(title: "Your Services", count: picked.count, showsFilter: false)
                    grid(for: picked)
                }
            }
            let rest = unselectedProviders
            let isTruncated = !showsAllProviders && rest.count > Self.featuredLimit
            VStack(spacing: 8) {
                SectionHeader(title: isTruncated ? "Popular Services" : "All Services", showsFilter: false)
                grid(for: isTruncated ? Array(rest.prefix(Self.featuredLimit)) : rest)
                if isTruncated {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                            showsAllProviders = true
                        }
                    } label: {
                        Text("Show All \(rest.count) Services")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
        } else if filteredProviders.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Services Match",
                subtitle: "Try a different name — services are listed the way TMDB names them."
            )
            .padding(.vertical, 40)
        } else {
            grid(for: filteredProviders)
        }
    }

    private func grid(for items: [TMDBWatchProviderInfo]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { provider in
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
    /// Re-runs the fetch that populated `regions`. Optional so existing call sites (owned
    /// elsewhere) keep compiling until they're updated to wire this up.
    var onRetry: (() async -> Void)? = nil

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
                    EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn’t load regions") {
                        if let onRetry {
                            Button("Try Again") {
                                Task { await onRetry() }
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
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
                    Text("Uses your device’s region (\(deviceRegionName))")
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
                    .frame(minHeight: 32)
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
