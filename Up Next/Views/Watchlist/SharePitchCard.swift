import SwiftUI

/// One-time pitch for sharing, shown at the top of the TV Shows tab only (see
/// `TVShowsTabView`'s visibility rule — sharing is the 2.0 headline feature but nothing else in
/// the main UI ever states it). Dismissing is permanent, via `ProviderSettings.hasDismissedSharePitch`
/// — either the close button, or tapping through to the share sheet counts as "handled".
struct SharePitchCard: View {
    private let settings = ProviderSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
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
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Dismiss")
            }

            ShareLink(item: LibraryShareItem(), preview: SharePreview("Up Next library")) {
                Label("Share with a partner", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            // Tapping through to the share sheet is enough to consider the pitch handled — the
            // card shouldn't reappear once the user has engaged with it, whether or not they
            // complete the share.
            .simultaneousGesture(TapGesture().onEnded { dismiss() })
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
