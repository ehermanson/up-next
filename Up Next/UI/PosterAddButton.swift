import SwiftUI

/// The add ↔ added control drawn over poster artwork (Discover carousels, More Like This,
/// collection suggestions) — one treatment everywhere so "add" looks the same on every poster.
///
/// A solid disc (white with an accent plus → green with a white check) reads on any artwork; the
/// soft `.fill.tertiary` halo around it gives the hit target a visible edge and lifts the disc
/// off busy or white posters. Adding jiggles the glyph as it morphs and sends a green ring
/// out from the disc; removing morphs back without the ring. All motion is Reduce-Motion gated.
struct PosterAddButton: View {
    let isAdded: Bool
    let accessibilityLabel: String
    /// Halo diameter. 44 on Discover's large cards; smaller posters pass a compact size so the
    /// halo doesn't swallow the corner (the tap target shrinks with it — acceptable there).
    var size: CGFloat = 44
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped on each add (not remove) so the jiggle and ripple only celebrate the positive action.
    @State private var rippleTrigger = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(size < 44 ? .title3 : .title2)
                .fontWeight(.semibold)
                // Palette layers for `*.circle.fill`: glyph first, disc second.
                .symbolRenderingMode(.palette)
                .foregroundStyle(isAdded ? Color.white : Color.accentColor, isAdded ? Color.green : Color.white)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .checkmarkPop(isOn: isAdded)
                .keyframeAnimator(initialValue: JiggleFrame(), trigger: rippleTrigger) { view, frame in
                    view.scaleEffect(frame.scale).rotationEffect(.degrees(frame.angle))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        SpringKeyframe(1.3, duration: 0.14)
                        SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                    }
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(-18, duration: 0.12)
                        CubicKeyframe(12, duration: 0.12)
                        SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                    }
                }
                .background { ripple }
                .frame(width: size, height: size)
                .background(Circle().fill(.fill.tertiary))
                .contentShape(.circle)
        }
        .buttonStyle(PressSquish())
        .padding(4)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: isAdded) { _, added in
            if added && !reduceMotion { rippleTrigger += 1 }
        }
    }

    private var ripple: some View {
        Circle()
            .strokeBorder(Color.green, lineWidth: 2)
            .frame(width: size * 0.64, height: size * 0.64)
            .keyframeAnimator(initialValue: RippleFrame(), trigger: rippleTrigger) { view, frame in
                view.scaleEffect(frame.scale).opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1, duration: 0.01)
                    CubicKeyframe(2.1, duration: 0.5)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: 0.01)
                    CubicKeyframe(0, duration: 0.5)
                }
            }
            .allowsHitTesting(false)
    }

    private struct JiggleFrame {
        var scale: CGFloat = 1
        var angle: Double = 0
    }

    private struct RippleFrame {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    /// Squashes slightly while held so the tap feels springy before the state flips.
    private struct PressSquish: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1)
                .animation(Motion.pop, value: configuration.isPressed)
        }
    }
}

#Preview {
    @Previewable @State var added = false
    PosterAddButton(isAdded: added, accessibilityLabel: "Add") { added.toggle() }
        .padding(40)
        .background(.black)
}
