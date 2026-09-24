import CoreData
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
    #if DEBUG
    @State private var schemaResult: String?
    @State private var isInitializingSchema = false
    #endif

    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .dark
    @AppStorage(StorageKey.showsSyncTools) private var showsSyncTools = false

    /// Newest `ActivityEvent`, for the Activity row's value. Refreshed on appear (including the
    /// pop back from the Activity screen) and when the other person's edits import.
    @State private var newestActivity: Date?

    @State private var regions: [TMDBWatchProviderRegion] = []
    @State private var isLoadingRegions = true

    private let settings = ProviderSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sharingRow
                    activityRow
                    streamingServicesRow
                    regionRow
                    if LegacyStoreReader.storeExists(), !LegacyImporter.hasCompletedImport { legacyImportRow }
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
        .onAppear(perform: loadNewestActivity)
        .onChange(of: PersistenceController.shared.remoteChangeCount) { loadNewestActivity() }
        .sheet(isPresented: $showingLegacyImport) {
            LegacyImportView(library: library, lists: lists)
        }
    }

    // MARK: - Import from 1.x

    /// Only shown while a 1.x store is on disk and hasn't been imported — "Not Now" on the offer
    /// sheet leaves this as the way back; a finished run removes it (the sheet's dismissal
    /// re-evaluates `body`, so the row goes away as soon as the user taps Done).
    private var legacyImportRow: some View {
        Button {
            showingLegacyImport = true
        } label: {
            row(icon: "arrow.down.doc", title: "Import from Up Next 1.7", value: "Not imported")
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
        // Names can be withheld by iOS — the row reads fine without one.
        if persistence.role == .participant {
            return persistence.otherPersonShortName.map { "Shared with you by \($0)" } ?? "Shared with you"
        }
        if persistence.isSharingLive {
            return persistence.otherPersonShortName.map { "Shared with \($0)" } ?? "Shared"
        }
        return "Not shared yet"
    }

    // MARK: - Activity

    private var activityRow: some View {
        NavigationLink {
            ActivityView()
        } label: {
            row(icon: "clock.arrow.circlepath", title: "Activity", value: activityStatus)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private var activityStatus: String {
        guard let newestActivity else { return "Nothing yet" }
        return newestActivity.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func loadNewestActivity() {
        guard let group = PersistenceController.shared.group, group.managedObjectContext != nil, !group.isDeleted else {
            newestActivity = nil
            return
        }
        newestActivity = group.activities?.filter { !$0.isDeleted }.compactMap(\.createdAtRaw).max()
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

    /// Just the count — the picker itself says the services are household-wide when a share is
    /// live, and a "Shared with …" suffix here crowded the row title off the line.
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
            // Same glyph treatment as the pushable rows above, so the card reads as a peer.
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text("Appearance")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
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
            syncStatusRow

            Divider()

            TMDBAttributionView()

            Text(versionString)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(.rect)
                .onLongPressGesture { showsSyncTools.toggle() }
                .sensoryFeedback(.success, trigger: showsSyncTools)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    /// What iCloud is doing right now, with the actual error text when it fails — the one place
    /// a TestFlight or App Store build can explain a share sheet that spins or titles that don't
    /// arrive on the other phone. Status only until sync tools are unlocked (long press on the
    /// version string); then it pushes `SyncActivityView`.
    @ViewBuilder
    private var syncStatusRow: some View {
        if showsSyncTools {
            NavigationLink {
                SyncActivityView()
            } label: {
                syncStatusLabel(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            syncStatusLabel(showsChevron: false)
        }
    }

    private func syncStatusLabel(showsChevron: Bool) -> some View {
        let persistence = PersistenceController.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: persistence.lastSyncError != nil ? "exclamationmark.icloud" : "icloud")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text("iCloud Sync")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Text(persistence.syncStatusSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let error = persistence.lastSyncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(.rect)
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

            // The title never wraps or yields: a long value (a name, a relative date) truncates
            // instead. With the priority the other way round, "Streaming Services" once rendered
            // one letter per line beside "11 selected · Shared with Erika Herman…".
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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

            // Creates every record type/field in the Development schema regardless of what the
            // library holds — the Console only shows a field once some record exported with it.
            Button {
                isInitializingSchema = true
                Task {
                    schemaResult = await PersistenceController.shared.cloudKitDiagnostics()
                    isInitializingSchema = false
                }
            } label: {
                Label(isInitializingSchema ? "Initializing…" : "Initialize CloudKit Schema", systemImage: "icloud.and.arrow.up")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(isInitializingSchema)
            .alert("CloudKit Schema", isPresented: Binding(
                get: { schemaResult != nil },
                set: { if !$0 { schemaResult = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(schemaResult ?? "")
            }
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
