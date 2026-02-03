import SwiftUI

/// A reusable circular button style that renders a "liquid glass" appearance
/// and adapts for light and dark modes.
public struct LiquidGlassCircleButtonStyle: ButtonStyle {
    public init(size: CGFloat = 44) {
        self.size = size
    }

    private let size: CGFloat

    public func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonBody(configuration: configuration, size: size)
    }

    private struct LiquidGlassButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let size: CGFloat
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.headline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(colorScheme == .dark ? .ultraThinMaterial : .thinMaterial)
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.55 : 0.35),
                                    Color.white.opacity(colorScheme == .dark ? 0.15 : 0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ), lineWidth: 1
                        )
                        .blendMode(.overlay)
                )
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.35 : 0.18),
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.02),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blur(radius: 0.5)
                        .allowsHitTesting(false)
                )
                .shadow(
                    color: (colorScheme == .dark
                        ? Color.black.opacity(0.25) : Color.black.opacity(0.08)), radius: 10, x: 0,
                    y: 6
                )
                .shadow(
                    color: (colorScheme == .dark
                        ? Color.blue.opacity(0.25) : Color.blue.opacity(0.15)), radius: 8, x: 0,
                    y: 2
                )
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .animation(
                    .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
        }
    }
}
