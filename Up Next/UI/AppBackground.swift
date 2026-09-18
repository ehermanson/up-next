import SwiftUI

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
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
    }
}

#Preview {
    AppBackground()
}
