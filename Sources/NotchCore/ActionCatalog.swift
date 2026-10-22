import Foundation

// The Action Engine's contract: every action NotchFlow can run declares what it takes, what it makes,
// what it needs from macOS, how far its effects reach, and whether it can be cancelled or undone.
// Execution stays with the runners that already do it well (Notch Actions, suggestion actions);
// this is the one declaration they're all checked against.

public enum ActionValue: String, Sendable, CaseIterable {
    case text, link, file, folder, image, pdf, audio, video, collection
    case color, date, place, contact, note, reminder, clipboard, shelfItem
}

/// A macOS permission an action needs before it can run.
public enum ActionPermission: String, Sendable, CaseIterable {
    case reminders, calendar, filesAndFolders, automation
    public var title: String {
        switch self {
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .filesAndFolders: "Files and Folders"
        case .automation: "Automation"
        }
    }
}

/// How far an action's effects reach, from nothing to irreversible. Ordered.
public enum ActionImpact: Int, Comparable, Sendable {
    /// Shows something; nothing changes.
    case readsOnly
    /// Hands off to another app (Maps, Mail, Finder, the browser).
    case opensElsewhere
    /// Replaces what's on the clipboard.
    case writesClipboard
    /// Writes a new file; originals are never changed.
    case createsFile
    /// Adds a record: a note, a reminder, a shelf item.
    case createsRecord
    /// Asks the internet for something.
    case network
    /// Changes or removes something that already exists. Always confirmed.
    case destructive

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum UndoSupport: String, Sendable {
    case none
    /// Removes what the action created.
    case removesCreated
    /// Puts back what was on the clipboard.
    case restoresClipboard
}

public struct ActionDescriptor: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let inputs: Set<ActionValue>
    public let outputs: Set<ActionValue>
    public let permissions: Set<ActionPermission>
    public let impact: ActionImpact
    public let requiresConfirmation: Bool
    public let cancellable: Bool
    public let undo: UndoSupport

    public init(id: String, title: String, inputs: Set<ActionValue>, outputs: Set<ActionValue> = [], permissions: Set<ActionPermission> = [],
                impact: ActionImpact, requiresConfirmation: Bool = false, cancellable: Bool = false, undo: UndoSupport = .none) {
        self.id = id; self.title = title; self.inputs = inputs; self.outputs = outputs; self.permissions = permissions
        self.impact = impact; self.requiresConfirmation = requiresConfirmation; self.cancellable = cancellable; self.undo = undo
    }
}

public enum ActionCatalog {
    static let anyFile: Set<ActionValue> = [.file, .folder, .image, .pdf, .audio, .video]

    public static func descriptor(for action: ContentAction) -> ActionDescriptor {
        let id = "content.\(action.rawValue)"
        func file(_ inputs: Set<ActionValue>, makes outputs: Set<ActionValue>) -> ActionDescriptor {
            ActionDescriptor(id: id, title: action.title, inputs: inputs, outputs: outputs.union([.shelfItem]), impact: .createsFile,
                             cancellable: true, undo: .removesCreated)
        }
        func reads(_ inputs: Set<ActionValue>, shows outputs: Set<ActionValue> = [], cancellable: Bool = false) -> ActionDescriptor {
            ActionDescriptor(id: id, title: action.title, inputs: inputs, outputs: outputs, impact: .readsOnly, cancellable: cancellable)
        }
        switch action {
        case .copy:
            return ActionDescriptor(id: id, title: action.title, inputs: anyFile.union([.text, .link]), outputs: [.clipboard], impact: .writesClipboard)
        case .quickLook: return reads(anyFile)
        case .open, .reveal:
            return ActionDescriptor(id: id, title: action.title, inputs: anyFile.union([.link]), impact: .opensElsewhere)
        case .createNote:
            return ActionDescriptor(id: id, title: action.title, inputs: [.text], outputs: [.note], impact: .createsRecord)
        case .annotate: return reads([.image], shows: [.image])
        case .extractText: return reads([.image], shows: [.text], cancellable: true)
        case .removeBackground, .convertPNG, .convertJPEG, .convertHEIC, .resizeHalf, .compress: return file([.image], makes: [.image])
        case .pdfText: return reads([.pdf], shows: [.text], cancellable: true)
        case .exportPages: return file([.pdf], makes: [.image])
        case .splitPages: return file([.pdf], makes: [.pdf])
        case .mergePDFs: return file([.collection], makes: [.pdf])
        case .cleanWhitespace, .uppercase, .lowercase, .titleCase: return reads([.text], shows: [.text])
        case .wordCount, .detectLanguage: return reads([.text])
        case .linkPreview:
            return ActionDescriptor(id: id, title: action.title, inputs: [.link], outputs: [.text], impact: .network, cancellable: true)
        case .mediaInfo: return reads([.audio, .video])
        case .extractFrame: return file([.video], makes: [.image])
        case .convertM4A: return file([.audio, .video], makes: [.audio])
        case .compressVideo: return file([.video], makes: [.video])
        }
    }

    public static func descriptor(for action: SuggestedAction) -> ActionDescriptor {
        let title = action.title
        switch action {
        case .openURL:
            return ActionDescriptor(id: "suggest.openURL", title: title, inputs: [.link], impact: .opensElsewhere)
        case .copyText:
            return ActionDescriptor(id: "suggest.copyText", title: title, inputs: [.text, .link, .color], outputs: [.clipboard],
                                    impact: .writesClipboard, undo: .restoresClipboard)
        case .openMaps:
            return ActionDescriptor(id: "suggest.openMaps", title: title, inputs: [.place], impact: .opensElsewhere)
        case .composeEmail:
            return ActionDescriptor(id: "suggest.composeEmail", title: title, inputs: [.contact], impact: .opensElsewhere)
        case .call:
            // macOS asks before placing the call.
            return ActionDescriptor(id: "suggest.call", title: title, inputs: [.contact], impact: .opensElsewhere)
        case .remind:
            return ActionDescriptor(id: "suggest.remind", title: title, inputs: [.date, .text], outputs: [.reminder], permissions: [.reminders],
                                    impact: .createsRecord, undo: .removesCreated)
        case .reveal:
            return ActionDescriptor(id: "suggest.reveal", title: title, inputs: [.file, .folder], impact: .opensElsewhere)
        case .openFile:
            return ActionDescriptor(id: "suggest.openFile", title: title, inputs: [.file, .folder], impact: .opensElsewhere)
        case .keepOnShelf:
            return ActionDescriptor(id: "suggest.keepOnShelf", title: title, inputs: [.text, .link], outputs: [.shelfItem],
                                    impact: .createsRecord, undo: .removesCreated)
        case .newNote:
            return ActionDescriptor(id: "suggest.newNote", title: title, inputs: [.text], outputs: [.note], impact: .createsRecord,
                                    undo: .removesCreated)
        }
    }

    /// One representative of each suggested action, for checks and documentation.
    public static let suggestionSamples: [SuggestedAction] = [
        .openURL(URL(string: "https://example.com")!), .copyText("x", label: "Copy"), .openMaps("1 Infinite Loop"),
        .composeEmail("a@example.com"), .call("+1 555 0100"), .remind(title: "x", due: Date(timeIntervalSince1970: 0)),
        .reveal(path: "/tmp"), .openFile(path: "/tmp"), .keepOnShelf("x"), .newNote("x"),
    ]

    public static var all: [ActionDescriptor] {
        ContentAction.allCases.map(descriptor(for:)) + suggestionSamples.map(descriptor(for:))
    }
}

public enum ActionClearance: Equatable, Sendable {
    case run
    /// Ask macOS for these first; the action runs once they're granted.
    case needsPermission(Set<ActionPermission>)
    /// Show what will happen and get a yes first.
    case needsConfirmation
}

/// The single check before any action runs.
public enum ActionGuard {
    public static func clearance(for descriptor: ActionDescriptor, granted: Set<ActionPermission>, confirmed: Bool) -> ActionClearance {
        let missing = descriptor.permissions.subtracting(granted)
        if !missing.isEmpty { return .needsPermission(missing) }
        // Anything that changes or removes what already exists is confirmed, whatever its descriptor says.
        if (descriptor.requiresConfirmation || descriptor.impact == .destructive) && !confirmed { return .needsConfirmation }
        return .run
    }
}
