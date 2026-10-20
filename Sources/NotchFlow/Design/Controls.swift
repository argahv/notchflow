import SwiftUI

private struct NookNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// One namespace for the whole surface so elements can travel between states.
    var nookNamespace: Namespace.ID? {
        get { self[NookNamespaceKey.self] }
        set { self[NookNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func nookMatched(_ id: some Hashable, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace { matchedGeometryEffect(id: AnyHashable(id), in: namespace, isSource: isSource) } else { self }
    }
}

/// Circular glyph control: header actions, transport, small utilities.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var tint: Color = Ink.primary
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, size: size, tint: tint) }
    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(!enabled ? Ink.disabled : hovering && tint == Ink.secondary ? Ink.primary : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Ink.hover.opacity(active ? (configuration.isPressed ? 1 : 0.8) : 0)))
                .scaleEffect(configuration.isPressed && enabled ? 0.95 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Motion.micro, value: hovering)
                .animation(Motion.micro, value: configuration.isPressed)
        }
    }
}

/// Text action. Prominent pills carry the one primary action of a surface.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tone: Tone = .accent
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, prominent: prominent, tone: tone) }
    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let tone: Tone
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(!enabled ? Ink.disabled : prominent ? onTone : Ink.primary)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(Ink.silver.opacity(prominent || !enabled ? 0 : hovering ? 0.12 : 0.06), lineWidth: 0.5))
                .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
                .contentShape(Capsule())
                .onHover { hovering = enabled && $0 }
                .animation(Motion.micro, value: hovering)
                .animation(Motion.micro, value: configuration.isPressed)
        }
        /// Text on a filled pill: white on blue and red, black on the lighter tones.
        private var onTone: Color { [.accent, .red].contains(tone) ? .white : Ink.void }
        private var fill: Color {
            if !enabled { return Ink.surface }
            if prominent { return tone.color.opacity(configuration.isPressed ? 0.8 : hovering ? 1 : 0.92) }
            return configuration.isPressed ? Ink.elevated : hovering ? Ink.hover : Ink.elevated
        }
    }
}

/// Whole-row button on the interactive material.
struct RowButtonStyle: ButtonStyle {
    var radius: CGFloat = Radius.card
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, radius: radius) }
    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .nookMaterial(.interactive, radius: radius, hovering: hovering, pressed: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(Motion.micro, value: hovering)
                .animation(Motion.micro, value: configuration.isPressed)
        }
    }
}

/// Feature switcher glyph in the band beside the notch. The selection pill travels between items.
struct DockButtonStyle: ButtonStyle {
    let selected: Bool
    var badge: Tone?
    /// Route buttons share one sliding selection; toggles (pin) light up in place.
    var slides = true
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, selected: selected, badge: badge, slides: slides)
    }
    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let badge: Tone?
        let slides: Bool
        @Environment(\.nookNamespace) private var namespace
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected || hovering ? Ink.primary : Ink.secondary)
                .frame(width: 26, height: 24)
                .background {
                    if selected {
                        Capsule().fill(Ink.elevated).overlay(Capsule().strokeBorder(Ink.silver.opacity(0.14), lineWidth: 0.5))
                            .nookMatched("dock-selection", in: slides ? namespace : nil)
                    } else if hovering {
                        Capsule().fill(Ink.hover.opacity(0.75))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge { Circle().fill(badge.color).frame(width: 6, height: 6).offset(x: -2, y: 2).transition(.scale.combined(with: .opacity)) }
                }
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Motion.micro, value: hovering)
                .animation(Motion.micro, value: configuration.isPressed)
                .animation(Motion.quick, value: badge)
        }
    }
}

/// A status or category glyph on a soft disc of its own colour.
struct ToneGlyph: View {
    let symbol: String
    let tone: Tone
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(Circle().fill(tone.color.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// Sub-view header: a back affordance that names the current place.
struct BackHeader<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary))
                .help("Back · Esc").accessibilityLabel("Back")
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(height: 28)
    }
}

extension BackHeader where Trailing == EmptyView {
    init(title: String, back: @escaping () -> Void) { self.init(title: title, back: back, trailing: { EmptyView() }) }
}

/// Empty states stay one compact row with a single clear action, never a large blank panel.
struct CompactEmptyState: View {
    let symbol: String
    var tone: Tone = .silver
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            ToneGlyph(symbol: symbol, tone: tone, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary)
                Text(detail).font(TypeScale.secondary).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .nookMaterial(.ambient)
    }
}

/// Determinate progress only; indeterminate work shows a spinner instead of an invented percentage.
struct ProgressLine: View {
    let value: Double
    var tone: Tone = .silver
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hover)
                Capsule().fill(tone.color).frame(width: max(3, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.4), value: value)
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(value * 100)) percent")
    }
}
