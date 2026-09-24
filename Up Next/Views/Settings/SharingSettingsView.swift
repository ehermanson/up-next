import CloudKit
import SwiftUI

/// `Transferable` wrapper handed to the "Share Your Watchlist" `ShareLink`. The exporter defers
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
/// owner-unshared, owner-shared (including a pending invite), participant, or joining.
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
                supportingCards
            } else if persistence.isSharingLive, let share = persistence.liveShare {
                sharedCard(share: share)
                supportingCards
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
            Text("You’ll get an empty watchlist of your own. The shared one keeps going without you.")
        }
        .alert(
            "Couldn’t Leave Shared Watchlist",
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
            "Couldn’t Update Sharing",
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
            Text("Not Shared Yet")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Text("Invite one other person with an Apple Account. You’ll both see and edit the same watchlist, collections and streaming services.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Creating the share queues behind any export in flight (a whole library on a first
            // launch against a fresh CloudKit environment), and a failed sync means it can't
            // succeed at all — say so here rather than letting the share sheet spin.
            if persistence.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing your watchlist to iCloud… Sharing works once that finishes.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let error = persistence.lastSyncError {
                Text("iCloud sync failed, so sharing can’t start yet: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ShareLink(item: LibraryShareItem(existingShare: persistence.liveShare), preview: SharePreview("Up Next watchlist")) {
                Label("Share Your Watchlist", systemImage: "person.2")
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

            Text(sharedCaption(name: partner?.shortDisplayName, isPending: isPending))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            participantRows(share)

            Button {
                showingManageSheet = true
            } label: {
                Label("Manage Sharing…", systemImage: "person.2.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .borderedTint()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    /// The name can be withheld by iOS; the sentence is rewritten around the gap instead of
    /// guessing at a noun for the other person.
    private func sharedCaption(name: String?, isPending: Bool) -> String {
        switch (isPending, name) {
        case (true, let name?): return "Invited \(name) — waiting for them to accept."
        case (true, nil): return "Invitation sent — waiting for them to accept."
        case (false, let name?): return "Shared with \(name)."
        case (false, nil): return "Shared with one other person."
        }
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

            Text("Sign in to iCloud on this device to share your watchlist.")
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
                Text("Shared watchlist")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Text(persistence.otherPersonShortName.map { "Shared with you by \($0)." } ?? "Shared with you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let share = persistence.liveShare {
                participantRows(share)
            }

            Button(role: .destructive) {
                showingLeaveConfirmation = true
            } label: {
                if isLeaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    Label("Leave Shared Watchlist", systemImage: "rectangle.portrait.and.arrow.right")
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

    /// "Leave Sarah’s watchlist?" when the owner's name is known, else a generic fallback.
    private var leaveDialogTitle: String {
        guard let name = persistence.otherPersonName else { return "Leave Shared Watchlist?" }
        return "Leave \(name)’s watchlist?"
    }

    // MARK: - People

    /// One row per person on the share: name (or a role fallback when iOS withholds it), "You"
    /// where applicable, and where they stand — Owner / Joined / Invited.
    private func participantRows(_ share: CKShare) -> some View {
        let people = share.participants.filter { $0.acceptanceStatus != .removed }
            .sorted { ($0.role == .owner ? 0 : 1) < ($1.role == .owner ? 0 : 1) }
        return VStack(spacing: 8) {
            ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                let isMe = person.userIdentity.userRecordID == share.currentUserParticipant?.userIdentity.userRecordID
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName
                             ?? (person.role == .owner && persistence.role == .participant ? persistence.otherPersonName : nil)
                             ?? (person.role == .owner ? "Owner" : "Invited person"))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if isMe {
                            Text("You")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(person.role == .owner ? "Owner" : person.acceptanceStatus == .accepted ? "Joined" : "Invited")
                        .font(.caption)
                        .fontDesign(.rounded)
                        .foregroundStyle(person.acceptanceStatus == .pending && person.role != .owner ? .orange : .secondary)
                }
                .padding(12)
                .cellSurface(cornerRadius: DesignTokens.Radius.cardCompact)
            }
        }
    }

    // MARK: - What's shared / Activity

    /// Shown under whichever card applies, so the screen explains itself instead of floating one
    /// card in a void.
    @ViewBuilder
    private var supportingCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What’s Shared")
                .font(.subheadline)
                .fontWeight(.semibold)
            sharedPoint("bookmark.circle", "Up Next and Watched, for TV shows and movies — with seasons, ratings and notes.")
            sharedPoint("folder", "Every collection.")
            sharedPoint("play.tv", "Streaming services — one set for the household.")
            sharedPoint("person.crop.circle", "Each title’s detail shows who added it. Region and appearance stay per device.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)

        NavigationLink {
            ActivityView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text("Activity")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("What’s changed, and who changed it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .padding(16)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private func sharedPoint(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Joining

    private var joiningRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Joining shared watchlist…")
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
        // Then the server's copy — the only place an accepted invitation shows up.
        Task { await persistence.refreshLiveShareFromServer() }
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
