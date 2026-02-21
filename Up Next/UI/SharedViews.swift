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
    private(set) var current: ToastItem?
    private(set) var triggerCount = 0
    private var queue: [String] = []
    private var dismissTask: Task<Void, Never>?
    private var nextID = 0

    struct ToastItem: Equatable {
        let id: Int
        let message: String
    }

    func show(_ message: String) {
        triggerCount += 1
        queue.append(message)

        if current == nil {
            advanceQueue()
        } else {
            quickDismissThenAdvance()
        }
    }

    private func advanceQueue() {
        guard !queue.isEmpty else { return }
        let message = queue.removeFirst()
        let item = ToastItem(id: nextID, message: message)
        nextID += 1
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            current = item
        }
        scheduleAutoDismiss()
    }

    private func quickDismissThenAdvance() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            current = nil
        }
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            advanceQueue()
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            if queue.isEmpty {
                withAnimation(.easeOut(duration: 0.3)) {
                    current = nil
                }
            } else {
                quickDismissThenAdvance()
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
                if let item = toast.current {
                    HStack(spacing: 8) {
                        ToastCheckmark()
                        Text(item.message)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                    }
                    .id(item.id)
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
