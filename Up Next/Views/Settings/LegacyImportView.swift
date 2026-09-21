import SwiftUI

/// The one-time offer to bring an Up Next 1.x library into 2.0, and the progress / result of doing
/// it. Presented as its own sheet (no navigation chrome — it's a single decision), so every state
/// is a centered icon, a line of copy and at most two buttons.
struct LegacyImportView: View {
    let library: MediaLibraryViewModel
    let lists: CustomListViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var summary: LegacyLibrary.Summary?
    @State private var summaryError: (any Error)?

    private let importer = LegacyImporter.shared
    private let persistence = PersistenceController.shared

    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            content
                .padding(.horizontal, DesignTokens.Spacing.screenInset)
                .padding(.vertical, 24)
        }
        // A half-finished import is confusing, and it's short — no swipe-away while it runs.
        .interactiveDismissDisabled(isWorking)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: stateKey)
        .task {
            // Reopened from Settings after an earlier run: start on the offer, not on its result.
            importer.resetState()
            loadSummary()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch importer.state {
        case .idle:
            if let summaryError {
                failureView(message: summaryError.localizedDescription)
            } else if let summary {
                offerView(summary)
            } else {
                ProgressView()
            }
        case .reading:
            progressView(done: 0, total: 0)
        case .importing(let done, let total):
            progressView(done: done, total: total)
        case .finished(let result):
            finishedView(result)
        case .failed(let error):
            failureView(message: error.localizedDescription)
        }
    }

    // MARK: - States

    private func offerView(_ summary: LegacyLibrary.Summary) -> some View {
        Group {
            if summary.isEmpty {
                ImportStateLayout(
                    icon: "arrow.down.doc",
                    title: "Nothing to Bring Over",
                    subtitle: "The previous version of Up Next didn’t leave anything on this device."
                ) {
                    dismissButton(title: "Done")
                }
            } else {
                ImportStateLayout(
                    icon: "arrow.down.doc",
                    breathes: true,
                    title: "Bring Over Your Up Next?",
                    subtitle: offerMessage(summary)
                ) {
                    VStack(spacing: 12) {
                        Button("Import") { startImport() }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)

                        Button("Not Now") {
                            importer.dismissOffer()
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    /// `total == 0` covers the brief read before the title count is known.
    private func progressView(done: Int, total: Int) -> some View {
        ImportStateLayout(
            icon: "arrow.down.doc",
            breathes: true,
            title: "Bringing Everything Over"
        ) {
            VStack(spacing: 10) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .tint(Color.accentColor)
                    Text("Importing \(done) of \(total)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Importing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
            .padding(.horizontal, 24)
        }
    }

    private func finishedView(_ result: LegacyImporter.ImportResult) -> some View {
        ImportStateLayout(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            bounces: true,
            title: "Imported \(result.imported) \(result.imported == 1 ? "title" : "titles")",
            subtitle: result.skippedExisting > 0 ? "\(result.skippedExisting) already here" : nil
        ) {
            dismissButton(title: "Done")
        }
    }

    private func failureView(message: String) -> some View {
        ImportStateLayout(
            icon: "exclamationmark.triangle",
            iconColor: .orange,
            title: "Couldn’t Import",
            subtitle: message
        ) {
            VStack(spacing: 12) {
                Button("Try Again") { retry() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button("Not Now") {
                    importer.dismissOffer()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        }
    }

    private func dismissButton(title: String) -> some View {
        Button(title) { dismiss() }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    // MARK: - Copy

    private func offerMessage(_ summary: LegacyLibrary.Summary) -> String {
        var parts: [String] = []
        if summary.tvShowCount > 0 {
            parts.append("\(summary.tvShowCount) \(summary.tvShowCount == 1 ? "show" : "shows")")
        }
        if summary.movieCount > 0 {
            parts.append("\(summary.movieCount) \(summary.movieCount == 1 ? "movie" : "movies")")
        }
        if summary.collectionCount > 0 {
            parts.append("\(summary.collectionCount) \(summary.collectionCount == 1 ? "collection" : "collections")")
        }
        var message = "Found \(joined(parts)) from the previous version of Up Next."
        if persistence.role == .participant {
            message += " They’ll be added to the shared watchlist."
        }
        return message
    }

    private func joined(_ parts: [String]) -> String {
        guard let last = parts.last else { return "nothing" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Actions

    private func loadSummary() {
        guard summary == nil, summaryError == nil else { return }
        do {
            summary = try importer.summary()
        } catch {
            summaryError = error
        }
    }

    /// Unstructured on purpose: the import must outlive any view update, and the sheet can't be
    /// swiped away while it runs.
    private func startImport() {
        Task { await importer.run(library: library, lists: lists) }
    }

    /// A failure reading the store puts the user back on the offer; a failure *importing* goes
    /// straight back into the import they already asked for.
    private func retry() {
        guard summaryError == nil else {
            summaryError = nil
            loadSummary()
            return
        }
        startImport()
    }

    private var isWorking: Bool {
        switch importer.state {
        case .reading, .importing: true
        default: false
        }
    }

    /// Animation key: coarse enough that each progress tick doesn't re-run the state transition.
    private var stateKey: String {
        switch importer.state {
        case .idle:
            if summaryError != nil { return "error" }
            return summary == nil ? "loading" : "offer"
        case .reading, .importing: return "importing"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }
}

// MARK: - State layout

/// `EmptyStateView`'s shape with a tintable, optionally animated icon and arbitrary content below
/// the copy — the import sheet needs a green check and a progress bar, which the shared view
/// deliberately doesn't offer.
private struct ImportStateLayout<Content: View>: View {
    let icon: String
    var iconColor: Color = .secondary
    var breathes: Bool = false
    var bounces: Bool = false
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    @ScaledMetric(relativeTo: .largeTitle) private var iconWellSize: CGFloat = 80
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(iconColor)
                .symbolEffect(.breathe, isActive: breathes && !reduceMotion)
                .symbolEffect(.bounce, value: reduceMotion ? false : appeared)
                .frame(width: iconWellSize, height: iconWellSize)
                .background(.fill.tertiary, in: .circle)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard bounces, !reduceMotion else { return }
            appeared = true
        }
    }
}
