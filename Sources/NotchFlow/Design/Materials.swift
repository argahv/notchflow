import SwiftUI

/// The surface outline: full-width top edge, concave ears where it meets the bezel, convex bottom
/// corners. Both radii animate, so the silhouette never jumps from sharp to round.
struct NotchShape: Shape {
    var ear: CGFloat
    var corner: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, corner) }
        set { ear = newValue.first; corner = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let e = max(0, min(ear, rect.width / 4, rect.height / 2))
        let c = max(0, min(corner, rect.height - e, (rect.width - 2 * e) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - c))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e + c, y: rect.maxY), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e - c, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - c), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        // Left open: fills and clips close it implicitly, while strokes skip the screen's top edge.
        return path
    }
}

/// Material 0 → Balanced/Ultra glass. The menu-bar band is pure black so the surface reads as the
/// camera housing itself; below it, a near-black glass with a slight lift toward the bottom.
struct ObsidianSurface: View {
    @EnvironmentObject var preferences: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var backdrop: BackdropService
    let band: CGFloat
    let form: SurfaceForm
    var body: some View {
        ZStack(alignment: .top) {
            if preferences.visualMode == .performance || reduceTransparency {
                Ink.void
            } else {
                NativeMaterial()
                Ink.obsidian.opacity(0.86)
                if preferences.visualMode == .ultra, let image = backdrop.frame {
                    RefractiveGlass(image: image, form: form, band: band, capture: backdrop.captureSize).opacity(0.6)
                    Ink.void.opacity(0.3)
                }
                LinearGradient(colors: [.clear, Ink.surface.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            VStack(spacing: 0) {
                Color.black.frame(height: band)
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 34)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Resting edge light: the lower edge catches light, the sides fade out before the band, the top
/// (the bezel) never does. Awareness swaps it for a restrained iris rim.
struct EdgeLight: View {
    let shape: NotchShape
    let presentation: Presentation
    let awareness: Awareness
    var body: some View {
        ZStack {
            shape.stroke(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                .init(color: .white.opacity(0), location: 0.25),
                                                .init(color: .white.opacity(0.1), location: 1)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .opacity(presentation == .collapsed ? 0 : 1)
            shape.stroke(LinearGradient(colors: [Ink.iris.opacity(0), Ink.iris.opacity(awareness == .drag ? 0.9 : 0.5)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: awareness == .drag ? 1.5 : 1)
                .opacity(presentation == .collapsed && awareness != .none ? 1 : 0)
        }
        .animation(Motion.quick, value: awareness)
        .allowsHitTesting(false)
    }
}

struct Illumination: Equatable {
    let id = UUID()
    let tone: Tone
}

/// Material 4: a brief rim of light in the event's colour that dissolves back into the surface.
struct RimIllumination: View {
    let shape: NotchShape
    let illumination: Illumination?
    var body: some View {
        let color = illumination?.tone.color ?? Ink.iris
        ZStack {
            shape.fill(RadialGradient(colors: [color.opacity(0), color.opacity(0.14)], center: .top, startRadius: 40, endRadius: 320))
            shape.stroke(color.opacity(0.9), lineWidth: 1.3)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: illumination?.id) { view, value in
            view.opacity(value)
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.14)
            CubicKeyframe(0.6, duration: 0.3)
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
