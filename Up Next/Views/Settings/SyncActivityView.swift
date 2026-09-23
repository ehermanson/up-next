import SwiftUI

/// Settings → About → iCloud Sync: the persisted log of finished CloudKit events and share
/// attempts, newest first, with the full error text. This is the support surface for a TestFlight
/// or App Store build — the one place a spinning share sheet or a partner who never sees a title
/// can be explained without a Mac attached. "Copy All" puts the whole log on the pasteboard.
struct SyncActivityView: View {
    private let persistence = PersistenceController.shared
    @State private var isChecking = false
    @State private var isRepairing = false
    @State private var showingRepairConfirmation = false
    @State private var repairError: String?
    @State private var isStuck = false
    @State private var showingResetConfirmation = false
    @State private var showingDedupeConfirmation = false
    @State private var isResetting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard

                if persistence.syncActivity.isEmpty {
                    Text("No iCloud activity recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else {
                    ForEach(persistence.syncActivity) { entry in
                        entryCard(entry)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(AppBackground())
        .onAppear { isStuck = persistence.isStuckBehindUnacceptedShare() }
        .confirmationDialog("Repair iCloud Sync?", isPresented: $showingRepairConfirmation, titleVisibility: .visible) {
            Button("Repair") {
                isRepairing = true
                Task {
                    do {
                        try await persistence.repairSync()
                    } catch {
                        repairError = error.localizedDescription
                    }
                    isStuck = persistence.isStuckBehindUnacceptedShare()
                    isRepairing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rebuilds your watchlist’s connection to iCloud. Your titles, watched state, ratings, notes and collections all stay. Any share link you’d created stops working — share again afterwards.")
        }
        .confirmationDialog("Remove Duplicates?", isPresented: $showingDedupeConfirmation, titleVisibility: .visible) {
            Button("Remove Duplicates") {
                _ = persistence.removeDuplicates()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps one copy of each title per list and merges collections that share a name. Watched state, ratings and notes on the kept copy stay.")
        }
        .confirmationDialog("Reset iCloud Sync?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("Reset and Close App", role: .destructive) {
                isResetting = true
                Task {
                    do {
                        try await persistence.resetSync()
                    } catch {
                        repairError = error.localizedDescription
                        isResetting = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes everything Up Next has put in iCloud and rebuilds it from what’s on this device. Your titles, watched state, ratings, notes and collections all stay. Any share link stops working. Up Next will close when it’s done — reopen it to finish.")
        }
        .alert("Couldn’t Repair", isPresented: Binding(
            get: { repairError != nil },
            set: { if !$0 { repairError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repairError ?? "")
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy All", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = transcript
                    }
                    Button("Copy Core Data Log", systemImage: "doc.text.magnifyingglass") {
                        UIPasteboard.general.string = persistence.recentCoreDataLog()
                    }
                    Button("Clear Log", systemImage: "trash", role: .destructive) {
                        persistence.clearSyncActivity()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(persistence.syncStatusSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Every finished sync and every attempt to create a share link, newest first. Errors here are what to send along when sharing or syncing isn’t working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isChecking = true
                Task {
                    await persistence.runCloudKitCheck()
                    isChecking = false
                }
            } label: {
                Label(isChecking ? "Checking…" : "Check iCloud Now", systemImage: "stethoscope")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isChecking)

            if persistence.role == .owner {
                if isStuck {
                    Text("Your watchlist is stuck behind a share iCloud never accepted, so nothing is syncing and sharing can’t start. Repair rebuilds the connection without losing anything.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    showingRepairConfirmation = true
                } label: {
                    Label(isRepairing ? "Repairing…" : "Repair iCloud Sync", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(isStuck ? .orange : .accentColor)
                .disabled(isRepairing)

                Button {
                    showingDedupeConfirmation = true
                } label: {
                    Label("Remove Duplicates", systemImage: "rectangle.on.rectangle.slash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button {
                    showingResetConfirmation = true
                } label: {
                    Label(isResetting ? "Resetting…" : "Reset iCloud Sync", systemImage: "arrow.counterclockwise.icloud")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResetting)
                Text("For when Repair isn’t enough: exports keep failing even though iCloud accepts the schema. Starts sync over from a clean store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private func entryCard(_ entry: PersistenceController.SyncActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: entry))
                    .foregroundStyle(["check", "repair", "reset", "restore", "dedupe"].contains(entry.kind) ? Color.accentColor : entry.errorText == nil ? .green : .orange)
                Text(entry.kind.capitalized)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(Self.timeFormatter.string(from: entry.endDate))
                    .font(.caption)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            Text(durationLabel(entry))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let error = entry.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private func icon(for entry: PersistenceController.SyncActivityEntry) -> String {
        if entry.kind == "check" { return "stethoscope" }
        if entry.kind == "repair" { return "wrench.and.screwdriver" }
        if entry.kind == "reset" || entry.kind == "restore" { return "arrow.counterclockwise.icloud" }
        if entry.kind == "dedupe" { return "rectangle.on.rectangle.slash" }
        return entry.errorText == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func durationLabel(_ entry: PersistenceController.SyncActivityEntry) -> String {
        let seconds = max(0, entry.endDate.timeIntervalSince(entry.startDate))
        return seconds < 1 ? "under a second" : "\(Int(seconds.rounded())) s"
    }

    private var transcript: String {
        persistence.syncActivity.map { entry in
            let stamp = Self.transcriptFormatter.string(from: entry.endDate)
            let outcome = entry.errorText ?? "OK"
            return "\(stamp) \(entry.kind) (\(durationLabel(entry))): \(outcome)"
        }.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let transcriptFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
}
