import Foundation

public enum Presentation: String, Codable, Sendable { case collapsed, preview, expanded }
/// Something is approaching the notch without having entered it yet.
public enum Awareness: String, Codable, Sendable { case none, pointer, drag }
public enum InteractionEvent: Sendable {
    case enter, leave, expand, dismiss, togglePin, beginDrag, endDrag, beginEditing, endEditing, attention
    case approach, dragApproach, retreat
    /// Portal: the drag came close; a drop is being received (file promises); it was kept; it couldn't
    /// be kept; the result has been shown.
    case dragAttract, receive, absorb, rejectDrop, settlePortal
}

/// A drag's progress toward the resting or previewing notch. An open workspace takes drops into its
/// own surface instead, so the portal only exists outside it.
public enum PortalStage: String, Codable, Sendable {
    /// Nothing is being carried toward the notch.
    case closed
    /// An eligible drag is nearby: the rim brightens and the silhouette swells slightly.
    case aware
    /// The drag is close: a compact target says what's coming and how many.
    case attracted
    /// The drag is over the target: the opening deepens and says what a drop does.
    case open
    /// The drop was accepted and its files are still arriving (file promises).
    case receiving
    /// What was dropped is on the shelf and is being drawn in.
    case absorbing
    /// The drop couldn't be kept. Nothing was lost; the source still has it.
    case failed

    /// A drag is still in flight, as opposed to a result being shown.
    public var carrying: Bool { [.aware, .attracted, .open].contains(self) }
}

/// Presentation, dismissal, and input are independent axes. An incoming event never
/// replaces the workspace while the user is editing or dragging.
public struct InteractionState: Equatable, Sendable {
    public private(set) var presentation: Presentation = .collapsed
    public private(set) var pinned = false
    public private(set) var dragging = false
    public private(set) var editing = false
    public private(set) var awareness: Awareness = .none
    public private(set) var portal: PortalStage = .closed
    public init() {}

    public mutating func send(_ event: InteractionEvent) {
        switch event {
        case .enter:
            if presentation == .collapsed { presentation = .preview }
        case .leave:
            if !pinned && !dragging && !editing { presentation = .collapsed }
        case .expand: presentation = .expanded; portal = .closed
        case .dismiss:
            pinned = false; dragging = false; editing = false; awareness = .none; portal = .closed; presentation = .collapsed
        case .togglePin:
            pinned.toggle()
            if pinned { presentation = .expanded; portal = .closed }
        case .beginDrag:
            // Over the surface: an open workspace receives the drop itself; otherwise the portal opens.
            dragging = true
            if presentation != .expanded { portal = .open; awareness = .drag }
        case .endDrag:
            // Left the surface without dropping: back to the target, which the pointer is still near.
            dragging = false
            if portal == .open { portal = .attracted } else if awareness == .drag && !portal.carrying { awareness = .none }
        case .beginEditing: editing = true; presentation = .expanded
        case .endEditing: editing = false
        case .attention:
            // A passive event never takes the surface from a drag or from a drop's result.
            if presentation == .collapsed && portal == .closed { presentation = .preview }
        case .approach:
            // A file drag outranks the pointer: it keeps the drop target ready.
            if awareness == .none { awareness = .pointer }
        case .dragApproach:
            awareness = .drag
            if presentation != .expanded, [.closed, .attracted].contains(portal) { portal = .aware }
        case .dragAttract:
            awareness = .drag
            if presentation != .expanded, [.closed, .aware].contains(portal) { portal = .attracted }
        case .retreat:
            guard !dragging else { return }
            awareness = .none
            if portal.carrying { portal = .closed }
        case .receive:
            dragging = false; awareness = .none
            if portal == .open { portal = .receiving }
        case .absorb:
            dragging = false; awareness = .none
            if presentation != .expanded { portal = .absorbing }
        case .rejectDrop:
            dragging = false; awareness = .none
            if presentation != .expanded { portal = .failed }
        case .settlePortal:
            if [.receiving, .absorbing, .failed].contains(portal) { portal = .closed }
        }
    }
}

public struct DisplayGeometry: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var notchWidth: Double, notchHeight: Double
    /// Horizontal centre of the hardware notch in screen coordinates, measured from the menu-bar
    /// areas on either side of it. Nil for a simulated notch, which sits at the screen's midpoint.
    public var notchCenterX: Double?
    public init(x: Double, y: Double, width: Double, height: Double,
                notchWidth: Double = 180, notchHeight: Double = 32, notchCenterX: Double? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.notchWidth = notchWidth; self.notchHeight = notchHeight; self.notchCenterX = notchCenterX
    }
    /// Where every surface is anchored: the notch, not the screen.
    public var anchorX: Double { notchCenterX ?? (x + width / 2) }
    /// The hardware notch's lower corner radius. macOS doesn't report it; this tracks the notch
    /// height so the resting surface sits inside the housing on every model.
    public var notchCorner: Double { min(12, max(6, notchHeight * 0.28)) }
    /// Top-centred on the notch, kept on screen.
    public func origin(panelWidth: Double, panelHeight: Double) -> (x: Double, y: Double) {
        let left = anchorX - panelWidth / 2
        return (min(max(left, x), x + width - panelWidth), y + height - panelHeight)
    }
}
