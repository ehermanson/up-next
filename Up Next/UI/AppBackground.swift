import SwiftUI

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only the active tab's root background should drift — the four tab roots pass `true`; every
    /// sheet and pushed screen keeps the default `false` (a static mesh) so more than one instance
    /// isn't animating on screen at once.
    var drifts: Bool = false

    /// Toggled once on appear under a slow, autoreversing forever-animation. `MeshGradient`
    /// interpolates its control points, so nudging the interior points between two positions makes
    /// the whole background breathe quietly behind the glass. Reduce Motion pins it to the resting
    /// grid. This is a single property animation on four points — not a per-frame timeline — so it
    /// stays cheap even full-screen.
    @State private var drift = false

    private var points: [SIMD2<Float>] {
        let d: Float = (reduceMotion || !drift) ? 0 : 1
        // Corners stay pinned to the edges (moving them would open gaps); the edge-mid and centre
        // points swing on differing offsets so the whole field visibly churns.
        return [
            [0.0, 0.0], [0.5 + 0.06 * d, 0.0], [1.0, 0.0],
            [0.0, 0.5 - 0.07 * d], [0.5 + 0.08 * d, 0.5 + 0.07 * d], [1.0, 0.5 + 0.08 * d],
            [0.0, 1.0], [0.5 - 0.07 * d, 1.0], [1.0, 1.0],
        ]
    }

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: points,
            colors: colorScheme == .dark ? [
                Color(red: 0.07, green: 0.05, blue: 0.17),
                Color(red: 0.11, green: 0.07, blue: 0.24),
                Color(red: 0.08, green: 0.06, blue: 0.20),

                Color(red: 0.10, green: 0.06, blue: 0.22),
                Color(red: 0.16, green: 0.10, blue: 0.32),
                Color(red: 0.09, green: 0.07, blue: 0.23),

                Color(red: 0.06, green: 0.06, blue: 0.16),
                DesignTokens.Colors.backgroundBase,
                // Slightly warmer corner so the mesh doesn't read as flat purple.
                Color(red: 0.22, green: 0.12, blue: 0.15),
            ] : [
                // Near-neutral grouped-background gray (~#F2F2F7) with a cool/warm drift of a
                // point or two — enough for the mesh to breathe, not enough to read as a color.
                // Any real chroma here made the whole light design "lavender" (see
                // `DesignTokens.Colors.lightSurface`).
                Color(red: 0.95, green: 0.95, blue: 0.97),
                Color(red: 0.94, green: 0.94, blue: 0.97),
                Color(red: 0.96, green: 0.96, blue: 0.98),

                Color(red: 0.95, green: 0.95, blue: 0.97),
                Color(red: 0.94, green: 0.94, blue: 0.96),
                Color(red: 0.96, green: 0.96, blue: 0.98),

                Color(red: 0.94, green: 0.95, blue: 0.98),
                DesignTokens.Colors.backgroundBase,
                // Warm corner, the light counterpart of dark's warm stop.
                Color(red: 0.97, green: 0.95, blue: 0.95),
            ]
        )
        .ignoresSafeArea()
        .onAppear {
            guard drifts, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
        // `TabView` keeps visited tabs alive, so without this every tab root visited keeps its
        // forever-animation running off screen. Snapping back un-animated replaces the repeat.
        .onDisappear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { drift = false }
        }
    }
}

#Preview {
    AppBackground()
}
