import Foundation

// Notch Actions: what a piece of content is, which actions fit it, and the life of one action run.
// Deterministic and local: types, sizes and a light look at text decide; no model and no network.

public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case image, pdf, text, code, link, audio, video, folder, file, collection
}

/// How an action treats the person's data. Shown beside the action, so nothing surprises.
public enum ActionEffect: String, Codable, Sendable {
    /// Reads only; the result is shown, copied or opened.
    case local
    /// Writes a new file to the shelf; the original is never changed.
    case createsFile
    /// Asks the internet for something (a page's title), only when chosen.
    case network
}

public enum ContentAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case copy, quickLook, open, reveal, createNote, annotate
    case extractText, removeBackground, convertPNG, convertJPEG, convertHEIC, resizeHalf, compress
    case pdfText, exportPages, splitPages, mergePDFs
    case cleanWhitespace, uppercase, lowercase, titleCase, wordCount, detectLanguage
    case linkPreview
    case mediaInfo, extractFrame, convertM4A, compressVideo
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .quickLook: "Quick Look"
        case .open: "Open"
        case .reveal: "Show in Finder"
        case .createNote: "New Note"
        case .annotate: "Annotate"
        case .extractText: "Extract Text"
        case .removeBackground: "Remove Background"
        case .convertPNG: "Convert to PNG"
        case .convertJPEG: "Convert to JPEG"
        case .convertHEIC: "Convert to HEIC"
        case .resizeHalf: "Resize to Half"
        case .compress: "Compress"
        case .pdfText: "Extract Text"
        case .exportPages: "Export as Images"
        case .splitPages: "Split Pages"
        case .mergePDFs: "Merge PDFs"
        case .cleanWhitespace: "Clean Up Spacing"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .wordCount: "Count Words"
        case .detectLanguage: "Detect Language"
        case .linkPreview: "Fetch Title"
        case .mediaInfo: "Details"
        case .extractFrame: "Save a Frame"
        case .convertM4A: "Convert to M4A"
        case .compressVideo: "Compress"
        }
    }

    public var effect: ActionEffect {
        switch self {
        case .removeBackground, .convertPNG, .convertJPEG, .convertHEIC, .resizeHalf, .compress,
             .exportPages, .splitPages, .mergePDFs, .extractFrame, .convertM4A, .compressVideo: .createsFile
        case .linkPreview: .network
        default: .local
        }
    }
}

/// What the notch knows about one dropped or shelved item before acting on it.
public struct ContentContext: Equatable, Sendable {
    public var kind: ContentKind
    public var title: String
    public var byteCount: Int?
    /// For a PDF, its page count when known.
    public var pageCount: Int?
    /// For a collection, the kinds of its members.
    public var members: [ContentKind]
    /// Text that looks like a password or key: only copying and counting are offered for it.
    public var sensitive: Bool
    public init(kind: ContentKind, title: String, byteCount: Int? = nil, pageCount: Int? = nil,
                members: [ContentKind] = [], sensitive: Bool = false) {
        self.kind = kind; self.title = title; self.byteCount = byteCount; self.pageCount = pageCount
        self.members = members; self.sensitive = sensitive
    }
}

public enum ContentClassifier {
    /// A file's kind from its type identifier and its supertypes (passed in by the app from `UTType`).
    public static func kind(lineage: Set<String>, isDirectory: Bool, isPackage: Bool) -> ContentKind {
        if isDirectory && !isPackage { return .folder }
        if lineage.contains("com.adobe.pdf") { return .pdf }
        if lineage.contains("public.image") { return .image }
        if lineage.contains("public.movie") || lineage.contains("public.video") { return .video }
        if lineage.contains("public.audio") { return .audio }
        if lineage.contains("public.source-code") || lineage.contains("public.json") || lineage.contains("public.xml")
            || lineage.contains("public.script") || lineage.contains("public.shell-script") { return .code }
        if lineage.contains("public.plain-text") || lineage.contains("public.rtf") || lineage.contains("net.daringfireball.markdown") { return .text }
        return .file
    }

    /// Text: a single web link, code, or prose.
    public static func kind(ofText text: String) -> ContentKind {
        if ShelfPolicy.link(from: text) != nil { return .link }
        return ClipClassifier.kind(of: text) == .code ? .code : .text
    }

    /// Several items at once, named for what they are: "2 PDFs", "3 images", "2 files" for files of
    /// different kinds, "4 items" for anything else together.
    public static func collection(_ members: [ContentKind]) -> ContentContext {
        ContentContext(kind: .collection, title: collectionTitle(members), members: members)
    }

    static func collectionTitle(_ members: [ContentKind]) -> String {
        let count = members.count
        guard count > 1, let first = members.first else { return count == 1 ? "1 item" : "Nothing" }
        if members.allSatisfy({ $0 == first }) {
            switch first {
            case .image: return "\(count) images"
            case .pdf: return "\(count) PDFs"
            case .text: return "\(count) text clippings"
            case .code: return "\(count) code snippets"
            case .link: return "\(count) links"
            case .audio: return "\(count) audio files"
            case .video: return "\(count) videos"
            case .folder: return "\(count) folders"
            case .file: return "\(count) files"
            case .collection: return "\(count) items"
            }
        }
        let fileLike: Set<ContentKind> = [.image, .pdf, .audio, .video, .folder, .file]
        return members.allSatisfy(fileLike.contains) ? "\(count) files" : "\(count) items"
    }
}

public enum ActionRegistry {
    /// Every action that fits, most useful first. The notch offers the first two in its compact result;
    /// the rest sit under More.
    public static func actions(for context: ContentContext) -> [ContentAction] {
        switch context.kind {
        case .image:
            return [.extractText, .removeBackground, .annotate, .copy, .convertPNG, .convertJPEG, .convertHEIC,
                    .resizeHalf, .compress, .quickLook, .reveal]
        case .pdf:
            var actions: [ContentAction] = [.pdfText, .exportPages, .quickLook]
            if (context.pageCount ?? 2) > 1 { actions.append(.splitPages) }
            return actions + [.copy, .reveal]
        case .text:
            // A secret isn't copied anywhere new: no note, no transformed copies.
            return context.sensitive ? [.copy, .wordCount]
                : [.createNote, .copy, .cleanWhitespace, .titleCase, .uppercase, .lowercase, .wordCount]
        case .code:
            return context.sensitive ? [.copy] : [.copy, .detectLanguage, .createNote, .wordCount]
        case .link:
            return [.open, .copy, .linkPreview]
        case .audio:
            return [.mediaInfo, .quickLook, .convertM4A, .copy, .reveal]
        case .video:
            return [.extractFrame, .mediaInfo, .quickLook, .compressVideo, .copy, .reveal]
        case .folder:
            return [.reveal, .open, .copy]
        case .file:
            return [.quickLook, .open, .copy, .reveal]
        case .collection:
            let pdfs = !context.members.isEmpty && context.members.allSatisfy { $0 == .pdf }
            return pdfs && context.members.count > 1 ? [.mergePDFs] : []
        }
    }

    public static func primary(for context: ContentContext) -> [ContentAction] { Array(actions(for: context).prefix(2)) }
}

/// The result an action leaves behind, shown in the same surface.
public enum ActionOutcome: Equatable, Sendable {
    /// Text to read and copy (recognised text, a page title).
    case text(String)
    /// Facts about the content (dimensions, duration, words).
    case details([Detail])
    /// New files on the shelf, by name. Undo removes them.
    case created([String])
    /// Something happened outside the notch (copied, opened, a note made).
    case done(String)

    public struct Detail: Equatable, Sendable {
        public var label: String, value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }
}

/// One action at a time, from available to processing to completed or failed. Progress is reported
/// only when the work can measure it; otherwise it stays indeterminate. A run that was cancelled, or
/// replaced by another, can't overwrite the state when it finishes late.
public struct ActionRun: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case available
        case processing(ContentAction, progress: Double?)
        case completed(ContentAction, ActionOutcome)
        case failed(ContentAction, String)
    }
    public private(set) var phase: Phase = .available
    /// Identifies the current attempt; a finishing task must present the token it started with.
    public private(set) var token = 0
    public init() {}

    public var isProcessing: Bool { if case .processing = phase { return true }; return false }

    /// Starts an action and returns its token, or nil while another is still running.
    public mutating func start(_ action: ContentAction) -> Int? {
        guard !isProcessing else { return nil }
        token += 1
        phase = .processing(action, progress: nil)
        return token
    }
    public mutating func progress(_ value: Double, token: Int) {
        guard token == self.token, case .processing(let action, _) = phase, value.isFinite else { return }
        phase = .processing(action, progress: min(1, max(0, value)))
    }
    public mutating func finish(_ outcome: ActionOutcome, token: Int) {
        guard token == self.token, case .processing(let action, _) = phase else { return }
        phase = .completed(action, outcome)
    }
    public mutating func fail(_ message: String, token: Int) {
        guard token == self.token, case .processing(let action, _) = phase else { return }
        phase = .failed(action, message)
    }
    public mutating func cancel() {
        guard isProcessing else { return }
        token += 1
        phase = .available
    }
    public mutating func reset() { if !isProcessing { phase = .available } }
}

/// Plain-text transformations, all local and exact.
public enum TextTransforms {
    public static func uppercase(_ text: String) -> String { text.uppercased() }
    public static func lowercase(_ text: String) -> String { text.lowercased() }
    /// Capitalises the first letter of each word and leaves the rest as written, so acronyms keep
    /// their capitals ("ship the API" becomes "Ship The API").
    public static func titleCase(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if character.isLetter {
                result.append(atWordStart ? Character(String(character).uppercased()) : character)
                atWordStart = false
            } else {
                result.append(character)
                atWordStart = character.isWhitespace || character == "-" || character == "\"" || character == "("
            }
        }
        return result
    }
    /// Trims each line, collapses runs of spaces and tabs, and keeps at most one blank line between paragraphs.
    public static func cleanWhitespace(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        var output: [String] = []
        for line in lines {
            if line.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(line)
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }
    public static func words(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
    public static func details(_ text: String) -> [ActionOutcome.Detail] {
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return [.init("Words", "\(words(text))"), .init("Characters", "\(text.count)"), .init("Lines", "\(lines)")]
    }
}

/// A best guess at a snippet's programming language, from telltale syntax. Says nothing rather than guess wildly.
public enum CodeLanguage {
    static let signatures: [(name: String, marks: [String])] = [
        ("Swift", ["func ", "let ", "var ", "guard ", "import SwiftUI", "import Foundation", "struct ", "-> "]),
        ("Python", ["def ", "import ", "self.", "elif ", "print(", "None", "__init__", ":\n"]),
        ("TypeScript", ["interface ", ": string", ": number", "export ", "import ", "=> ", "const "]),
        ("JavaScript", ["function ", "const ", "let ", "=> ", "console.log", "require(", "document."]),
        ("Go", ["func ", "package ", ":= ", "fmt.", "go ", "chan "]),
        ("Rust", ["fn ", "let mut ", "impl ", "::", "pub ", "match ", "-> "]),
        ("Java", ["public class ", "public static void", "System.out", "private ", "new ", "import java."]),
        ("Ruby", ["def ", "end\n", "puts ", "require ", "do |", "attr_"]),
        ("Shell", ["#!/bin/", "echo ", "fi\n", "then\n", "$(", "export "]),
        ("SQL", ["SELECT ", "FROM ", "WHERE ", "INSERT INTO", "CREATE TABLE", "JOIN "]),
        ("HTML", ["<div", "<html", "</", "<body", "<span", "class=\""]),
        ("CSS", ["{\n", "color:", "margin:", "padding:", "display:", "px;"]),
    ]

    public static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { return "JSON" }
        let scored = signatures.map { signature in (signature.name, signature.marks.filter { text.contains($0) }.count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 2 else { return nil }
        // A tie between the top two is too close to call.
        if scored.filter({ $0.1 == best.1 }).count > 1 { return nil }
        return best.0
    }
}
