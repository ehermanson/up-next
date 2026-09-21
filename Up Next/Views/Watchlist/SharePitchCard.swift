import SwiftUI

/// One-time pitch for sharing, shown at the top of the TV Shows tab only (see
/// `TVShowsTabView`'s visibility rule — sharing is the 2.0 headline feature but nothing else in
/// the main UI ever states it). Dismissing is permanent, via `ProviderSettings.hasDismissedSharePitch`
/// — the close button sets it; the card also retires itself once a partner has joined.
struct SharePitchCard: View {
    private let settings = ProviderSettings.shared
    private let persistence = PersistenceController.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .frame(width: 44, height: 44)
                    .cellSurface(tint: .accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Watching with someone?")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Share your list with one person and you'll both see and edit the same watchlist and collections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Dismiss")
            }

            ShareLink(item: LibraryShareItem(existingShare: persistence.liveShare), preview: SharePreview("Up Next library")) {
                Label("Share with a partner", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            // Deliberately not dismissed on tap: the share sheet is presented *from* this link,
            // so removing the card here would tear down the presenter mid-presentation. The card
            // goes away by itself once a partner joins (see `TVShowsTabView.showsSharePitch`).
        }
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            settings.hasDismissedSharePitch = true
        }
    }
}

#Preview {
    ZStack {
        AppBackground()
        SharePitchCard()
            .padding(20)
    }
}
