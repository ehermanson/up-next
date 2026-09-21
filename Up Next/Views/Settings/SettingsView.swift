import SwiftUI

/// Settings root, reached from every tab via `SettingsToolbarButton`. Rows push their own
/// screens rather than cramming everything (sharing, streaming services, region, about) into one
/// scroll, the way `ProviderSettingsView` used to before Sharing became the release's headline
/// feature and needed real prominence.
struct SettingsView: View {
    /// Passed through to `LegacyImportView`, which adds through the view-model APIs.
    let library: MediaLibraryViewModel
    let lists: CustomListViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var showingLegacyImport = false

    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .dark

    @State private var regions: [TMDBWatchProviderRegion] = []
    @State private var isLoadingRegions = true

    private let settings = ProviderSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sharingRow
                    streamingServicesRow
                    regionRow
                    if LegacyStoreReader.storeExists() { legacyImportRow }
                    appearanceSection
                    aboutSection

                    #if DEBUG
                    debugSection
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AppBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Sheets own their presentation appearance. Update this presentation as well as the
        // app root so a selection takes effect while Settings remains open.
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await loadRegions()
        }
        .sheet(isPresented: $showingLegacyImport) {
            LegacyImportView(library: library, lists: lists)
        }
    }

    // MARK: - Import from 1.x

    /// Only shown while a 1.x store is still on disk. Stays available after "Not Now" or a
    /// finished run — importing again skips anything already there.
    private var legacyImportRow: some View {
        Button {
            showingLegacyImport = true
        } label: {
            row(icon: "arrow.down.doc", title: "Import from Up Next 1.7",
                value: LegacyImporter.isOfferPending ? "Not imported" : "Imported")
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - Sharing

    private var sharingRow: some View {
        NavigationLink {
            SharingScreen()
        } label: {
            row(icon: "person.2", title: "Sharing", value: sharingStatus)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    /// Mirrors `SharingSection`'s states without duplicating its participant-name logic — a short
    /// summary is enough here, the pushed screen has the full picture. Reads `PersistenceController`'s
    /// observable sharing state directly rather than fetching a `CKShare` in `body`.
    private var sharingStatus: String {
        let persistence = PersistenceController.shared
        if persistence.isJoiningSharedLibrary {
            return "Joining…"
        }
        if persistence.isCloudAccountAvailable == false {
            return "iCloud unavailable"
        }
        if persistence.role == .participant {
            return "Shared with you by \(ownerName)"
        }
        if persistence.isSharingLive {
            return "Shared with \(partnerName)"
        }
        return "Not shared yet"
    }

    private var ownerName: String {
        PersistenceController.shared.liveShare?.ownerDisplayName ?? "your partner"
    }

    private var partnerName: String {
        PersistenceController.shared.liveShare?.partnerParticipant?.displayName ?? "your partner"
    }

    // MARK: - Streaming Services

    private var streamingServicesRow: some View {
        NavigationLink {
            ProviderSettingsView(isRoot: false)
        } label: {
            row(icon: "play.tv", title: "Streaming Services", value: streamingServicesStatus)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private var streamingServicesStatus: String {
        let count = settings.selectedProviderIDs.count
        return count == 0 ? "None selected" : "\(count) selected"
    }

    // MARK: - Region

    private var regionRow: some View {
        NavigationLink {
            RegionPickerView(regions: regions, isLoading: isLoadingRegions, selection: regionSelection, onRetry: { await loadRegions() })
        } label: {
            row(icon: "globe", title: "Region", value: currentRegionLabel)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    /// Writes through to the override; `ProviderSettingsView`'s own grid reloads itself the next
    /// time it's pushed, and Discover / the watchlist react via their existing `regionOverride`
    /// observers — this row doesn't need to trigger anything itself.
    private var regionSelection: Binding<String?> {
        Binding(
            get: { settings.regionOverride },
            set: { settings.regionOverride = $0 }
        )
    }

    private var currentRegionLabel: String {
        guard let code = settings.regionOverride else {
            let deviceRegionName = Locale.current.localizedString(forRegionCode: ProviderSettings.effectiveRegion)
                ?? ProviderSettings.effectiveRegion
            return "Automatic (\(deviceRegionName))"
        }
        return regions.first { $0.iso31661 == code }?.englishName
            ?? Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// A failure here is non-fatal: the row still shows the current pick (via `Locale` for the
    /// name) and `RegionPickerView` keeps Automatic selectable under a "couldn't load" state.
    private func loadRegions() async {
        isLoadingRegions = true
        regions = (try? await TMDBService.shared.fetchWatchProviderRegions()) ?? []
        isLoadingRegions = false
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows your device’s appearance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TMDBAttributionView()

            Text(versionString)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    // MARK: - Row

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 4) {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .padding(16)
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
                settings.hasCompletedProviderOnboarding = false
                settings.onlyMyServicesInDiscover = true
                settings.regionOverride = nil
                settings.hasDismissedSharePitch = false
                dismiss()
            } label: {
                Label("Reset Providers & Onboarding", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(.top, 8)
    }
    #endif
}

// MARK: - Sharing Screen

/// The Sharing row's destination: just `SharingSection` — its own `unsharedCard` already carries
/// the "invite one person" pitch, so this screen doesn't repeat it above.
private struct SharingScreen: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SharingSection()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppBackground())
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
