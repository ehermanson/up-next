import SwiftUI

struct AppBackground: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
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
            ]
        )
        .ignoresSafeArea()
    }
}

#Preview {
    AppBackground()
}
