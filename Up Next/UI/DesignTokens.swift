import SwiftUI

/// Shared visual constants and surface styles.
///
/// Material rules (iOS 26 Liquid Glass):
/// - Glass (`.glassEffect`, `.buttonStyle(.glass)`) is reserved for the *control layer* that floats
///   over scrolling content: toolbar/tab bar (system-provided), floating action buttons, the toast,
///   the detail sheet's action row, and empty-state CTAs.
/// - Content — list rows, cards, pills, badges, provider logos, form fields — sits on a tinted
///   surface (`cardSurface` / `chipSurface`), never on glass. Glass on glass is not allowed.
enum DesignTokens {
    enum Radius {
        /// Full-size list row / card.
        static let card: CGFloat = 20
        /// Compact row (e.g. list picker rows, settings cards).
        static let cardCompact: CGFloat = 16
        /// Buttons, text fields, grid cells.
        static let control: CGFloat = 14
        /// Small square cells (symbol picker, list icons).
        static let cell: CGFloat = 12
        /// Poster thumbnails in rows.
        static let poster: CGFloat = 10
        /// Poster thumbnails in compact rows.
        static let posterSmall: CGFloat = 8
        /// Large poster cards in horizontal carousels.
        static let posterCard: CGFloat = 12
    }

    enum Colors {
        /// Anchor color of `AppBackground`. Use this when a view must blend into the background
        /// (e.g. a gradient fading an image into the sheet) instead of a hard-coded literal.
        static let backgroundBase = Color("BackgroundBase")

        /// Explicit variants for RGB blending, independent of UIKit's current traits.
        static func backgroundBase(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.09, green: 0.06, blue: 0.20)
                : Color(red: 0.95, green: 0.95, blue: 0.97)
        }

        /// Light-mode card surface: plain white on a near-neutral page, the standard iOS grouped
        /// idiom. Light mode is deliberately *not* a pale version of dark's purple — two earlier
        /// passes (opaque white cards with a shadow on a saturated lilac mesh, then accent-tinted
        /// cards on a near-white lilac page) both read as "everything is lavender" to someone who
        /// lives in light UIs. The brand lives in the accent (tabs, buttons, progress) and the
        /// mesh keeps only an imperceptible cool/warm drift; small surfaces use `.fill.tertiary`
        /// in both schemes.
        static let lightSurface = Color.white
        /// Neutral hairline on light cards: white on grouped gray alone is soft. 0.05 rendered
        /// within two points of the page's own gray and vanished; 0.10 is the least that reads
        /// as an edge.
        static let lightSurfaceBorder = Color.primary.opacity(0.10)
        /// Outline for a light-mode control drawn as a shape (the season checkmark ring, the
        /// unselected progress dashes) — `.fill.secondary` is black-alpha and vanishes on lilac.
        static let lightControlBorder = Color.primary.opacity(0.22)
    }

    enum Spacing {
        /// Inner padding of a full-size card.
        static let cardPadding: CGFloat = 12
        /// Vertical gap between list rows.
        static let rowGap: CGFloat = 10
        /// Horizontal inset of list content from the screen edge.
        static let screenInset: CGFloat = 16
        /// Gap between major sections in a scroll view.
        static let section: CGFloat = 20
    }
}

// MARK: - Surfaces

extension View {
    /// Tinted, non-glass surface for content cards and list rows.
    func cardSurface(cornerRadius: CGFloat = DesignTokens.Radius.card) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }

    /// Tinted, non-glass surface for small square cells (icons, logos, grid cells).
    /// Pass `tint` to emphasize a selected state.
    func cellSurface(cornerRadius: CGFloat = DesignTokens.Radius.cell, tint: Color? = nil) -> some View {
        modifier(SmallSurface(shape: RoundedRectangle(cornerRadius: cornerRadius), tint: tint))
    }

    /// Tinted, non-glass capsule surface for pills and small badges.
    func chipSurface(tint: Color? = nil) -> some View {
        modifier(SmallSurface(shape: Capsule(), tint: tint))
    }

    /// Tint for a `.bordered` button inside a card. In dark mode the accent purple sits too close
    /// to the grey fill to read, so the label is lifted toward white; light mode keeps `color`.
    func borderedTint(_ color: Color = .accentColor) -> some View {
        modifier(BorderedTint(color: color))
    }
}

private struct BorderedTint: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let color: Color

    func body(content: Content) -> some View {
        content.tint(colorScheme == .dark ? color.mix(with: .white, by: 0.4) : color)
    }
}

/// Card/row surface. Dark: `.fill.tertiary`. Light: white with a neutral hairline, no shadow —
/// the white-on-grouped-gray relationship of a system grouped list, plus an edge.
private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            if colorScheme == .dark {
                shape.fill(.fill.tertiary)
            } else {
                shape
                    .fill(DesignTokens.Colors.lightSurface)
                    .overlay(shape.strokeBorder(DesignTokens.Colors.lightSurfaceBorder))
            }
        }
    }
}

/// Cell/chip surface: `.fill.tertiary` in both schemes (white-alpha on dark purple, black-alpha
/// on white — each the system's own step). `tint` overlays a selected state.
private struct SmallSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        content.background {
            shape.fill(.fill.tertiary)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.25))
                    }
                }
        }
    }
}

// MARK: - Chip

/// Compact metadata pill: optional leading symbol + short text. Used for ratings, runtimes,
/// air dates, genre tags, counts, and filter chips.
struct Chip: View {
    var icon: String? = nil
    var iconColor: Color? = nil
    let text: String
    /// Emphasized chips read as "selected" (e.g. an active filter).
    var isEmphasized: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(iconColor ?? (isEmphasized ? Color.primary : Color.secondary))
            }
            Text(text)
                .contentTransition(.numericText())
        }
        .font(.caption)
        .fontWeight(.medium)
        .fontDesign(.rounded)
        .foregroundStyle(isEmphasized ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .chipSurface(tint: isEmphasized ? (tint ?? .accentColor) : nil)
    }
}

// MARK: - Previews

#Preview("Surfaces") {
    ZStack {
        AppBackground()
        VStack(spacing: 16) {
            Text("Card surface")
                .padding(DesignTokens.Spacing.cardPadding)
                .frame(maxWidth: .infinity)
                .cardSurface()

            HStack {
                Image(systemName: "star.fill").frame(width: 44, height: 44).cellSurface()
                Image(systemName: "star.fill").frame(width: 44, height: 44).cellSurface(tint: .accentColor)
            }

            HStack {
                Chip(icon: "star.fill", iconColor: .yellow, text: "8.3")
                Chip(icon: "calendar", text: "Next: Jun 15")
                Chip(text: "Drama")
                Chip(text: "Stream", isEmphasized: true)
            }
        }
        .padding()
    }
}
