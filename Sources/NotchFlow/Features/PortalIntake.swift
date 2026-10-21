import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reads a drag over the notch and the drop itself. While the drag is over the notch only file names
/// and kinds are read, to say what's coming; contents are read when the person lets go here.
@MainActor enum PortalIntake {
    /// Everything the notch accepts as a drop destination.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .rtf, .png, .tiff,
         NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// What a drag over the notch carries: its files' names and kinds, or its items' kinds.
    static func cargo(of pasteboard: NSPasteboard) -> PortalCargo? {
        if let urls = fileURLs(pasteboard), !urls.isEmpty {
            return PortalRules.cargo(files: urls.map { ($0.lastPathComponent, kind(of: $0)) })
        }
        return PortalRules.cargo(itemTypes: (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) })
    }

    static func kind(of url: URL) -> PortalContentKind {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        let lineage = values?.contentType.map { Set([$0.identifier] + $0.supertypes.map(\.identifier)) } ?? []
        return PortalRules.kind(ofFileType: lineage, isDirectory: values?.isDirectory ?? false, isPackage: values?.isPackage ?? false)
    }

    enum Delivery { case nothing, now, later }
    typealias Deliver = @MainActor @Sendable ([ShelfIncoming], [String]) -> Void

    /// Reads a drop. Files arrive as references. Promised files (Mail, Photos, a browser's image) and
    /// raw image data are received into the shelf's own folder off the main thread. Links and text are
    /// read as they are. `deliver` runs on the main actor: at once for `.now`, later for `.later`.
    static func read(_ pasteboard: NSPasteboard, deliver: @escaping Deliver) -> Delivery {
        if let urls = fileURLs(pasteboard), !urls.isEmpty {
            deliver(urls.map(ShelfIncoming.reference), []); return .now
        }
        // Read now, while the drag pasteboard is still valid; written to disk later.
        let image = imageData(pasteboard)
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if let image {
            // A picture: its original file when the source promises one, else the pixels it handed over.
            if receivers.isEmpty { keep(image.data, type: image.type, deliver: deliver) }
            else { receive(receivers, fallback: image, deliver: deliver) }
            return .later
        }
        // A link outranks a promise: some browsers also promise a .webloc for a dragged link.
        let links = ((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).compactMap { ShelfPolicy.link(from: $0.absoluteString) }
        if !links.isEmpty { deliver(links.map(ShelfIncoming.link), []); return .now }
        if !receivers.isEmpty { receive(receivers, fallback: nil, deliver: deliver); return .later }
        let rich = pasteboard.data(forType: .rtf)
        guard let text = pasteboard.string(forType: .string) ?? rich.flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }) else {
            return .nothing
        }
        if let link = ShelfPolicy.link(from: text) { deliver([.link(link)], []); return .now }
        deliver([.text(text, rich: rich)], []); return .now
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private static func imageData(_ pasteboard: NSPasteboard) -> (data: Data, type: UTType)? {
        for type in [UTType.png, .jpeg, .heic, .tiff] {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) { return (data, type) }
        }
        return nil
    }

    /// Receives promised files, each into its own private folder. Gives up after a minute; whatever
    /// arrived late is removed by the next launch's sweep.
    private static func receive(_ receivers: [NSFilePromiseReceiver], fallback: (data: Data, type: UTType)?, deliver: @escaping Deliver) {
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let collector = PromiseCollector(expected: expected) { urls, failures in
            Task { @MainActor in
                // A browser that fails to write its promised image still handed over the pixels.
                if urls.isEmpty, let fallback { keep(fallback.data, type: fallback.type, deliver: deliver) }
                else { deliver(urls.map(ShelfIncoming.copy), failures) }
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            guard let folder = try? ShelfService.makeCopyFolder() else {
                for _ in 0..<max(1, receiver.fileNames.count) { collector.record(nil, CocoaError(.fileWriteUnknown)) }
                continue
            }
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                collector.record(error == nil ? url : nil, error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { collector.timeOut() }
    }

    /// Writes dropped image data into the shelf's folder off the main thread. TIFF (what browsers
    /// usually hand over, uncompressed) is kept as PNG.
    private static func keep(_ data: Data, type: UTType, deliver: @escaping Deliver) {
        Task.detached(priority: .userInitiated) {
            let outcome = writeImage(data, type: type)
            await MainActor.run { deliver(outcome.url.map { [.copy($0)] } ?? [], outcome.failure.map { [$0] } ?? []) }
        }
    }

    nonisolated static func writeImage(_ data: Data, type: UTType) -> (url: URL?, failure: String?) {
        guard Int64(data.count) <= ShelfPolicy.maxOwnedItemBytes else {
            return (nil, ShelfPolicy.Refusal.tooLarge("That image").errorDescription)
        }
        var folder: URL?
        do {
            let created = try ShelfService.makeCopyFolder()
            folder = created
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let stem = ShelfPolicy.safeFileName("Image \(formatter.string(from: Date()))", fallback: "Image")
            if type == .tiff {
                let url = created.appendingPathComponent(stem + ".png")
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                return (url, nil)
            }
            let url = created.appendingPathComponent(stem + "." + (type.preferredFilenameExtension ?? "png"))
            try data.write(to: url, options: .atomic)
            return (url, nil)
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            return (nil, "The image couldn't be saved to the shelf.")
        }
    }
}

/// Counts promised files as they arrive and reports once, when all have or when time runs out.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var failures: [String] = []
    private var remaining: Int
    private var finished = false
    private let done: @Sendable ([URL], [String]) -> Void

    init(expected: Int, done: @escaping @Sendable ([URL], [String]) -> Void) {
        remaining = expected; self.done = done
    }

    func record(_ url: URL?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let url { urls.append(url) } else { failures.append(error?.localizedDescription ?? "A file didn't arrive.") }
        remaining -= 1
        let complete = remaining <= 0
        if complete { finished = true }
        let result = (urls, failures)
        lock.unlock()
        if complete { done(result.0, result.1) }
    }

    func timeOut() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = (urls, failures + ["The app didn't finish handing over the file."])
        lock.unlock()
        done(result.0, result.1)
    }
}
