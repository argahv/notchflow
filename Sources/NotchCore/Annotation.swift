import Foundation

/// The annotation tools. Blur is a visual effect and can sometimes be reversed; Redact replaces the
/// pixels with solid black in the saved copy, so it's the one to use for anything secret.
public enum AnnotationTool: String, CaseIterable, Codable, Sendable {
    case arrow, rectangle, highlight, text, blur, redact
    /// Covers what's underneath in the saved copy instead of drawing on top of it.
    public var obscures: Bool { self == .blur || self == .redact }
}

/// A point as a fraction of the image, origin top-left, so annotations survive any display size.
public struct AnnotationPoint: Equatable, Codable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = min(1, max(0, x)); self.y = min(1, max(0, y)) }
}

public struct Annotation: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var tool: AnnotationTool
    public var start: AnnotationPoint
    public var end: AnnotationPoint
    public var text: String?
    public init(id: UUID = UUID(), tool: AnnotationTool, start: AnnotationPoint, end: AnnotationPoint, text: String? = nil) {
        self.id = id; self.tool = tool; self.start = start; self.end = end; self.text = text
    }
    /// The box the two points span, as fractions of the image: (x, y, width, height).
    public var box: (x: Double, y: Double, width: Double, height: Double) {
        (min(start.x, end.x), min(start.y, end.y), abs(end.x - start.x), abs(end.y - start.y))
    }
    /// Too small to mean anything (a click rather than a drag), except text, which is placed by a click.
    public var isNegligible: Bool {
        tool != .text && max(abs(end.x - start.x), abs(end.y - start.y)) < 0.004
    }
}

/// What has been drawn on one image, with undo and redo. Each change is one step; the original image
/// is never part of the document, so it can't be altered from here.
public struct AnnotationDocument: Equatable, Sendable {
    public private(set) var items: [Annotation] = []
    private var history: [[Annotation]] = []
    private var future: [[Annotation]] = []
    public static let historyLimit = 100
    public init() {}

    public var canUndo: Bool { !history.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    /// Areas whose pixels the saved copy replaces (redactions), as opposed to blurs drawn over them.
    public var redactions: [Annotation] { items.filter { $0.tool == .redact } }

    /// Adds a finished annotation. A negligible one (a stray click) is ignored.
    public mutating func add(_ annotation: Annotation) {
        guard !annotation.isNegligible else { return }
        record(); items.append(annotation)
    }
    public mutating func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        record(); items.removeAll { $0.id == id }
    }
    public mutating func setText(_ text: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].text != text else { return }
        record(); items[index].text = text
    }
    public mutating func clear() {
        guard !items.isEmpty else { return }
        record(); items = []
    }
    public mutating func undo() {
        guard let previous = history.popLast() else { return }
        future.append(items); items = previous
    }
    public mutating func redo() {
        guard let next = future.popLast() else { return }
        history.append(items); items = next
    }

    private mutating func record() {
        history.append(items)
        if history.count > Self.historyLimit { history.removeFirst() }
        future.removeAll()
    }
}
