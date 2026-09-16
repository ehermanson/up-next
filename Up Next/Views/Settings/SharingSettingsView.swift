import CloudKit
import SwiftUI

/// `Transferable` wrapper handed to the "Share with a partner" `ShareLink`. The exporter defers
/// to `PersistenceController.createShare()` — the CloudKit share on `WatchListGroup` isn't created
/// until the system share sheet actually needs it, matching Apple's Core Data + CloudKit sharing
/// sample ("Sharing Core Data objects between iCloud users").
struct LibraryShareItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { _ in
            .prepareShare(
                container: PersistenceController.ckContainer,
                allowedSharingOptions: CKAllowedSharingOptions(
                    allowedParticipantPermissionOptions: .readWrite,
                    allowedParticipantAccessOptions: .specifiedRecipientsOnly
                )
            ) {
                try await PersistenceController.shared.createShare()
            }
        }
    }
}

/// The sharing block at the top of `ProviderSettingsView`. Exactly one `CKShare` ever exists,
/// rooted at the app's single `WatchListGroup` — this renders whichever of four states applies:
/// owner-unshared, owner-shared, participant, or joining (see `docs/v2-shared-library-plan.md`,
/// "Sharing (Task F)").
struct SharingSection: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var share: CKShare?
    @State private var showingManageSheet = false
    @State private var showingLeaveConfirmation = false
    @State private var isLeaving = false
    @State private var leaveErrorMessage: String?

    private let persistence = PersistenceController.shared

    var body: some View {
        Group {
            if persistence.isJoiningSharedLibrary {
                joiningRow
            } else if persistence.role == .participant {
                participantCard
            } else if let share {
                sharedCard(share: share)
            } else {
                unsharedCard
            }
        }
        .onAppear(perform: refresh)
        // The system share sheet and `UICloudSharingController` are both presented outside
        // SwiftUI's view hierarchy, so re-check `existingShare()` whenever the app comes back to
        // the foreground — that's the only reliable signal either one has been dismissed.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refresh()
        }
        .sheet(isPresented: $showingManageSheet, onDismiss: refresh) {
            if let share {
                CloudSharingView(share: share, container: PersistenceController.ckContainer, onChange: refresh)
            }
        }
        .confirmationDialog(
            "Leave Shared Library?",
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

            ShareLink(item: LibraryShareItem(), preview: SharePreview("Up Next library")) {
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

    private func sharedCard(share: CKShare) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Shared")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Text(participantsSummary(for: share))
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

    /// Non-owner participants, each rendered as a display name when CloudKit will give us one.
    /// iOS may withhold `nameComponents` for apps without the contacts entitlement, so a
    /// nameless participant still reads as "Invited" (pending) or "1 person" (accepted).
    private func participantsSummary(for share: CKShare) -> String {
        let participants = share.participants.filter { $0.role != .owner }
        guard !participants.isEmpty else {
            return "Invite a partner to start sharing your library."
        }
        let names = participants.map(displayName)
        return "Shared with " + names.joined(separator: ", ")
    }

    private func displayName(for participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter().string(from: components)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        return participant.acceptanceStatus == .pending ? "Invited" : "1 person"
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
        guard let components = share?.owner.userIdentity.nameComponents else { return "your partner" }
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "your partner" : name
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
        share = persistence.existingShare()
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
