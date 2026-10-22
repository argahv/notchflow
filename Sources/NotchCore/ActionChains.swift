import Foundation

// Action Chains and the Next Action. One engine: every step of a chain is an existing Notch Action, cleared
// by `ActionGuard` and run by the same executor as a single action. Chains add only what sequencing needs:
// which step can take what the step before made, overall progress, and cleanup of what's made in between.
// The Next Action looks at what an action just made and offers the step that usually follows.

/// Whether an action runs once per item or once over all of them.
public enum ActionScope: Sendable { case each, all }

public enum ActionChains {
    /// Kinds that are files on disk, so they can go into an archive.
    public static let fileKinds: Set<ContentKind> = [.image, .pdf, .audio, .video, .folder, .file]

    public static func scope(of action: ContentAction) -> ActionScope {
        switch action {
        case .mergePDFs, .createArchive: .all
        default: .each
        }
    }

    /// What one step makes from an input of this kind, or nil when it can't take it. Actions that show a
    /// result (text, details) instead of making a file don't chain.
    public static func output(of action: ContentAction, from input: ContentKind) -> ContentKind? {
        switch action {
        case .convertPNG, .convertJPEG, .convertHEIC, .resizeHalf, .compress, .removeBackground: input == .image ? .image : nil
        case .exportPages: input == .pdf ? .image : nil
        case .splitPages, .mergePDFs: input == .pdf ? .pdf : nil
        case .extractFrame: input == .video ? .image : nil
        case .convertM4A: [.audio, .video].contains(input) ? .audio : nil
        case .compressVideo: input == .video ? .video : nil
        case .qrCode: input == .link ? .image : nil
        case .createArchive: fileKinds.contains(input) ? .file : nil
        default: nil
        }
    }
}

/// A short sequence of Notch Actions run as one task.
public struct ActionChain: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let steps: [ContentAction]
    public let accepts: Set<ContentKind>
    public let minimumItems: Int

    public init(id: String, title: String, summary: String, steps: [ContentAction], accepts: Set<ContentKind>, minimumItems: Int = 1) {
        self.id = id; self.title = title; self.summary = summary; self.steps = steps; self.accepts = accepts; self.minimumItems = minimumItems
    }

    /// What the chain makes from this kind, if every step can take what the one before made.
    public func output(from input: ContentKind) -> ContentKind? {
        steps.reduce(Optional(input)) { kind, step in kind.flatMap { ActionChains.output(of: step, from: $0) } }
    }

    /// Whether it can run on these items: enough of them, all accepted, and the steps fit together.
    public func applies(to members: [ContentKind]) -> Bool {
        members.count >= minimumItems && !members.isEmpty
            && members.allSatisfy { accepts.contains($0) && output(from: $0) != nil }
    }

    public static let presets: [ActionChain] = [
        ActionChain(id: "web-ready-images", title: "Web-Ready Images", summary: "Half the size, then compressed as JPEG",
                    steps: [.resizeHalf, .compress], accepts: [.image]),
        ActionChain(id: "compress-and-zip", title: "Compress into a ZIP", summary: "Each image compressed, then all in one archive",
                    steps: [.compress, .createArchive], accepts: [.image], minimumItems: 2),
        ActionChain(id: "document-bundle", title: "Document Bundle", summary: "Merged into one PDF, then archived",
                    steps: [.mergePDFs, .createArchive], accepts: [.pdf], minimumItems: 2),
        ActionChain(id: "pages-as-images", title: "Pages as Images", summary: "Every page as an image, all in one archive",
                    steps: [.exportPages, .createArchive], accepts: [.pdf]),
    ]

    public static func applicable(to members: [ContentKind]) -> [ActionChain] { presets.filter { $0.applies(to: members) } }
}

/// Where a chain run is. Progress is reported per step as the step reports it; a step that can't measure
/// its own progress counts as half done until it finishes, rather than inventing a number.
public struct ChainProgress: Equatable, Sendable {
    public let chain: ActionChain
    public private(set) var step = 0
    public private(set) var stepFraction: Double?
    public init(chain: ActionChain) { self.chain = chain }

    public var current: ContentAction { chain.steps[min(step, chain.steps.count - 1)] }
    public var overall: Double { min(1, (Double(step) + (stepFraction ?? 0.5)) / Double(max(1, chain.steps.count))) }
    /// "Step 2 of 3 · Compress"
    public var label: String { "Step \(min(step, chain.steps.count - 1) + 1) of \(chain.steps.count) · \(current.title)" }

    public mutating func begin(step index: Int) { step = index; stepFraction = nil }
    public mutating func report(_ fraction: Double) { if fraction.isFinite { stepFraction = min(1, max(0, fraction)) } }
}

/// Which files a chain run owns. Originals are never among them. What a step made becomes the next step's
/// input; what's made in between is removed when the run ends, however it ends; only the last step's files
/// are kept.
public struct ChainArtifacts<File: Hashable & Sendable>: Sendable {
    public private(set) var current: [File]
    public private(set) var intermediate: [File] = []
    public let originals: Set<File>

    public init(inputs: [File]) { current = inputs; originals = Set(inputs) }

    /// A step finished: what it made is what the next step takes; what it took, if the run made it, is spent.
    public mutating func stepFinished(made: [File]) {
        intermediate += current.filter { !originals.contains($0) }
        current = made
    }

    /// The run finished: keep the last step's files and remove everything made in between.
    public func finished() -> (keep: [File], remove: [File]) { (current.filter { !originals.contains($0) }, intermediate) }

    /// The run was cancelled or failed: everything it made goes, originals stay.
    public mutating func abandon() -> [File] {
        let made = intermediate + current.filter { !originals.contains($0) }
        intermediate = []; current = []
        return made
    }
}

/// One step worth offering after another, and why.
public struct NextStep: Equatable, Sendable {
    public let action: ContentAction
    public let reason: String
    public init(_ action: ContentAction, _ reason: String) { self.action = action; self.reason = reason }
}

public enum NextActionRules {
    /// After an action made `count` files of `kind`, what usually comes next with them: a primary step and at
    /// most one more. Never the action that just ran.
    public static func after(_ action: ContentAction, made kind: ContentKind, count: Int) -> [NextStep] {
        var steps: [NextStep] = []
        if count > 1, ActionChains.fileKinds.contains(kind), action != .createArchive {
            steps.append(NextStep(.createArchive, "Put the \(count) new files in one archive"))
        }
        switch (action, kind) {
        case (.resizeHalf, .image), (.convertPNG, .image), (.convertJPEG, .image), (.convertHEIC, .image), (.extractFrame, .image):
            steps.append(NextStep(.compress, "Make the new image smaller"))
        case (.removeBackground, .image):
            // Compressing would flatten the transparency that was just made; copy it instead.
            steps.append(NextStep(.copy, "Copy it, transparency and all"))
        case (.compress, .image), (.qrCode, .image):
            steps.append(NextStep(.copy, "Copy it, ready to paste"))
        case (.mergePDFs, .pdf):
            steps.append(NextStep(.pdfText, "Read the merged document's text"))
        case (.createArchive, .file):
            steps.append(NextStep(.copy, "Copy the archive to paste into a message"))
        default:
            break
        }
        var seen: Set<ContentAction> = [action]
        return Array(steps.filter { seen.insert($0.action).inserted }.prefix(2))
    }
}
