import CloudKit
import SwiftUI

/// `Transferable` wrapper handed to the "Share with a partner" `ShareLink`. The exporter defers
/// to `PersistenceController.createShare()` — the CloudKit share on `WatchListGroup` isn't created
/// until the system share sheet actually needs it, matching Apple's Core Data + CloudKit sharing
/// sample ("Sharing Core Data objects between iCloud users").
struct LibraryShareItem: Transferable {
    /// Snapshot of any existing share, passed in by the caller — on the main actor, from
    /// `PersistenceController.liveShare` — when the `ShareLink` is built. A `Transferable`'s
    /// default member values must themselves be non-isolated (it has to be constructible from any
    /// actor), so this can't default to calling `PersistenceController` itself; callers supply it.
    var existingShare: CKShare?

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            // A `CKShare` may already exist with nobody invited yet (the system share sheet was
            // cancelled after `createShare()` ran) — hand that one to the sheet instead of minting
            // a second, orphaned share.
            if let share = item.existingShare {
                return .existing(share, container: PersistenceController.ckContainer)
            }
            return .prepareShare(
                container: PersistenceController.ckContainer,
                // Read/write only (a read-only partner defeats the point). Access defaults to
                // "only people you invite" in the share sheet, but "anyone with the link" stays
                // selectable: invite-only requires the number/email the link is sent to be on
                // the recipient's Apple Account, and when it isn't the link is a dead end.
                allowedSharingOptions: CKAllowedSharingOptions(
                    allowedParticipantPermissionOptions: .readWrite,
                    allowedParticipantAccessOptions: .any
                )
            ) {
                try await PersistenceController.shared.createShare()
            }
        }
    }
}

/// The sharing block pushed from `SettingsView`'s Sharing row. Exactly one `CKShare` ever exists,
/// rooted at the app's single `WatchListGroup` — this renders whichever state applies: iCloud off,
/// owner-unshared, owner-shared (including a pending invite), participant, or joining (see
/// `docs/v2-shared-library-plan.md`, "Sharing (Task F)").
struct SharingSection: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingManageSheet = false
    @State private var showingLeaveConfirmation = false
    @State private var isLeaving = false
    @State private var leaveErrorMessage: String?
    @State private var manageErrorMessage: String?

    private let persistence = PersistenceController.shared

    var body: some View {
        Group {
            if persistence.isJoiningSharedLibrary {
                joiningRow
            } else if persistence.isCloudAccountAvailable == false {
                iCloudUnavailableCard
            } else if persistence.role == .participant {
                participantCard
            } else if persistence.isSharingLive, let share = persistence.liveShare {
                sharedCard(share: share)
            } else {
                unsharedCard
            }
        }
        .onAppear(perform: refresh)
        // The system share sheet and `UICloudSharingController` are both presented outside
        // SwiftUI's view hierarchy, so re-check `liveShare` whenever the app comes back to the
        // foreground — that's the only reliable signal either one has been dismissed.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refresh()
        }
        .sheet(isPresented: $showingManageSheet, onDismiss: refresh) {
            if let share = persistence.liveShare {
                CloudSharingView(
                    share: share,
                    container: PersistenceController.ckContainer,
                    onChange: refresh,
                    onError: { manageErrorMessage = $0.localizedDescription }
                )
            }
        }
        .confirmationDialog(
            leaveDialogTitle,
            isPresented: $showingLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await leaveShare() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll get an empty library of your own. The shared one keeps going without you.")
        }
        .alert(
            "Couldn't Leave Shared Library",
            isPresented: Binding(
                get: { leaveErrorMessage != nil },
                set: { if !$0 { leaveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(leaveErrorMessage ?? "")
        }
        .alert(
            "Couldn't Update Sharing",
            isPresented: Binding(
                get: { manageErrorMessage != nil },
                set: { if !$0 { manageErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manageErrorMessage ?? "")
        }
    }

    // MARK: - Owner, not yet shared

    private var unsharedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share your library")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text("Invite one person with an Apple Account. You'll both see and edit the same watchlist and collections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ShareLink(item: LibraryShareItem(existingShare: persistence.liveShare), preview: SharePreview("Up Next library")) {
                Label("Share with a partner", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - Owner, shared

    /// `isSharingLive` already guarantees a non-owner participant exists (invited or accepted) by
    /// the time this renders — see the state list in `body`.
    private func sharedCard(share: CKShare) -> some View {
        let partner = share.partnerParticipant
        let isPending = partner?.acceptanceStatus == .pending

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Shared")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Text(isPending
                 ? "Invited \(partner?.displayName ?? "your partner") — waiting for them to accept."
                 : "Shared with \(partner?.displayName ?? "your partner").")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingManageSheet = true
            } label: {
                Label("Manage Sharing…", systemImage: "person.2.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - iCloud unavailable

    private var iCloudUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
                Text("iCloud Is Off")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Text("Sign in to iCloud on this device to share your library with a partner.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - Participant

    private var participantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Shared library")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Text("Shared with you by \(ownerName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                showingLeaveConfirmation = true
            } label: {
                if isLeaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    Label("Leave Shared Library", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isLeaving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private var ownerName: String {
        persistence.liveShare?.ownerDisplayName ?? "your partner"
    }

    /// "Leave Sarah's Library?" when CloudKit gave us the owner's name, else a generic fallback.
    private var leaveDialogTitle: String {
        guard let name = persistence.liveShare?.ownerDisplayName else { return "Leave Shared Library?" }
        return "Leave \(name)'s Library?"
    }

    // MARK: - Joining

    private var joiningRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Joining shared library…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    // MARK: - Actions

    private func refresh() {
        persistence.refreshLiveShare()
        // Sharing is live on this device, whichever side it's on: ask for notification
        // permission (the system only ever prompts once).
        if persistence.liveShare != nil {
            RemoteActivityNotifier.requestPermissionIfNeeded()
        }
    }

    private func leaveShare() async {
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await persistence.leaveShare()
        } catch {
            leaveErrorMessage = error.localizedDescription
        }
    }
}

#Preview("Not Shared") {
    ScrollView {
        SharingSection()
            .padding(20)
    }
    .background(AppBackground())
}
