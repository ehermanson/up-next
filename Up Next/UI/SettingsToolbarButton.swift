import CloudKit
import SwiftUI

/// The trailing toolbar entry point into `SettingsView`, used on all four tabs. Plain gear icon
/// normally; once a share is actually live on this device (an owner who has a partner, or a
/// participant) it swaps to two overlapping initials avatars so sharing status reads at a glance
/// without opening Settings — sharing is the release's headline feature and was otherwise buried.
struct SettingsToolbarButton: View {
    let action: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let persistence = PersistenceController.shared

    var body: some View {
        Button(action: action) {
            content
        }
        .accessibilityLabel(accessibilityLabel)
        // The system share sheet and `UICloudSharingController` are presented outside SwiftUI, so
        // re-check `liveShare` whenever the app returns to the foreground; `SharingSection` and
        // `TVShowsTabView`'s pitch card do the same for the same reason. Every other trigger
        // (bootstrap, accept/leave, remote changes) already refreshes `liveShare` itself.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if reduceMotion {
                persistence.refreshLiveShare()
            } else {
                // Cross-fade the gear into the paired avatars the moment a share goes live — the
                // arrival of a partner is worth a beat, not a hard swap.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    persistence.refreshLiveShare()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pair = participantPair {
            avatarPair(pair)
                .transition(Motion.morph)
        } else {
            Label("Settings", systemImage: "gearshape")
                .transition(Motion.morph)
        }
    }

    // MARK: - State

    /// (me, partner), only once sharing is actually live — an owner who hasn't invited anyone
    /// yet still keeps the plain gear.
    private var participantPair: (me: CKShare.Participant?, partner: CKShare.Participant?)? {
        guard persistence.isSharingLive, let share = persistence.liveShare else { return nil }
        return (share.currentUserParticipant, share.partnerParticipant)
    }

    // MARK: - Avatars

    private func avatarPair(_ pair: (me: CKShare.Participant?, partner: CKShare.Participant?)) -> some View {
        HStack(spacing: -10) {
            avatar(for: pair.me)
            avatar(for: pair.partner)
        }
    }

    private func avatar(for participant: CKShare.Participant?) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.35))
                .overlay(Circle().strokeBorder(DesignTokens.Colors.backgroundBase, lineWidth: 1.5))
                .frame(width: 26, height: 26)

            if let initials = participant?.initials {
                Text(initials)
                    .font(.caption2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "person.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var accessibilityLabel: String {
        guard let pair = participantPair else { return "Settings" }
        return "Settings, shared with \(pair.partner?.displayName ?? "your partner")"
    }
}
