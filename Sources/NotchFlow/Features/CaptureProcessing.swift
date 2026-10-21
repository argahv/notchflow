import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

/// On-device text recognition with Vision. The image never leaves the Mac.
enum TextRecognition {
    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "That image couldn't be read." }
    }
    private final class Request: @unchecked Sendable {
        let vision = VNRecognizeTextRequest()
        init() {
            vision.recognitionLevel = .accurate
            vision.usesLanguageCorrection = true
            vision.automaticallyDetectsLanguage = true
        }
    }

    /// The image's text in reading order. Runs off the main thread; cancelling the calling task
    /// cancels Vision's request too.
    static func text(in url: URL) async throws -> String {
        let request = Request()
        let work = Task.detached(priority: .userInitiated) { () throws -> String in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request.vision])
            try Task.checkCancellation()
            let lines = (request.vision.results ?? []).compactMap { observation -> TextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox   // Vision: fractions, origin bottom-left
                return TextLine(text: candidate.string, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            }
            return TextLayout.readingOrder(lines)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            request.vision.cancel(); work.cancel()
        }
    }
}

/// Writes an annotated copy of an image at the original's full resolution. The original is only read.
/// Order matters for privacy: blurs are taken from the original, redactions are filled solid black
/// after them (so no blur can bring a redacted area back), and marks are drawn on top.
enum AnnotationRenderer {
    enum Failure: LocalizedError {
        case unreadable, unwritable
        var errorDescription: String? {
            switch self {
            case .unreadable: "The screenshot couldn't be read."
            case .unwritable: "The annotated copy couldn't be saved."
            }
        }
    }
    /// The colour marks are drawn in: the system's red, readable on light and dark screenshots.
    static let ink = CGColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)

    static func render(_ url: URL, _ items: [Annotation]) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        let width = original.width, height = original.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.unreadable }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(original, in: full)
        // Annotation boxes are fractions with the origin top-left; Core Graphics' origin is bottom-left.
        func rect(_ item: Annotation) -> CGRect {
            let box = item.box
            return CGRect(x: box.x * Double(width), y: (1 - box.y - box.height) * Double(height),
                          width: box.width * Double(width), height: box.height * Double(height)).integral
        }
        func point(_ p: AnnotationPoint) -> CGPoint { CGPoint(x: p.x * Double(width), y: (1 - p.y) * Double(height)) }
        let scale = Double(min(width, height))

        let blurs = items.filter { $0.tool == .blur }
        if !blurs.isEmpty {
            let ciContext = CIContext(options: [.useSoftwareRenderer: false])
            let blurred = CIImage(cgImage: original).clampedToExtent()
                .applyingGaussianBlur(sigma: max(8, scale * 0.012)).cropped(to: full)
            for item in blurs {
                let area = rect(item).intersection(full)
                guard !area.isEmpty, let patch = ciContext.createCGImage(blurred, from: area) else { continue }
                context.draw(patch, in: area)
            }
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for item in items where item.tool == .redact { context.fill(rect(item).intersection(full)) }

        let line = max(3, scale * 0.004)
        for item in items {
            switch item.tool {
            case .highlight:
                context.saveGState()
                context.setBlendMode(.multiply)
                context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 0.45))
                context.fill(rect(item)); context.restoreGState()
            case .rectangle:
                context.setStrokeColor(ink); context.setLineWidth(line)
                context.stroke(rect(item).insetBy(dx: line / 2, dy: line / 2))
            case .arrow:
                let from = point(item.start), to = point(item.end)
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(line * 4, 14)
                context.setStrokeColor(ink); context.setFillColor(ink)
                context.setLineWidth(line); context.setLineCap(.round)
                // The shaft stops at the head's base so the tip stays sharp.
                context.move(to: from)
                context.addLine(to: CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8))
                context.strokePath()
                context.move(to: to)
                context.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * head, y: to.y - sin(angle - .pi / 7) * head))
                context.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * head, y: to.y - sin(angle + .pi / 7) * head))
                context.closePath(); context.fillPath()
            case .text:
                guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, max(14, scale * 0.028), nil)
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                ])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                let origin = point(item.start)
                context.textPosition = CGPoint(x: origin.x, y: origin.y - CTFontGetAscent(font))
                CTLineDraw(ctLine, context)
            case .blur, .redact:
                continue
            }
        }
        guard let image = context.makeImage() else { throw Failure.unreadable }
        return image
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Saves the annotated copy next to the original as "<name> (annotated).png", never over anything.
    static func saveCopy(of url: URL, _ items: [Annotation]) throws -> URL {
        guard let data = png(try render(url, items)) else { throw Failure.unwritable }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent + " (annotated)"
        var destination = folder.appendingPathComponent(stem + ".png")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem) \(counter).png"); counter += 1
        }
        do { try data.write(to: destination, options: .withoutOverwriting) } catch { throw Failure.unwritable }
        return destination
    }
}

/// Puts an image on the clipboard as PNG, with its file when there is one, so a paste lands as a
/// picture in Messages or Slack and as a file in Finder.
enum ImagePasteboard {
    @MainActor static func copy(png data: Data, file: URL?) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// The file's bytes when it's already PNG, otherwise a PNG made from it.
    static func pngData(of url: URL) -> Data? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true { return try? Data(contentsOf: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return AnnotationRenderer.png(image)
    }
}
