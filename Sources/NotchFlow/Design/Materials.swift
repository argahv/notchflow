import SwiftUI

/// Polished black glass. The top is the camera housing, pure black; the interior is obsidian,
/// nearly opaque, so the camera housing and the workspace read as one material with no tonal step.
/// Translucency is a trace, for depth, never enough to show what's behind as grey.
struct ObsidianSurface: View {
    @EnvironmentObject var preferences: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var backdrop: BackdropService
    let band: CGFloat
    let form: SurfaceForm
    var body: some View {
        ZStack(alignment: .top) {
            if preferences.visualMode == .performance || reduceTransparency {
                Ink.obsidian
            } else {
                NativeMaterial()
                Ink.obsidian.opacity(0.95)
                if preferences.visualMode == .ultra, let image = backdrop.frame {
                    RefractiveGlass(image: image, form: form, band: band, capture: backdrop.captureSize).opacity(0.35)
                    Ink.void.opacity(0.45)
                }
            }
            // The housing eases into the interior over a long distance, so there's no seam to find.
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: min(0.95, band / max(band + 1, form.size.height))),
                                   .init(color: .black.opacity(0), location: min(1, (band + 44) / max(band + 1, form.size.height)))],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// Fades a stroke out toward the top, so edge light lives on the lower boundary and never draws a
/// line along the screen edge or across the attachment to the notch.
private struct LowerEdgeMask: View {
    let band: CGFloat
    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .clear, location: min(0.9, band * 0.6 / height)),
                                   .init(color: .black, location: min(1, (band + 10) / height))],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Silver reflection on the lower edge. Nearly invisible at rest; it catches light while the shape
/// moves and settles back when it stops. Hover brings it up at the lower corners first.
struct EdgeLight: View {
    let shape: NotchShape
    let presentation: Presentation
    let awareness: Awareness
    let moving: Bool
    let band: CGFloat
    var body: some View {
        let resting = presentation == .collapsed && awareness == .none
        let strength: Double = resting ? 0 : awareness == .drag ? 0.5 : moving ? 0.26 : presentation == .collapsed ? 0.2 : 0.11
        shape.stroke(Ink.silver, lineWidth: awareness == .drag ? 1.2 : 0.8)
            .mask { LowerEdgeMask(band: band) }
            // The lower corners catch the light more than the long bottom edge (masks multiply).
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.45), location: 0.3),
                                       .init(color: .black.opacity(0.45), location: 0.7), .init(color: .black, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .opacity(strength)
            .animation(moving ? Motion.micro : .easeOut(duration: 0.6), value: moving)
            .animation(Motion.quick, value: awareness)
            .animation(Motion.quick, value: presentation)
            .allowsHitTesting(false)
    }
}

struct Illumination: Equatable {
    let id = UUID()
    let tone: Tone
}

/// A notification's arrival: the lower edge briefly lights in the event's semantic colour, then
/// dissolves back into the surface. Never a full outline, never across the top.
struct RimIllumination: View {
    let shape: NotchShape
    let illumination: Illumination?
    let band: CGFloat
    var body: some View {
        let color = illumination?.tone.color ?? Ink.silver
        ZStack {
            shape.fill(RadialGradient(colors: [color.opacity(0), color.opacity(0.1)], center: .bottom, startRadius: 10, endRadius: 260))
            shape.stroke(color.opacity(0.85), lineWidth: 1.1).mask { LowerEdgeMask(band: band) }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: illumination?.id) { view, value in
            view.opacity(value)
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.14)
            CubicKeyframe(0.55, duration: 0.3)
            CubicKeyframe(0, duration: 0.9)
        }
        .allowsHitTesting(false)
    }
}

enum MaterialLevel { case ambient, interactive, elevated }

/// Materials 1–3 for cards and controls on the surface. Light comes from above: top edges catch a
/// highlight, bottoms stay quiet. Only elevated objects cast a shadow.
struct NookMaterial: ViewModifier {
    let level: MaterialLevel
    var radius: CGFloat = Radius.card
    var hovering = false
    var pressed = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            shape.fill(fill)
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(highlight), .white.opacity(0.012)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: .black.opacity(level == .elevated ? 0.4 : 0), radius: 12, y: 6)
        }
    }
    private var fill: Color {
        switch level {
        case .ambient: Ink.obsidian.opacity(0.8)
        case .interactive: pressed ? Ink.surface : hovering ? Ink.elevated : Ink.surface.opacity(0.92)
        case .elevated: hovering ? Ink.hover : Ink.elevated
        }
    }
    private var highlight: Double {
        switch level {
        case .ambient: 0.035
        case .interactive: hovering ? 0.1 : 0.055
        case .elevated: 0.12
        }
    }
}

extension View {
    func nookMaterial(_ level: MaterialLevel, radius: CGFloat = Radius.card, hovering: Bool = false, pressed: Bool = false) -> some View {
        modifier(NookMaterial(level: level, radius: radius, hovering: hovering, pressed: pressed))
    }
}
