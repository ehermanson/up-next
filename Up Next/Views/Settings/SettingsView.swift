import CloudKit
import SwiftUI

/// Settings root, reached from every tab via `SettingsToolbarButton`. Rows push their own
/// screens rather than cramming everything (sharing, streaming services, region, about) into one
/// scroll, the way `ProviderSettingsView` used to before Sharing became the release's headline
/// feature and needed real prominence.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

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
    }

    // MARK: - Sharing

    private var sharingRow: some View {
        NavigationLink {
            SharingScreen()
        } label: {
            row(icon: "person.2", title: "Sharing", value: sharingStatus)
        }
        .buttonStyle(.plain)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    /// Mirrors `SharingSection`'s four states without duplicating its participant-name logic —
    /// a short summary is enough here, the pushed screen has the full picture.
    private var sharingStatus: String {
        let persistence = PersistenceController.shared
        if persistence.isJoiningSharedLibrary {
            return "Joining…"
        }
        if persistence.role == .participant {
            return "Shared by \(ownerName)"
        }
        if let share = persistence.existingShare() {
            let partners = share.participants.filter { $0.role != .owner }
            if let name = partners.first.flatMap(participantName) {
                return "Shared with \(name)"
            }
            return partners.isEmpty ? "Not shared yet" : "Shared"
        }
        return "Not shared yet"
    }

    private var ownerName: String {
        guard let components = PersistenceController.shared.existingShare()?.owner.userIdentity.nameComponents else {
            return "your partner"
        }
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "your partner" : name
    }

    private func participantName(_ participant: CKShare.Participant) -> String? {
        guard let components = participant.userIdentity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Streaming Services

    private var streamingServicesRow: some View {
        NavigationLink {
            ProviderSettingsView(isRoot: false)
        } label: {
            row(icon: "play.tv", title: "Streaming Services", value: streamingServicesStatus)
        }
        .buttonStyle(.plain)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private var streamingServicesStatus: String {
        let count = settings.selectedProviderIDs.count
        return count == 0 ? "None selected" : "\(count) selected"
    }

    // MARK: - Region

    private var regionRow: some View {
        NavigationLink {
            RegionPickerView(regions: regions, isLoading: isLoadingRegions, selection: regionSelection)
        } label: {
            row(icon: "globe", title: "Region", value: currentRegionLabel)
        }
        .buttonStyle(.plain)
        .padding(16)
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
        guard let code = settings.regionOverride else { return "Automatic" }
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

/// The Sharing row's destination: `SharingSection` unchanged, with a short intro paragraph above
/// it when nothing is shared yet (mirrors the copy `SharingSection.unsharedCard` already shows,
/// so this doesn't repeat it — the card speaks for itself once shared).
private struct SharingScreen: View {
    private let persistence = PersistenceController.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !isSharingLive {
                    introSection
                }
                SharingSection()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppBackground())
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isSharingLive: Bool {
        persistence.role == .participant || persistence.existingShare() != nil
    }

    private var introSection: some View {
        Text("Invite one person with an Apple Account. You'll both see and edit the same watchlist and collections.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }
}
