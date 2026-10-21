import AppKit
import ImageIO

/// A screenshot the notch is showing. The file stays where macOS saved it; the thumbnail lives in
/// memory only.
struct Capture: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let taken: Date
    /// Pixel dimensions, zero when the file couldn't be measured.
    let pixelSize: CGSize
    let thumbnail: NSImage?
    var name: String { url.lastPathComponent }
    var aspect: CGFloat { pixelSize.width > 0 && pixelSize.height > 0 ? pixelSize.width / pixelSize.height : 16 / 10 }
    static func == (a: Capture, b: Capture) -> Bool { a.id == b.id }
}

/// Opt-in. Watches the folder macOS saves screenshots to (the `location` screencapture preference, or
/// the Desktop) and reports each new screenshot once. It uses no Screen Recording permission and no key
/// monitoring, and it never moves, renames or deletes what macOS saved. Reading the Desktop asks for
/// access the first time it's turned on.
@MainActor final class ScreenshotService: ObservableObject {
    enum Status: Equatable {
        case off
        case watching(URL)
        /// Screenshots go to the clipboard, Preview, Mail or Messages, not to a file.
        case notFiles(String)
        /// The folder can't be read (no access granted, or it doesn't exist).
        case unavailable(URL)
    }
    @Published private(set) var status: Status = .off
    var onCapture: ((Capture) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var since = Date()
    private var seen = RecentSet()
    private var scanWork: DispatchWorkItem?

    /// Whether macOS shows its floating thumbnail first, which holds the file back about five seconds.
    static var showsFloatingThumbnail: Bool {
        (CFPreferencesCopyAppValue("show-thumbnail" as CFString, "com.apple.screencapture" as CFString) as? Bool) ?? true
    }

    func configure(enabled: Bool) {
        stop()
        guard enabled else { status = .off; return }
        let domain = "com.apple.screencapture" as CFString
        let target = CFPreferencesCopyAppValue("target" as CFString, domain) as? String
        guard ScreenshotRules.savesToFile(target: target) else { status = .notFiles(target ?? ""); return }
        let folder = Self.folderOverride ?? ScreenshotRules.folder(
            location: CFPreferencesCopyAppValue("location" as CFString, domain) as? String,
            home: FileManager.default.homeDirectoryForCurrentUser)
        // Listing the folder is what asks for access to the Desktop (or wherever screenshots go).
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else { status = .unavailable(folder); return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { status = .unavailable(folder); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleScan() } }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
        since = Date()
        status = .watching(folder)
    }

    func stop() {
        scanWork?.cancel(); scanWork = nil
        source?.cancel(); source = nil
    }

    #if DEBUG
    /// Scripted QA watches a scratch folder instead of the real one.
    private static var folderOverride: URL? {
        ProcessInfo.processInfo.environment["NOTCHFLOW_SCREENSHOT_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #else
    private static var folderOverride: URL? { nil }
    #endif

    /// Folder events come in bursts (a hidden temporary file, then a rename); one scan follows the burst.
    private func scheduleScan(after delay: TimeInterval = 0.25, attempt: Int = 0) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(attempt: attempt) }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan(attempt: Int) {
        guard case .watching(let folder) = status else { return }
        let now = Date()
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        var waiting = false
        for url in entries {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard ScreenshotRules.isCandidate(name: url.lastPathComponent, created: created, watchingSince: since, now: now),
                  let created else { continue }
            let key = url.path + "|" + String(created.timeIntervalSinceReferenceDate)
            guard !seen.contains(key) else { continue }
            // The marker can land a moment after the file; anything still without it after a few
            // tries isn't a screenshot (a downloaded or copied image).
            guard ScreenshotRules.isScreenCapture(attribute: Self.captureMarker(url)) else { waiting = true; continue }
            _ = seen.insert(key)
            deliver(url, taken: created)
        }
        if waiting, attempt < 6 { scheduleScan(after: 0.3, attempt: attempt + 1) }
    }

    /// Measures and thumbnails a screenshot off the main thread, then reports it.
    func deliver(_ url: URL, taken: Date) {
        Task { [weak self] in
            let described = await Task.detached(priority: .userInitiated) { Self.describe(url) }.value
            guard let self, let described else { return }
            self.onCapture?(Capture(url: url, taken: taken, pixelSize: described.size,
                                    thumbnail: described.thumbnail.map { NSImage(cgImage: $0, size: .zero) }))
        }
    }

    nonisolated static func captureMarker(_ url: URL) -> Data? {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 1024 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }

    struct Described: @unchecked Sendable { let size: CGSize; let thumbnail: CGImage? }
    /// Pixel size and a small thumbnail, decoded with ImageIO without loading the full image.
    nonisolated static func describe(_ url: URL) -> Described? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 480,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return Described(size: CGSize(width: width, height: height),
                         thumbnail: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }
}
