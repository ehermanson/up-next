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
    @State private var share: CKShare?

    private let persistence = PersistenceController.shared

    var body: some View {
        Button(action: action) {
            content
        }
        .accessibilityLabel(accessibilityLabel)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refresh()
        }
        .onChange(of: persistence.remoteChangeCount) {
            refresh()
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
        // Cross-fade the gear into the paired avatars the moment a share goes live — the arrival of
        // a partner is worth a beat, not a hard swap. Driven by `refresh()` wrapping `share` in an
        // animated transaction.
    }

    // MARK: - State

    /// (me, partner), only once sharing is actually live — an owner who hasn't invited anyone
    /// yet still keeps the plain gear.
    private var participantPair: (me: CKShare.Participant?, partner: CKShare.Participant?)? {
        guard let share else { return nil }
        let partner = share.participants.first { $0.role != .owner }
        guard persistence.role == .participant || partner != nil else { return nil }
        return (share.currentUserParticipant, partner)
    }

    private func refresh() {
        let updated = persistence.existingShare()
        if reduceMotion {
            share = updated
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                share = updated
            }
        }
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

            if let initials = initials(for: participant) {
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

    private func initials(for participant: CKShare.Participant?) -> String? {
        guard let components = participant?.userIdentity.nameComponents else { return nil }
        let letters = [components.givenName, components.familyName]
            .compactMap { $0?.first }
            .map(String.init)
        let initials = letters.joined()
        return initials.isEmpty ? nil : initials
    }

    private var accessibilityLabel: String {
        guard let pair = participantPair else { return "Settings" }
        let name = pair.partner?.userIdentity.nameComponents.flatMap {
            let formatted = PersonNameComponentsFormatter().string(from: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return formatted.isEmpty ? nil : formatted
        }
        return "Settings, shared with \(name ?? "your partner")"
    }
}
