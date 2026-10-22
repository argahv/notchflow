import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import LinkPresentation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// What the notch knows about a shelf item before acting on it: its kind from its type, its size, a
/// PDF's page count, and whether its text looks like a secret.
@MainActor enum ContentInspector {
    static func context(for item: ShelfFile, shelf: ShelfService) -> ContentContext {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            return ContentContext(kind: ContentClassifier.kind(ofText: text), title: item.name, byteCount: item.byteCount,
                                  sensitive: ClipClassifier.looksSecret(text))
        case .link:
            return ContentContext(kind: .link, title: item.name)
        case .reference, .copy:
            guard let url = shelf.resolve(item) else { return ContentContext(kind: .file, title: item.name) }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
            let lineage = values?.contentType.map { Set([$0.identifier] + $0.supertypes.map(\.identifier)) } ?? []
            var kind = ContentClassifier.kind(lineage: lineage, isDirectory: values?.isDirectory ?? false, isPackage: values?.isPackage ?? false)
            // Text actions work on what the shelf would hold; a larger text file is just a file.
            if [.text, .code].contains(kind), (item.byteCount ?? Int.max) > ShelfPolicy.maxTextBytes { kind = .file }
            let sensitive = [.text, .code].contains(kind) && ClipClassifier.looksSecret(text(of: url) ?? "")
            let pages = kind == .pdf ? PDFDocument(url: url)?.pageCount : nil
            return ContentContext(kind: kind, title: item.name, byteCount: item.byteCount, pageCount: pages, sensitive: sensitive)
        }
    }

    /// A small text file's contents, in whatever encoding it declares.
    static func text(of url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ShelfPolicy.maxTextBytes else { return nil }
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }
}

/// The work behind each action. Everything runs on this Mac and off the main thread; new files are
/// written into the shelf's own folder (the caller adds them to the shelf), never beside or over an original.
enum ActionExecutor {
    struct Output: Sendable {
        var outcome: ActionOutcome
        /// New files to add to the shelf as copies.
        var files: [URL] = []
    }
    typealias Progress = @Sendable (Double) -> Void

    enum Failure: LocalizedError {
        case unreadable, unwritable, noSubject, noText, notMedia, unsupported, alreadySmall
        var errorDescription: String? {
            switch self {
            case .alreadySmall: "It's already about as small as this makes it, so nothing new was saved."
            case .unreadable: "That file couldn't be read."
            case .unwritable: "The result couldn't be saved to the shelf."
            case .noSubject: "There's no clear subject to keep in this image."
            case .noText: "There's no text in this file."
            case .notMedia: "That file doesn't have the audio or video this needs."
            case .unsupported: "That can't be done with this file."
            }
        }
    }

    // MARK: Images

    static func image(_ action: ContentAction, url: URL) async throws -> Output {
        if action == .extractText {
            return Output(outcome: .text(try await TextRecognition.text(in: url)))
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
            let stem = url.deletingPathExtension().lastPathComponent
            let original = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            switch action {
            case .convertPNG:
                return try created(write(image, as: .png, named: stem))
            case .convertJPEG:
                return try created(write(flattened(image), as: .jpeg, quality: 0.9, named: stem))
            case .convertHEIC:
                return try created(write(image, as: .heic, quality: 0.8, named: stem))
            case .resizeHalf:
                let longest = max(image.width, image.height) / 2
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                guard let half = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
                let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? .png
                let writable = [UTType.png, .jpeg, .heic, .tiff].contains(type) ? type : .png
                return try created(write(half, as: writable, quality: 0.9, named: "\(stem) (50%)"))
            case .compress:
                let file = try write(flattened(image), as: .jpeg, quality: 0.6, named: "\(stem) (compressed)")
                let after = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return Output(outcome: .created(["\(file.lastPathComponent) · \(size(original)) → \(size(after))"]), files: [file])
            case .removeBackground:
                return try created(write(try withoutBackground(image), as: .png, named: "\(stem) (no background)"))
            default:
                throw Failure.unsupported
            }
        }.value
    }

    /// Keeps the foreground subjects Vision finds and makes everything else transparent.
    private static func withoutBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(masked, from: masked.extent) else { throw Failure.unwritable }
        return output
    }

    /// JPEG has no transparency: composite onto white rather than let clear pixels turn black.
    private static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private static func write(_ image: CGImage, as type: UTType, quality: Double? = nil, named name: String) throws -> URL {
        let folder = try ShelfService.makeCopyFolder()
        let url = folder.appendingPathComponent(ShelfPolicy.safeFileName(name, fallback: "Image") + "." + (type.preferredFilenameExtension ?? "png"))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: folder); throw Failure.unwritable
        }
        let properties: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: folder); throw Failure.unwritable }
        return url
    }

    private static func created(_ file: URL) -> Output { Output(outcome: .created([file.lastPathComponent]), files: [file]) }
    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    // MARK: Links and archives

    /// A QR code for a link, made on this Mac with Core Image: black on white, large enough to scan from a screen.
    static func qrCode(_ link: URL) throws -> Output {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(code, from: code.extent) else { throw Failure.unwritable }
        return try created(write(image, as: .png, named: "QR " + (link.host ?? "link")))
    }

    /// One ZIP of the given files and folders, made by the system's own archiver (NSFileCoordinator). The
    /// originals are only read: files are cloned into a temporary folder, which is removed afterwards.
    static func archive(_ urls: [URL], progress: @escaping Progress) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            guard let first = urls.first else { throw Failure.unreadable }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("NotchFlow-zip-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let root: URL
            if urls.count == 1 && isFolder {
                root = first
            } else {
                let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
                root = staging.appendingPathComponent(ShelfPolicy.safeFileName(name, fallback: "Archive"), isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var used: Set<String> = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    var name = url.lastPathComponent, copy = 2
                    while used.contains(name) {
                        name = url.deletingPathExtension().lastPathComponent + " \(copy)" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
                        copy += 1
                    }
                    used.insert(name)
                    try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(name))
                    progress(Double(index + 1) / Double(urls.count + 1))
                }
            }
            var zipped: URL?, failure: Error?, coordination: NSError?
            NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordination) { zip in
                do {
                    let output = try ShelfService.makeCopyFolder().appendingPathComponent(root.lastPathComponent + ".zip")
                    try FileManager.default.copyItem(at: zip, to: output)
                    zipped = output
                } catch { failure = error }
            }
            if let error = coordination ?? failure { throw error }
            guard let zipped else { throw Failure.unwritable }
            progress(1)
            return created(zipped)
        }.value
    }

    // MARK: PDFs

    /// At most this many pages are exported or split in one go, so one drop can't fill the disk.
    static let pageLimit = 60

    static func pdf(_ action: ContentAction, url: URL, progress: @escaping Progress) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
            let stem = url.deletingPathExtension().lastPathComponent
            switch action {
            case .pdfText:
                return Output(outcome: .text(document.string ?? ""))
            case .exportPages, .splitPages:
                let count = min(document.pageCount, pageLimit)
                guard count > 0 else { throw Failure.unreadable }
                let folder = try ShelfService.makeCopyFolder().appendingPathComponent(ShelfPolicy.safeFileName("\(stem) pages", fallback: "Pages"))
                // Cancelled or failed part-way: nothing half-written is left behind.
                var finished = false
                defer { if !finished { ShelfService.deleteCopy(at: folder) } }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for index in 0..<count {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { continue }
                    let name = "\(stem) – page \(index + 1)"
                    if action == .exportPages {
                        let bounds = page.bounds(for: .mediaBox)
                        let picture = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL,
                                                                                UTType.png.identifier as CFString, 1, nil) else { throw Failure.unwritable }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
                    } else {
                        let single = PDFDocument()
                        guard let copy = page.copy() as? PDFPage else { continue }
                        single.insert(copy, at: 0)
                        guard single.write(to: folder.appendingPathComponent(name + ".pdf")) else { throw Failure.unwritable }
                    }
                    progress(Double(index + 1) / Double(count))
                }
                let note = document.pageCount > count ? " (first \(count) of \(document.pageCount) pages)" : ""
                finished = true
                return Output(outcome: .created([folder.lastPathComponent + note]), files: [folder])
            default:
                throw Failure.unsupported
            }
        }.value
    }

    static func merge(_ urls: [URL], progress: @escaping Progress) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            let merged = PDFDocument()
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
                for page in 0..<document.pageCount {
                    if let copy = document.page(at: page)?.copy() as? PDFPage { merged.insert(copy, at: merged.pageCount) }
                }
                progress(Double(index + 1) / Double(urls.count))
            }
            let stem = urls.first?.deletingPathExtension().lastPathComponent ?? "Merged"
            let file = try ShelfService.makeCopyFolder()
                .appendingPathComponent(ShelfPolicy.safeFileName("\(stem) + \(urls.count - 1) more", fallback: "Merged") + ".pdf")
            guard merged.write(to: file) else { throw Failure.unwritable }
            return Output(outcome: .created(["\(file.lastPathComponent) · \(merged.pageCount) pages"]), files: [file])
        }.value
    }

    // MARK: Audio and video

    static func media(_ action: ContentAction, url: URL, progress: @escaping Progress) async throws -> Output {
        let asset = AVURLAsset(url: url)
        let stem = url.deletingPathExtension().lastPathComponent
        switch action {
        case .mediaInfo:
            let duration = try await asset.load(.duration).seconds
            var details = [ActionOutcome.Detail("Duration", duration.isFinite ? Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)) : "Unknown")]
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let shown = size.applying(transform)
                details.append(.init("Dimensions", "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"))
                if rate > 0 { details.append(.init("Frame rate", String(format: "%.0f fps", rate))) }
            }
            details.append(.init("Audio", try await asset.loadTracks(withMediaType: .audio).isEmpty ? "None" : "Yes"))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { details.append(.init("Size", size(bytes))) }
            return Output(outcome: .details(details))
        case .extractFrame:
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.notMedia }
            let duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let at = CMTimeMinimum(CMTime(seconds: 1, preferredTimescale: 600), CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2))
            let frame = try await generator.image(at: at).image
            return try created(write(frame, as: .png, named: "\(stem) frame"))
        case .convertM4A:
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.notMedia }
            return try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, named: stem, progress: progress, from: url)
        case .compressVideo:
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.notMedia }
            // Larger than 720p: scale down to it. Already that small: keep the size and lower the bitrate.
            let shown = try await video.load(.naturalSize)
            let preset = max(abs(shown.width), abs(shown.height)) > 1280 ? AVAssetExportPreset1280x720 : AVAssetExportPresetMediumQuality
            let output = try await export(asset, preset: preset, type: .mp4, named: "\(stem) (compressed)", progress: progress, from: url)
            // Never hand back a "compressed" file that isn't smaller.
            if let file = output.files.first,
               let before = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               let after = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, after >= before {
                ShelfService.deleteCopy(at: file)
                throw Failure.alreadySmall
            }
            return output
        default:
            throw Failure.unsupported
        }
    }

    /// An export with real progress (polled from the session while it runs) and real cancellation.
    private static func export(_ asset: AVURLAsset, preset: String, type: AVFileType, named name: String,
                               progress: @escaping Progress, from source: URL) async throws -> Output {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.unsupported }
        let folder = try ShelfService.makeCopyFolder()
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "mov"
        let file = folder.appendingPathComponent(ShelfPolicy.safeFileName(name, fallback: "Export") + "." + ext)
        session.outputURL = file
        session.outputFileType = type
        let box = SessionBox(session)
        let watcher = Task.detached {
            while !Task.isCancelled, box.session.status == .waiting || box.session.status == .exporting {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { done.resume() }
            }
        } onCancel: { box.session.cancelExport() }
        guard box.session.status == .completed else {
            try? FileManager.default.removeItem(at: folder)
            if box.session.status == .cancelled { throw CancellationError() }
            throw box.session.error ?? Failure.unwritable
        }
        let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Output(outcome: .created(["\(file.lastPathComponent) · \(size(before)) → \(size(after))"]), files: [file])
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    // MARK: Links and text

    /// The page's title, fetched only because the person asked; ten seconds at most.
    @MainActor static func linkTitle(_ url: URL) async throws -> Output {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata = try await withTaskCancellationHandler {
            try await provider.startFetchingMetadata(for: url)
        } onCancel: { provider.cancel() }
        return Output(outcome: .details([.init("Title", metadata.title ?? "No title"), .init("Site", url.host ?? url.absoluteString)]))
    }

    static func text(_ action: ContentAction, _ text: String) throws -> Output {
        switch action {
        case .uppercase: return Output(outcome: .text(TextTransforms.uppercase(text)))
        case .lowercase: return Output(outcome: .text(TextTransforms.lowercase(text)))
        case .titleCase: return Output(outcome: .text(TextTransforms.titleCase(text)))
        case .cleanWhitespace: return Output(outcome: .text(TextTransforms.cleanWhitespace(text)))
        case .wordCount: return Output(outcome: .details(TextTransforms.details(text)))
        case .detectLanguage:
            return Output(outcome: .details([.init("Language", CodeLanguage.detect(text) ?? "Not sure"),
                                             .init("Lines", "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)")]))
        default: throw Failure.unsupported
        }
    }
}
