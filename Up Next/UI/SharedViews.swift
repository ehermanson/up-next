import SwiftUI

/// Single source of truth for formatting a TMDB air-date string ("yyyy-MM-dd")
/// into a "Next: MMM d" label. Parses *and* displays in UTC so the rendered day
/// never shifts with the device time zone — this keeps the list card and the
/// detail view in agreement (they previously parsed the same string differently).
enum AirDateFormat {
    private static let input: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// Returns a "Next: Jun 15" label, or nil if the string can't be parsed.
    static func nextLabel(from dateString: String) -> String? {
        guard let date = input.date(from: dateString) else { return nil }
        return "Next: \(display.string(from: date))"
    }
}

struct StarRatingLabel: View {
    let vote: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(vote, format: .number.precision(.fractionLength(1)))
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
    private var queue: [QueuedToast] = []
    private var currentAction: (() -> Void)?
    private var dismissTask: Task<Void, Never>?
    private var nextID = 0

    struct ToastItem: Equatable {
        let id: Int
        let message: String
        let icon: String
        let actionLabel: String?
    }

    private struct QueuedToast {
        let message: String
        let icon: String
        let actionLabel: String?
        let action: (() -> Void)?
    }

    /// Shows a transient toast. Pass `actionLabel`/`action` to add a tappable button (e.g. "Undo").
    func show(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        triggerCount += 1
        queue.append(QueuedToast(message: message, icon: icon, actionLabel: actionLabel, action: action))

        if current == nil {
            advanceQueue()
        } else {
            quickDismissThenAdvance()
        }
    }

    /// Invokes the current toast's action (if any) and dismisses immediately.
    func performAction() {
        let action = currentAction
        dismissTask?.cancel()
        currentAction = nil
        withAnimation(.easeOut(duration: 0.2)) {
            current = nil
        }
        action?()
    }

    private func advanceQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let item = ToastItem(id: nextID, message: next.message, icon: next.icon, actionLabel: next.actionLabel)
        nextID += 1
        currentAction = next.action
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            current = item
        }
        scheduleAutoDismiss()
    }

    private func quickDismissThenAdvance() {
        dismissTask?.cancel()
        currentAction = nil
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
        // Action toasts (e.g. Undo) linger longer so the action stays reachable.
        let visibleDuration: Duration = current?.actionLabel != nil ? .seconds(4.5) : .seconds(2.5)
        dismissTask = Task {
            try? await Task.sleep(for: visibleDuration)
            guard !Task.isCancelled else { return }
            if queue.isEmpty {
                currentAction = nil
                withAnimation(.easeOut(duration: 0.3)) {
                    current = nil
                }
            } else {
                quickDismissThenAdvance()
            }
        }
    }
}

private struct ToastIcon: View {
    let name: String
    let color: Color
    @State private var drawn = false

    var body: some View {
        Image(systemName: name)
            .font(.body)
            .fontWeight(.semibold)
            .foregroundStyle(color)
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
                    // Action toasts (e.g. Undo) use neutral styling; plain confirmations stay green.
                    let isAction = item.actionLabel != nil
                    HStack(spacing: 8) {
                        ToastIcon(name: item.icon, color: isAction ? .secondary : .green)
                        Text(item.message)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                        if let actionLabel = item.actionLabel {
                            Button(actionLabel) {
                                toast.performAction()
                            }
                            .font(.callout.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.indigo)
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                    }
                    .id(item.id)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(isAction ? .white.opacity(0.08) : .green.opacity(0.25)), in: .capsule)
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

// MARK: - Previews

#Preview("Star Ratings") {
    HStack(spacing: 20) {
        StarRatingLabel(vote: 5.0)
        StarRatingLabel(vote: 7.8)
        StarRatingLabel(vote: 9.2)
    }
    .padding()
}

#Preview("Empty State — Full") {
    EmptyStateView(
        icon: "tv",
        title: "No TV Shows",
        subtitle: "Add shows from the Discover tab to start tracking what you watch."
    ) {
        Button("Browse Shows") {}
            .buttonStyle(.borderedProminent)
    }
}

#Preview("Empty State — Minimal") {
    EmptyStateView(icon: "film", title: "No Movies")
}

#Preview("Toast Overlay") {
    let toast = ToastState()
    Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toastOverlay()
        .environment(toast)
        .onAppear { toast.show("Added to Watchlist") }
}
