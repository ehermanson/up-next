import SwiftUI

struct AppBackground: View {
    var body: some View {
        if #available(iOS 26, *) {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
                ],
                colors: [
                    Color(red: 0.05, green: 0.04, blue: 0.14),
                    Color(red: 0.10, green: 0.05, blue: 0.22),
                    Color(red: 0.04, green: 0.06, blue: 0.18),

                    Color(red: 0.08, green: 0.04, blue: 0.18),
                    Color(red: 0.14, green: 0.06, blue: 0.28),
                    Color(red: 0.06, green: 0.08, blue: 0.22),

                    Color(red: 0.03, green: 0.03, blue: 0.10),
                    Color(red: 0.08, green: 0.04, blue: 0.16),
                    Color(red: 0.04, green: 0.05, blue: 0.14),
                ]
            )
            .ignoresSafeArea()
        } else {
            Color(red: 0.04, green: 0.02, blue: 0.12)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    AppBackground()
}
