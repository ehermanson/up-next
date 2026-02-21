import SwiftUI

struct StarRatingLabel: View {
    let vote: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(String(format: "%.1f", vote))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let actions: Actions

    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 80, height: 80)
                .glassEffect(.regular, in: .circle)
            Text(title)
                .font(.title3)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

// MARK: - Toast

@MainActor @Observable
final class ToastState {
    var message: String?
    private(set) var triggerCount = 0
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            self.message = message
        }
        triggerCount += 1
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.3)) {
                self.message = nil
            }
        }
    }
}

private struct ToastCheckmark: View {
    @State private var drawn = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundStyle(.green)
            .symbolEffect(.bounce, value: drawn)
            .onAppear { drawn = true }
    }
}

struct ToastOverlayModifier: ViewModifier {
    @Environment(ToastState.self) private var toast
    var bottomPadding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = toast.message {
                    HStack(spacing: 8) {
                        ToastCheckmark()
                        Text(msg)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(.green.opacity(0.25)), in: .capsule)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .padding(.bottom, bottomPadding)
                }
            }
            .sensoryFeedback(.success, trigger: toast.triggerCount)
    }
}

extension View {
    func toastOverlay(bottomPadding: CGFloat = 20) -> some View {
        modifier(ToastOverlayModifier(bottomPadding: bottomPadding))
    }
}
