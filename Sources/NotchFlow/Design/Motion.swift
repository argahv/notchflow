import SwiftUI

/// Named motion presets. Every animation in the app comes from here so timing stays coherent,
/// and every preset has a Reduce Motion form: short, linear-feeling, no overshoot.
enum Motion {
    /// macOS Reduce Motion, or the `NotchFlowReduceMotion` default (lets the path be verified without
    /// changing a system setting).
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "NotchFlowReduceMotion")
    }
    /// Low Power Mode keeps every transition but drops nonessential cost: no blur passes, no ambient loops.
    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// Button feedback, hover, small indicators: ≈90–150 ms.
    static var micro: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.13, dampingFraction: 0.9) }
    /// Toggles and small reveals: ≈150–220 ms.
    static var quick: Animation { reduced ? .easeOut(duration: 0.14) : .spring(response: 0.22, dampingFraction: 0.9) }
    /// The surface itself. Opening settles with a hint of give; closing is faster and never overshoots.
    static func fluid(opening: Bool) -> Animation {
        if reduced { return .easeOut(duration: 0.16) }
        return opening ? .spring(response: 0.34, dampingFraction: 0.86) : .spring(response: 0.28, dampingFraction: 1)
    }
    /// The silhouette between presentations, inside the Obsidian & Silver timing ranges:
    /// hover 100–160 ms, compact 180–260, full expansion 280–420, collapse 220–350. Springs retarget
    /// from the presented value with its velocity, so a change of mind mid-flight never snaps.
    static func surface(from: Presentation, to: Presentation, growing: Bool) -> Animation {
        if reduced { return .easeOut(duration: 0.16) }
        switch (from, to) {
        case (.collapsed, .collapsed): return .spring(response: 0.15, dampingFraction: 0.92)          // hover stretch
        case (_, .collapsed): return .spring(response: 0.28, dampingFraction: 1)                      // collapse
        case (.collapsed, .preview): return .spring(response: 0.22, dampingFraction: 0.88)            // compact
        case (_, .expanded) where from != .expanded: return .spring(response: 0.34, dampingFraction: 0.86) // full
        default: return growing ? .spring(response: 0.26, dampingFraction: 0.9) : .spring(response: 0.24, dampingFraction: 1)
        }
    }
    /// Absorbing a dropped file or a merging shape: more travel, more give.
    static var expressive: Animation { reduced ? .easeOut(duration: 0.16) : .spring(response: 0.48, dampingFraction: 0.72) }
    /// Sliding selection indicators.
    static var selection: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.86) }
}

/// Reveal order when the surface opens: the material leads, then primary content, then secondary
/// controls, then fine detail. Exits run in reverse with shorter durations, so detail leaves first
/// and the material retracts last.
enum RevealTier {
    case primary, secondary, detail
    var delay: Double {
        switch self { case .primary: 0.02; case .secondary: 0.09; case .detail: 0.15 }
    }
}

/// Content condenses out of the notch: slightly blurred, scaled and lifted, settling into place.
/// State-driven rather than a transition, because SwiftUI runs only the outermost inserted view's
/// transition; this lets every element of a newly shown surface keep its own tier and stagger.
private struct Reveal: ViewModifier {
    let tier: RevealTier
    let stagger: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        let reduced = Motion.reduced
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduced || Motion.lowPower ? 0 : 6)
            .scaleEffect(shown || reduced ? 1 : 0.97, anchor: .top)
            .offset(y: shown || reduced ? 0 : -5)
            .onAppear {
                guard !shown else { return }
                let animation: Animation = reduced
                    ? .easeOut(duration: 0.14).delay(tier.delay * 0.5)
                    : .spring(response: 0.36, dampingFraction: 0.9).delay(tier.delay + stagger)
                withAnimation(animation) { shown = true }
            }
    }
}

extension AnyTransition {
    /// The container of a surface's content: children reveal themselves; on the way out the whole
    /// layer fades fast so the material is the last thing to move.
    static var surfaceContent: AnyTransition {
        // Slightly longer than the incoming reveal's delay so the two overlap: never a blank frame.
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: Motion.reduced ? 0.08 : 0.15)))
    }
    /// Swapping content in place (sub-views, list ↔ detail): a short crossfade, no travel.
    static var swap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.05)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
    /// A list row arriving or leaving because data changed.
    static var row: AnyTransition {
        if Motion.reduced { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }
}

extension View {
    func reveal(_ tier: RevealTier, stagger: Double = 0) -> some View { modifier(Reveal(tier: tier, stagger: stagger)) }
}
