import CoreData
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

    /// Used for dates outside the current year ("Jul 8, 2027") — a bare "Jul 8" ten months
    /// out reads as if it were this year.
    private static let displayWithYear: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()

    /// "Jun 15" within the current UTC year, otherwise "Jul 8, 2027".
    private static func dayLabel(for date: Date, now: Date = .now) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? display : displayWithYear).string(from: date)
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// Same UTC calendar the formatters use, so "is this today?" agrees with what's rendered.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Parses a TMDB "yyyy-MM-dd" string as midnight UTC, or nil if it can't be parsed.
    static func date(from dateString: String) -> Date? {
        input.date(from: dateString)
    }

    /// Start of `date`'s UTC day — the comparison basis for "today or later".
    static func startOfUTCDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// "Jun 15" (or "Jul 8, 2027" outside the current year), or nil if the string can't be parsed.
    static func shortLabel(from dateString: String) -> String? {
        guard let date = date(from: dateString) else { return nil }
        return dayLabel(for: date)
    }

    /// "Today" / "Tomorrow" / the weekday name within the next six days / "Jun 15".
    /// Days are counted in the UTC calendar, matching how the date was parsed.
    static func relativeLabel(for date: Date, now: Date = .now) -> String {
        let today = startOfUTCDay(for: now)
        let target = startOfUTCDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return weekday.string(from: target)
        default: return dayLabel(for: target, now: now)
        }
    }

    /// Returns a "Next: Jun 15" label, or nil if the string can't be parsed.
    static func nextLabel(from dateString: String) -> String? {
        guard let short = shortLabel(from: dateString) else { return nil }
        return "Next: \(short)"
    }
}

struct StarRatingLabel: View {
    let vote: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(vote, format: .number.precision(.fractionLength(1)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fontDesign(.rounded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(vote.formatted(.number.precision(.fractionLength(1))))")
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let actions: Actions

    /// Icon well scales with the user's text size so the symbol never overflows it.
    @ScaledMetric(relativeTo: .largeTitle) private var iconWellSize: CGFloat = 80

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .frame(width: iconWellSize, height: iconWellSize)
                .cellSurface(cornerRadius: iconWellSize / 2)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
    /// The `SensoryFeedback` for the toast that triggered the most recent `triggerCount` bump —
    /// read by the single root `.sensoryFeedback` (see `ContentView`) rather than each of the four
    /// tab roots + the search sheet firing their own, which used to fire the haptic multiple times
    /// per toast. Set synchronously in `show()` so it's current by the time SwiftUI observes the
    /// `triggerCount` change, even when the toast itself is still queued behind another one.
    private(set) var lastFeedback: SensoryFeedback?
    private var queue: [QueuedToast] = []
    private var currentAction: (() -> Void)?
    private var dismissTask: Task<Void, Never>?
    private var nextID = 0

    struct ToastItem: Equatable {
        let id: Int
        let message: String
        let icon: String
        /// Removals are orange (`minus.circle.fill`, same as the Activity screen); nil keeps the
        /// default — green for confirmations, secondary for other action toasts.
        let iconTint: Color?
        let actionLabel: String?
    }

    private struct QueuedToast {
        let message: String
        let icon: String
        let iconTint: Color?
        let actionLabel: String?
        let feedback: SensoryFeedback?
        let action: (() -> Void)?
    }

    /// Shows a transient toast. Pass `actionLabel`/`action` to add a tappable button (e.g. "Undo").
    /// `feedback` picks the haptic: `.success` for adds/watched (the default), `.impact` for
    /// removals/undo-able deletes, `nil` for purely informational toasts (errors, partner activity).
    func show(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        iconTint: Color? = nil,
        actionLabel: String? = nil,
        feedback: SensoryFeedback? = .success,
        action: (() -> Void)? = nil
    ) {
        triggerCount += 1
        lastFeedback = feedback
        queue.append(QueuedToast(message: message, icon: icon, iconTint: iconTint, actionLabel: actionLabel, feedback: feedback, action: action))

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
        let item = ToastItem(id: nextID, message: next.message, icon: next.icon, iconTint: next.iconTint, actionLabel: next.actionLabel)
        nextID += 1
        currentAction = next.action
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            current = item
        }
        postAnnouncement(for: item)
        scheduleAutoDismiss()
    }

    /// VoiceOver doesn't otherwise learn about a toast — it's not focused content, just an overlay.
    private func postAnnouncement(for item: ToastItem) {
        let text = item.actionLabel != nil ? "\(item.message). Undo available." : item.message
        AccessibilityNotification.Announcement(text).post()
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        Image(systemName: name)
            .font(.body)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: reduceMotion ? false : drawn)
            .onAppear {
                guard !reduceMotion else { return }
                drawn = true
            }
    }
}

struct ToastOverlayModifier: ViewModifier {
    @Environment(ToastState.self) private var toast
    @Environment(\.colorScheme) private var colorScheme
    var bottomPadding: CGFloat = 20

    /// Neutral action-toast tint: white-alpha frosts dark glass but does nothing on a light
    /// background, so light mode leans on the accent instead.
    private var neutralTint: Color {
        colorScheme == .dark ? .white.opacity(0.08) : Color.accentColor.opacity(0.10)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let item = toast.current {
                    // Action toasts (e.g. Undo) use neutral styling; plain confirmations stay green.
                    let isAction = item.actionLabel != nil
                    HStack(spacing: 8) {
                        ToastIcon(name: item.icon, color: item.iconTint ?? (isAction ? .secondary : .green))
                        Text(item.message)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                        if let actionLabel = item.actionLabel {
                            // A filled capsule, not accent text: the toast is glass over whatever
                            // is scrolling underneath, so plain text has no guaranteed contrast.
                            Button(actionLabel) {
                                toast.performAction()
                            }
                            .font(.subheadline.weight(.bold))
                            .fontDesign(.rounded)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(Color.accentColor)
                            .padding(.leading, 4)
                        }
                    }
                    .id(item.id)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(isAction ? neutralTint : .green.opacity(0.25)), in: .capsule)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 12, y: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .padding(.bottom, bottomPadding)
                }
            }
    }
}

extension View {
    func toastOverlay(bottomPadding: CGFloat = 20) -> some View {
        modifier(ToastOverlayModifier(bottomPadding: bottomPadding))
    }
}

// MARK: - Tab Root Navigation Bar

extension View {
    /// Tab roots keep the navigation bar transparent once the large title scrolls away. iOS's
    /// default material band there put a flat slab under the glass toolbar buttons and flattened
    /// their Liquid Glass; only the system's soft scroll-edge blur is left.
    ///
    /// The collapsed inline title is blanked too: iOS centers it unless the trailing items crowd
    /// it, then moves it leading — so "TV Shows" (beside "+ Edit") sat left while "Movies" and
    /// "Discover" sat centered. The large title at rest is unaffected.
    func tabRootNavigationBar() -> some View {
        toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
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
            .buttonStyle(.glassProminent)
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
        .onAppear { toast.show("Added Severance") }
}

// Library-only feedback shared by list actions and detail-sheet dismissal.
extension ToastState {
    func showWatchedMove(for item: ListItem, previous: ListItem.WatchState, onUndo: @escaping () -> Void) {
        let current = item.watchState
        guard !previous.isInWatchedSection, current.isInWatchedSection else { return }
        show("Moved \(item.media?.title ?? "title") to Watched", icon: "checkmark.circle.fill", actionLabel: "Undo") {
            // A later local or partner edit takes precedence over this older undo action.
            guard !item.isDeleted, item.managedObjectContext != nil, item.watchState == current else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                item.restoreWatchState(previous)
                onUndo()
            }
        }
    }
}
