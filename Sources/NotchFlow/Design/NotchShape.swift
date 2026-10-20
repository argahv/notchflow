import SwiftUI

/// The one silhouette every state is drawn in. Its top is the screen edge; concave shoulders flow
/// out of the bezel into the sides, and the lower corners use Apple's continuous curvature. Every
/// parameter animates, so the hardware notch, the compact capsule and the workspace are one shape
/// changing size, never a card appearing under the camera.
struct NotchShape: Shape {
    /// Shoulder radius: how far the surface flares into the bezel at the top.
    var ear: CGFloat
    /// Lower corner radius (continuous).
    var corner: CGFloat
    /// At rest the shape sits just inside the hardware housing, so it disappears into it.
    var inset: CGFloat = 0
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(ear, corner), inset) }
        set { ear = newValue.first.first; corner = newValue.first.second; inset = newValue.second }
    }

    func path(in bounds: CGRect) -> Path {
        let rect = CGRect(x: bounds.minX + inset, y: bounds.minY,
                          width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - inset * 1.5))
        guard rect.width > 1, rect.height > 1 else { return Path() }
        let e = max(0, min(ear, rect.width / 6, rect.height / 3))
        let bodyWidth = rect.width - 2 * e
        let c = max(0, min(corner, bodyWidth / 2, rect.height * 0.75))
        let body = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: c, bottomTrailing: c, topTrailing: 0),
                                          style: .continuous)
            .path(in: CGRect(x: rect.minX + e, y: rect.minY, width: bodyWidth, height: rect.height))
        guard e > 0.25 else { return body }
        // Shoulders: both control points sit on the joint, so curvature is zero where the fillet
        // meets the screen edge and where it meets the side. It runs further down the side than
        // along the top, which reads as material stretching outward rather than a corner.
        let drop = min(e * 1.7, rect.height - c)
        let overlap: CGFloat = 0.75
        var shoulders = Path()
        for side in [CGFloat(-1), 1] {
            let edge = side < 0 ? rect.minX : rect.maxX
            let joint = edge - side * e
            shoulders.move(to: CGPoint(x: edge, y: rect.minY))
            shoulders.addCurve(to: CGPoint(x: joint, y: rect.minY + drop),
                               control1: CGPoint(x: joint, y: rect.minY), control2: CGPoint(x: joint, y: rect.minY))
            shoulders.addLine(to: CGPoint(x: joint - side * overlap, y: rect.minY + drop))
            shoulders.addLine(to: CGPoint(x: joint - side * overlap, y: rect.minY))
            shoulders.closeSubpath()
        }
        return body.union(shoulders)
    }
}
