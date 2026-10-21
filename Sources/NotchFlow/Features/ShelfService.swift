import AppKit
import SwiftData
import QuickLookThumbnailing
import Quartz
import UniformTypeIdentifiers
import Combine

/// What a shelf item is. Stored as `ShelfFile.kindRaw`.
enum ShelfKind: String {
    /// The person's own file or folder, by security-scoped bookmark. Never copied, moved or changed.
    case reference
    /// A file NotchFlow received because the drop had no file of its own; deleted with its item.
    case copy
    case text, link
}

/// One thing a drop or the file picker brings to the shelf, before it's stored.
enum ShelfIncoming: Sendable {
    case reference(URL)
    /// A file already received into the shelf folder.
    case copy(URL)
    case text(String, rich: Data?)
    case link(URL)
}

struct ShelfIntake {
    var added: [UUID] = []
    var duplicates = 0
    var refusals: [ShelfPolicy.Refusal] = []
    var message: String? { refusals.first?.errorDescription }
}

extension ShelfFile {
    var kind: ShelfKind { ShelfKind(rawValue: kindRaw) ?? .reference }
    var isFile: Bool { kind == .reference || kind == .copy }
    var linkURL: URL? { kind == .link ? text.flatMap(ShelfPolicy.link(from:)) : nil }
}

/// Feeds Quick Look. The notch panel hands it to the preview panel from its responder chain.
final class ShelfPreview: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

@MainActor final class ShelfService: ObservableObject {
    var context: ModelContext?
    @Published var error: String?
    /// What the last removal or clear took away, kept for one undo. Copies on disk are deleted once
    /// that undo is no longer possible.
    @Published private(set) var removed: [ShelfFile] = []
    let preview = ShelfPreview()

    /// NotchFlow's own folder for copies: one private subfolder per received file.
    nonisolated static var folder: URL { AppFiles.root.appendingPathComponent("Shelf", isDirectory: true) }

    nonisolated static func makeCopyFolder() throws -> URL {
        let folder = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Newest first. At most `ShelfPolicy.capacity` items, so sorting in memory is cheap.
    var items: [ShelfFile] {
        ((try? context?.fetch(FetchDescriptor<ShelfFile>())) ?? []).sorted { $0.addedAt > $1.addedAt }
    }

    /// Adds the person's own file by reference and returns its id; nil for duplicates or failures.
    @discardableResult func add(_ url: URL) -> UUID? { intake([.reference(url)], origin: "picker").added.first }

    /// Stores what arrived. A duplicate is skipped, not an error; anything refused is reported, and a
    /// copy received for it is deleted.
    @discardableResult func intake(_ incoming: [ShelfIncoming], origin: String) -> ShelfIntake {
        var result = ShelfIntake()
        let existing = items
        var count = existing.count
        var locations = Set(existing.lazy.filter { $0.kind == .reference }.compactMap { self.resolve($0)?.standardizedFileURL.path })
        var keys = Set(existing.compactMap(\.contentKey))
        var copyBytes = existing.lazy.filter { $0.kind == .copy }.reduce(0) { $0 + ($1.byteCount ?? 0) }
        for item in incoming {
            do {
                guard ShelfPolicy.fits(existing: count, adding: 1) else { throw ShelfPolicy.Refusal.full }
                let made: ShelfFile?
                switch item {
                case .reference(let url): made = try reference(url, known: &locations)
                case .copy(let url): made = try copy(url, ownedTotal: copyBytes)
                case .text(let text, let rich): made = try snippet(text, rich: rich, known: keys)
                case .link(let url): made = link(url, known: keys)
                }
                guard let file = made else { result.duplicates += 1; continue }
                file.origin = origin
                context?.insert(file)
                count += 1
                if file.kind == .copy { copyBytes += file.byteCount ?? 0 }
                if let key = file.contentKey { keys.insert(key) }
                result.added.append(file.id)
            } catch {
                result.refusals.append(error as? ShelfPolicy.Refusal ?? .unavailable(Self.name(of: item)))
                if case .copy(let url) = item { Self.deleteCopy(at: url) }
            }
        }
        // Callers decide where a refusal is shown (the portal says it itself); a success clears an old one.
        if !result.added.isEmpty { save(); error = nil }
        return result
    }

    private func reference(_ url: URL, known: inout Set<String>) throws -> ShelfFile? {
        guard url.isFileURL else { throw ShelfPolicy.Refusal.unavailable(url.lastPathComponent) }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ShelfPolicy.Refusal.unavailable(url.lastPathComponent) }
        guard known.insert(url.standardizedFileURL.path).inserted else { return nil }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let file = ShelfFile(name: url.lastPathComponent, bookmark: bookmark)
        describe(file, url)
        return file
    }

    private func copy(_ url: URL, ownedTotal: Int) throws -> ShelfFile {
        let base = Self.folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base), FileManager.default.fileExists(atPath: path) else {
            throw ShelfPolicy.Refusal.unavailable(url.lastPathComponent)
        }
        let file = ShelfFile(name: url.lastPathComponent, bookmark: Data())
        file.kindRaw = ShelfKind.copy.rawValue
        file.copyPath = String(path.dropFirst(base.count))
        describe(file, url)
        if let refusal = ShelfPolicy.admitCopy(bytes: Int64(file.byteCount ?? 0), ownedTotal: Int64(ownedTotal), name: file.name) {
            throw refusal
        }
        return file
    }

    private func snippet(_ text: String, rich: Data?, known: Set<String>) throws -> ShelfFile? {
        if let refusal = ShelfPolicy.admit(text: text) { throw refusal }
        let key = ShelfPolicy.key(forText: text)
        guard !known.contains(key) else { return nil }
        let file = ShelfFile(name: ShelfPolicy.title(forText: text), bookmark: Data())
        file.kindRaw = ShelfKind.text.rawValue
        file.text = text
        // The rich version is a convenience; an oversized one is dropped and the plain text kept.
        file.richText = rich.flatMap { $0.count <= ShelfPolicy.maxTextBytes * 4 ? $0 : nil }
        file.byteCount = text.utf8.count
        file.contentType = (file.richText != nil ? UTType.rtf : UTType.plainText).identifier
        file.contentKey = key
        return file
    }

    private func link(_ url: URL, known: Set<String>) -> ShelfFile? {
        let key = ShelfPolicy.key(forLink: url)
        guard !known.contains(key) else { return nil }
        let file = ShelfFile(name: ShelfPolicy.title(forLink: url), bookmark: Data())
        file.kindRaw = ShelfKind.link.rawValue
        file.text = url.absoluteString
        file.contentType = UTType.url.identifier
        file.contentKey = key
        return file
    }

    private func describe(_ file: ShelfFile, _ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
        // Folders aren't measured: that would walk the whole tree.
        file.byteCount = values?.isDirectory == true ? nil : values?.fileSize
        file.contentType = values?.contentType?.identifier
    }

    private static func name(of item: ShelfIncoming) -> String {
        switch item {
        case .reference(let url), .copy(let url): url.lastPathComponent
        case .text: "That text"
        case .link(let url): url.host ?? "That link"
        }
    }

    // QuickLook previews can be surprisingly large. NSCache evicts under memory pressure and
    // these limits keep long-lived Shelf sessions from accumulating every thumbnail ever visited.
    // Include requested pixel size so a tiny preview never gets stretched into a blurry large one.
    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    /// A QuickLook thumbnail, falling back to the Finder icon. Generated locally and cached in memory only.
    func thumbnail(for item: ShelfFile, size: CGSize, scale: CGFloat) async -> NSImage? {
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        let key = "\(item.id.uuidString):\(pixelsWide)x\(pixelsHigh)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let url = resolve(item) else { return nil }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        let image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
        guard !Task.isCancelled else { return nil }
        // Approximate RGBA cost. NSCache may discard previews sooner when memory is constrained.
        let cost = pixelsWide * pixelsHigh * 4
        thumbnails.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Where a file item is now. Nil for text and links, and for files that are gone.
    func resolve(_ item: ShelfFile) -> URL? {
        switch item.kind {
        case .text, .link:
            return nil
        case .copy:
            guard let path = item.copyPath else { return nil }
            let url = Self.folder.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .reference:
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    item.bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try context?.save()
                }
                return url
            } catch { return nil }
        }
    }

    func open(_ item: ShelfFile) {
        if item.kind == .link {
            // Only web links are ever stored as links, and they open in the browser.
            if let url = item.linkURL { NSWorkspace.shared.open(url) }
            return
        }
        guard item.isFile else { return }
        guard let url = resolve(item) else { error = "File reference is unavailable. Locate the original file and add it again."; return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { error = "The original file is missing or its drive is disconnected."; return }
        NSWorkspace.shared.open(url)
    }
    func reveal(_ item: ShelfFile) {
        guard let url = resolve(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts the item on the clipboard as what it is: a file, a link, or text with its rich version.
    func copyToPasteboard(_ item: ShelfFile) {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .reference, .copy:
            guard let url = resolve(item) else { error = "That file is no longer available."; return }
            pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL])
        case .link:
            guard let url = item.linkURL else { return }
            let entry = NSPasteboardItem()
            entry.setString(url.absoluteString, forType: .URL)
            entry.setString(url.absoluteString, forType: .string)
            pasteboard.clearContents(); pasteboard.writeObjects([entry])
        case .text:
            let entry = NSPasteboardItem()
            if let rich = item.richText { entry.setData(rich, forType: .rtf) }
            entry.setString(item.text ?? "", forType: .string)
            pasteboard.clearContents(); pasteboard.writeObjects([entry])
        }
    }

    /// What dragging an item out carries: the file itself, a link, or text with its rich version, so
    /// each receiving app takes the form it understands.
    func itemProvider(for item: ShelfFile) -> NSItemProvider {
        switch item.kind {
        case .reference, .copy:
            guard let url = resolve(item) else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = item.name
            return provider
        case .link:
            guard let url = item.linkURL else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            provider.registerObject(url.absoluteString as NSString, visibility: .all)
            return provider
        case .text:
            let provider = NSItemProvider(object: (item.text ?? "") as NSString)
            if let rich = item.richText {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
                    completion(rich, nil); return nil
                }
            }
            return provider
        }
    }

    /// Points Quick Look at a file item. False when there's nothing to preview.
    func prepareQuickLook(_ item: ShelfFile) -> Bool {
        guard let url = resolve(item) else { error = "That file is no longer available."; return false }
        preview.urls = [url]
        return true
    }

    func remove(_ item: ShelfFile) { discard([item]) }
    func clear() { discard(items) }
    func undo() {
        guard !removed.isEmpty else { return }
        removed.forEach { context?.insert($0) }
        removed = []
        thumbnails.removeAllObjects(); save()
    }

    private func discard(_ doomed: [ShelfFile]) {
        guard !doomed.isEmpty else { return }
        purgeRemoved()
        // Unmanaged copies for undo; removing an item never touches the person's original file.
        removed = doomed.map(Self.detached)
        doomed.forEach { context?.delete($0) }
        thumbnails.removeAllObjects(); save()
    }

    /// The undo window closed: copies that belonged to the removed items go with them.
    private func purgeRemoved() {
        for item in removed where item.kind == .copy {
            if let path = item.copyPath { Self.deleteCopy(at: Self.folder.appendingPathComponent(path)) }
        }
        removed = []
    }

    private static func detached(_ item: ShelfFile) -> ShelfFile {
        let copy = ShelfFile(name: item.name, bookmark: item.bookmark)
        copy.id = item.id; copy.addedAt = item.addedAt; copy.kindRaw = item.kindRaw
        copy.text = item.text; copy.richText = item.richText; copy.copyPath = item.copyPath
        copy.byteCount = item.byteCount; copy.contentType = item.contentType
        copy.origin = item.origin; copy.contentKey = item.contentKey
        return copy
    }

    /// Deletes one copy, and its folder once empty. Never touches anything outside the shelf folder.
    nonisolated static func deleteCopy(at url: URL) {
        let base = folder.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(base) else { return }
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path.hasPrefix(base),
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Deletes copies no item refers to: an undo window that was still open at quit, or a drop that
    /// was interrupted. Runs at launch and only inside the shelf folder.
    func sweepOrphans() {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        var onDisk: [String] = []
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            if entries.isEmpty { try? manager.removeItem(at: folder); continue }
            onDisk += entries.map { folder.lastPathComponent + "/" + $0 }
        }
        let referenced = Set(items.compactMap(\.copyPath))
        for path in ShelfPolicy.orphans(onDisk: onDisk, referenced: referenced) {
            Self.deleteCopy(at: Self.folder.appendingPathComponent(path))
        }
    }

    private func save() { do { try context?.save() } catch { self.error = error.localizedDescription } }
    func chooseFiles() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = true
        guard picker.runModal() == .OK else { return }
        let result = intake(picker.urls.map(ShelfIncoming.reference), origin: "picker")
        if result.added.isEmpty, let message = result.message { error = message }
    }
}
