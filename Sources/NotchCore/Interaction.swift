import Foundation

public enum Presentation: String, Codable, Sendable { case collapsed, preview, expanded }
/// Something is approaching the notch without having entered it yet.
public enum Awareness: String, Codable, Sendable { case none, pointer, drag }
public enum InteractionEvent: Sendable {
    case enter, leave, expand, dismiss, togglePin, beginDrag, endDrag, beginEditing, endEditing, attention
    case approach, dragApproach, retreat
}

/// Presentation, dismissal, and input are independent axes. An incoming event never
/// replaces the workspace while the user is editing or dragging.
public struct InteractionState: Equatable, Sendable {
    public private(set) var presentation: Presentation = .collapsed
    public private(set) var pinned = false
    public private(set) var dragging = false
    public private(set) var editing = false
    public private(set) var awareness: Awareness = .none
    public init() {}

    public mutating func send(_ event: InteractionEvent) {
        switch event {
        case .enter:
            if presentation == .collapsed { presentation = .preview }
        case .leave:
            if !pinned && !dragging && !editing { presentation = .collapsed }
        case .expand: presentation = .expanded
        case .dismiss:
            pinned = false; dragging = false; editing = false; awareness = .none; presentation = .collapsed
        case .togglePin:
            pinned.toggle()
            if pinned { presentation = .expanded }
        case .beginDrag: dragging = true; presentation = .expanded
        case .endDrag: dragging = false; if awareness == .drag { awareness = .none }
        case .beginEditing: editing = true; presentation = .expanded
        case .endEditing: editing = false
        case .attention:
            if presentation == .collapsed { presentation = .preview }
        case .approach:
            // A file drag outranks the pointer: it keeps the drop target ready.
            if awareness == .none { awareness = .pointer }
        case .dragApproach: awareness = .drag
        case .retreat: if !dragging { awareness = .none }
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
