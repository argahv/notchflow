import AppKit
import SwiftData
import QuickLookThumbnailing
import Combine

@MainActor final class ShelfService: ObservableObject {
    var context: ModelContext?
    @Published var error: String?
    @Published var removed: ShelfFile?
    /// Adds a reference and returns its id; nil for duplicates or failures. The original is never touched.
    @discardableResult func add(_ url: URL) -> UUID? {
        guard url.isFileURL else { error = "Only local file references are supported."; return nil }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw EventError.invalid("File is unavailable") }
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let existing = try context?.fetch(FetchDescriptor<ShelfFile>()) ?? []
            guard existing.count < 100 else { throw EventError.invalid("The shelf holds up to 100 references. Remove some to add more.") }
            guard !existing.contains(where: { resolve($0)?.standardizedFileURL == url.standardizedFileURL }) else { return nil }
            let item = ShelfFile(name: url.lastPathComponent, bookmark: data)
            context?.insert(item); try context?.save()
            error = nil
            return item.id
        } catch { self.error = error.localizedDescription; return nil }
    }

    private var thumbnails: [UUID: NSImage] = [:]
    /// A QuickLook thumbnail, falling back to the Finder icon. Generated locally and cached in memory only.
    func thumbnail(for item: ShelfFile, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let url = resolve(item) else { return nil }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        let image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
        thumbnails[item.id] = image
        return image
    }
    func resolve(_ item: ShelfFile) -> URL? {
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
    func open(_ item: ShelfFile) {
        guard let url = resolve(item) else { error = "File reference is unavailable. Locate the original file and add it again."; return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { error = "The original file is missing or its drive is disconnected."; return }
        NSWorkspace.shared.open(url)
    }
    func reveal(_ item: ShelfFile) {
        guard let url = resolve(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func remove(_ item: ShelfFile) {
        // Keep an unmanaged copy for undo; removing a reference never deletes its original.
        removed = ShelfFile(name: item.name, bookmark: item.bookmark)
        context?.delete(item); save()
    }
    func undo() { guard let removed else { return }; context?.insert(removed); self.removed = nil; save() }
    private func save() { do { try context?.save() } catch { self.error = error.localizedDescription } }
    func chooseFiles() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = true
        if picker.runModal() == .OK { for url in picker.urls { add(url) } }
    }
}
