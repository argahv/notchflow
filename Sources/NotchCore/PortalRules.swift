import Foundation
import CryptoKit

// Pure rules behind the notch portal and the shelf, kept here so they're tested without a drag
// session, a pasteboard or a file system.

/// What a drag carries, as far as the portal says before the drop.
public enum PortalContentKind: String, Codable, Sendable, CaseIterable {
    case file, folder, image, pdf, audio, video, link, text, mixed
}

/// The kind and number of things heading for the notch.
public struct PortalCargo: Equatable, Sendable {
    public var kind: PortalContentKind
    public var count: Int
    /// A single file's name, known only once the drag is over the notch and its files can be read.
    public var name: String?
    public init(kind: PortalContentKind, count: Int, name: String? = nil) {
        self.kind = kind; self.count = max(1, count); self.name = name
    }

    /// "Report.pdf", "3 images", "Link", "4 items".
    public var title: String {
        if count == 1 {
            if let name, ![.link, .text, .mixed].contains(kind) { return name }
            switch kind {
            case .file: return "File"
            case .folder: return "Folder"
            case .image: return "Image"
            case .pdf: return "PDF"
            case .audio: return "Audio file"
            case .video: return "Video"
            case .link: return "Link"
            case .text: return "Text"
            case .mixed: return "1 item"
            }
        }
        switch kind {
        case .file: return "\(count) files"
        case .folder: return "\(count) folders"
        case .image: return "\(count) images"
        case .pdf: return "\(count) PDFs"
        case .audio: return "\(count) audio files"
        case .video: return "\(count) videos"
        case .link: return "\(count) links"
        case .text: return "\(count) text clippings"
        case .mixed: return "\(count) items"
        }
    }
}

/// Which drags the portal reacts to and what they carry, from pasteboard type identifiers only. The
/// notch never reads a drag's contents until the person drops it there.
public enum PortalRules {
    static let fileURL = "public.file-url"
    static let url = "public.url"
    static let texts = ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.plain-text"]
    static let richText = ["public.rtf", "com.apple.flat-rtfd"]
    static let images = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
    static let promises = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
                           "com.apple.pasteboard.promised-file-content-type"]

    /// Whether a drag carrying these types can be dropped on the notch.
    public static func isEligible(types: [String]) -> Bool {
        types.contains { kind(ofType: $0) != nil }
    }

    /// One dragged item's kind, from its types. A real file outranks everything else it also offers
    /// (a Finder file carries its name as text). Image data outranks the promise and the link a browser
    /// adds to a picture; a promise on its own (Mail, Photos) is a file; then links, then text.
    public static func kind(ofItemTypes types: [String]) -> PortalContentKind? {
        if types.contains(fileURL) { return .file }
        if types.contains(where: images.contains) { return .image }
        if types.contains(where: isPromise) { return .file }
        if types.contains(url) { return .link }
        if types.contains(where: { texts.contains($0) || richText.contains($0) }) { return .text }
        return nil
    }

    static func isPromise(_ type: String) -> Bool {
        promises.contains(type) || type.hasPrefix("com.apple.pasteboard.promised-file")
    }

    /// What a drag carries, from each item's types. Nil when nothing in it can be kept.
    public static func cargo(itemTypes: [[String]]) -> PortalCargo? {
        let kinds = itemTypes.compactMap(kind(ofItemTypes:))
        guard !kinds.isEmpty else { return nil }
        return PortalCargo(kind: combine(kinds), count: kinds.count)
    }

    /// A file's kind from its uniform type identifier and its ancestors (the app layer passes the
    /// real conformance list from `UTType`). Packages (apps, bundles) count as files.
    public static func kind(ofFileType lineage: Set<String>, isDirectory: Bool, isPackage: Bool) -> PortalContentKind {
        if isDirectory && !isPackage { return .folder }
        if lineage.contains("com.adobe.pdf") { return .pdf }
        if lineage.contains("public.image") { return .image }
        if lineage.contains("public.movie") || lineage.contains("public.video") { return .video }
        if lineage.contains("public.audio") { return .audio }
        return .file
    }

    /// The cargo once the drag is over the notch and its files' names and kinds are known.
    public static func cargo(files: [(name: String, kind: PortalContentKind)]) -> PortalCargo? {
        guard !files.isEmpty else { return nil }
        return PortalCargo(kind: combine(files.map(\.kind)), count: files.count, name: files.count == 1 ? files[0].name : nil)
    }

    static func kind(ofType type: String) -> PortalContentKind? {
        if type == fileURL || isPromise(type) { return .file }
        if images.contains(type) { return .image }
        if type == url { return .link }
        if texts.contains(type) || richText.contains(type) { return .text }
        return nil
    }

    static func combine(_ kinds: [PortalContentKind]) -> PortalContentKind {
        guard let first = kinds.first else { return .mixed }
        if kinds.allSatisfy({ $0 == first }) { return first }
        // Files of different types are still files; anything else together is a mix.
        let fileLike: Set<PortalContentKind> = [.file, .folder, .image, .pdf, .audio, .video]
        return kinds.allSatisfy(fileLike.contains) ? .file : .mixed
    }
}

/// What the shelf keeps and how. References point at the person's own files and never copy, move or
/// change them. Owned items are copies NotchFlow had to make because the drop had no file of its own
/// (a promised file from Mail or Photos, image data from a browser); they live under NotchFlow's
/// Application Support folder and are deleted with their shelf item. Text and links are stored in the
/// workspace database.
public enum ShelfPolicy {
    public static let capacity = 100
    public static let maxTextBytes = 256 * 1024
    public static let maxOwnedItemBytes: Int64 = 512 * 1024 * 1024
    public static let maxOwnedTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    public enum Refusal: Equatable, Sendable, LocalizedError {
        case full, empty, textTooLong, tooLarge(String), ownedSpaceFull, unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .full: "The shelf holds up to \(ShelfPolicy.capacity) items. Remove some to add more."
            case .empty: "There was nothing in that drop to keep."
            case .textTooLong: "That text is longer than the shelf keeps (256 KB)."
            case .tooLarge(let name): "\(name) is larger than the shelf copies (512 MB)."
            case .ownedSpaceFull: "The shelf's copies already use 2 GB. Remove some to add more."
            case .unavailable(let name): "\(name) isn't available."
            }
        }
    }

    /// Only a single web address is kept as a link; anything else is text.
    public static func link(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func admit(text: String) -> Refusal? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return text.utf8.count > maxTextBytes ? .textTooLong : nil
    }

    /// Whether `adding` more items fit beside `existing` ones.
    public static func fits(existing: Int, adding: Int) -> Bool { existing + adding <= capacity }

    /// Whether a copy of `bytes` may be kept beside `ownedTotal` bytes of existing copies.
    public static func admitCopy(bytes: Int64, ownedTotal: Int64, name: String) -> Refusal? {
        if bytes > maxOwnedItemBytes { return .tooLarge(name) }
        return ownedTotal + bytes > maxOwnedTotalBytes ? .ownedSpaceFull : nil
    }

    /// Identity used to refuse a second copy of the same text or link. Files compare by location.
    public static func key(forText text: String) -> String {
        "text:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func key(forLink url: URL) -> String {
        var string = url.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        return "link:" + string
    }

    /// A one-line label: the first non-empty line, spaces collapsed, shortened. Text that looks like a key
    /// or password is never its own label, so it can't show up in the shelf, Time Travel or a result.
    public static func title(forText text: String) -> String {
        if ClipClassifier.looksSecret(text) { return "Text that looks like a key" }
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }.first { !$0.isEmpty } ?? ""
        return shorten(line.isEmpty ? "Text" : line, to: 60)
    }
    /// "example.com/docs/page" — no scheme, no "www.", shortened.
    public static func title(forLink url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path == "/" ? "" : url.path
        return shorten(host + path, to: 60)
    }

    /// A name that is safe to create inside NotchFlow's own folder: one path component, no leading
    /// dot, no separators or control characters, a sensible length. Falls back when nothing is left.
    public static func safeFileName(_ proposed: String, fallback: String) -> String {
        var name = proposed.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let base = String((name as NSString).deletingPathExtension.prefix(110))
            name = ext.isEmpty || ext.count > 9 ? String(name.prefix(120)) : base + "." + ext
        }
        return name.isEmpty ? fallback : name
    }

    /// Copies on disk that no shelf item refers to any more (after a removal that wasn't undone, or a
    /// crash mid-drop). Paths are relative to the shelf's folder.
    public static func orphans(onDisk: [String], referenced: Set<String>) -> [String] {
        onDisk.filter { !referenced.contains($0) }.sorted()
    }

    static func shorten(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
