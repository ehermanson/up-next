import SwiftUI

/// Shared motion vocabulary for the app's whimsical touches. Keeping the springs, transitions and
/// the animated-checkmark treatment in one place means new surfaces animate the same way the
/// existing ones do.
///
/// Rule: anything here that moves must be gated by `@Environment(\.accessibilityReduceMotion)` at
/// the call site (or degrade to no motion), matching the discipline the watched-disclosure and
/// hero-tint code already follow. The `checkmarkPop` modifier below handles that gating itself.
enum Motion {
    /// Soft settle for posters/artwork as they finish loading. Applied by callers to the `.success`
    /// image inside `CachedAsyncImage`; the container animates the phase change on a *fresh*
    /// download only (never a cache hit), so scrolling a populated list stays flash-free.
    static let posterAppear: AnyTransition = .opacity.combined(with: .scale(scale: 0.96))

    /// Springy pop for state flips — checkmarks filling, the Add pill flipping to its status style.
    static let pop: Animation = .spring(response: 0.34, dampingFraction: 0.6)

    /// Cross-fade for a control that swaps between two forms (gear ↔ avatars, addable ↔ status pill).
    static let morph: AnyTransition = .scale(scale: 0.7).combined(with: .opacity)

    /// Insert/remove for a checkmark that appears conditionally (a badge that isn't always present),
    /// rather than swapping systemName in place. Pair with `.symbolEffect(.bounce, value:)`.
    static let checkPop: AnyTransition = .scale(scale: 0.3).combined(with: .opacity)
}

extension View {
    /// The app's standard animated treatment for a single symbol that swaps between two states —
    /// add ↔ added, unchecked ↔ checked, bookmark ↔ watched. Pairs a symbol-replace morph with a
    /// bounce and a spring, all reduce-motion aware.
    ///
    /// The `Image`'s `systemName` must be a ternary on `isOn` (one `Image`, not an `if/else` of two
    /// separate `Image`s) so the replace transition has a single symbol to morph.
    func checkmarkPop(isOn: Bool) -> some View {
        modifier(CheckmarkPop(isOn: isOn))
    }
}

private struct CheckmarkPop: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .symbolEffect(.bounce, value: reduceMotion ? false : isOn)
            .animation(reduceMotion ? nil : Motion.pop, value: isOn)
    }
}
