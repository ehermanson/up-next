import CloudKit
import SwiftUI

/// The trailing toolbar entry point into `SettingsView`, used on all four tabs. Plain gear icon
/// normally; once a share is actually live on this device (an owner who has a partner, or a
/// participant) it swaps to the system's collaboration glyph (`person.2`, what Notes / Reminders /
/// Files show) so sharing status reads at a glance without opening Settings. Overlapping initials
/// avatars were tried and dropped — iOS withholds names from apps without the extended
/// share-access entitlement, so they degraded to two generic heads in a circle.
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
            // The mirror can't know about an accepted invitation (see
            // `refreshLiveShareFromServer`) — ask the server so the glyph flips when they join.
            Task { await persistence.refreshLiveShareFromServer() }
            if reduceMotion {
                persistence.refreshLiveShare()
            } else {
                // Morph the gear into the collaboration glyph the moment a share goes live — the
                // arrival of the other person is worth a beat, not a hard swap.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    persistence.refreshLiveShare()
                }
            }
        }
    }

    private var content: some View {
        // One `Image` with a ternary name so the glyph morphs rather than swapping.
        Label("Settings", systemImage: isSharingLive ? "person.2" : "gearshape")
            .contentTransition(.symbolEffect(.replace))
    }

    // MARK: - State

    /// Only once sharing is actually live — an owner who hasn't invited anyone yet still keeps
    /// the plain gear.
    private var isSharingLive: Bool {
        persistence.isSharingLive && persistence.liveShare != nil
    }

    private var accessibilityLabel: String {
        guard isSharingLive else { return "Settings" }
        guard let name = persistence.otherPersonName else { return "Settings, sharing is on" }
        return "Settings, shared with \(name)"
    }
}
