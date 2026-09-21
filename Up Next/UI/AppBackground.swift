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
                // Same structure as dark: a saturated centre, a cool corner and a warm corner.
                // Near-white stops collapse into "off-white", so these carry real chroma.
                Color(red: 0.93, green: 0.90, blue: 1.00),
                Color(red: 0.89, green: 0.85, blue: 0.99),
                Color(red: 0.96, green: 0.92, blue: 1.00),

                Color(red: 0.91, green: 0.88, blue: 0.99),
                Color(red: 0.86, green: 0.82, blue: 0.98),
                Color(red: 0.94, green: 0.91, blue: 1.00),

                Color(red: 0.90, green: 0.93, blue: 1.00),
                DesignTokens.Colors.backgroundBase,
                // Warm rose corner, the light counterpart of dark's warm stop.
                Color(red: 1.00, green: 0.90, blue: 0.92),
            ]
        )
        .ignoresSafeArea()
        .onAppear {
            guard drifts, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

#Preview {
    AppBackground()
}
