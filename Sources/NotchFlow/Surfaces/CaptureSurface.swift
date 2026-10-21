import SwiftUI
import ImageIO

/// A screenshot just taken. Its thumbnail rises out of the lower edge into the notch, keeping the
/// screenshot's own shape, then its details and actions settle in beside it.
struct CaptureGlance: View {
    @ObservedObject var model: AppModel
    let capture: Capture
    @State private var arrived = false

    var body: some View {
        let reduced = Motion.reduced
        HStack(spacing: 14) {
            Button { model.quickLookCapture() } label: {
                CaptureThumbnail(image: capture.thumbnail, aspect: capture.aspect)
                    .frame(maxWidth: 132, maxHeight: 84)
            }
            .buttonStyle(PressScale())
            .help("Preview with Quick Look")
            .accessibilityLabel("Preview the screenshot")
            .offset(y: arrived || reduced ? 0 : 74)
            .scaleEffect(arrived || reduced ? 1 : 0.7, anchor: .top)
            .opacity(arrived ? 1 : 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screenshot").font(TypeScale.cardTitle).foregroundStyle(Ink.primary)
                        Text(CaptureWording.meta(capture)).font(TypeScale.secondary).monospacedDigit().foregroundStyle(Ink.secondary)
                        Text(capture.name).font(.system(size: 10.5)).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.middle)
                    }
                    .reveal(.primary, stagger: 0.08)
                    Spacer(minLength: 4)
                    Button { model.dismissCapture() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 22, tint: Ink.secondary)).accessibilityLabel("Dismiss")
                }
                HStack(spacing: 6) {
                    Button("Copy") { model.copyCapture() }
                        .buttonStyle(PillButtonStyle()).help("Copy the image")
                    Button { model.readCaptureText() } label: { Label("Extract Text", systemImage: "text.viewfinder") }
                        .buttonStyle(PillButtonStyle(prominent: true)).help("Read the text on this Mac")
                    Button("Annotate") { model.annotateCapture() }
                        .buttonStyle(PillButtonStyle()).help("Mark up a copy")
                    Menu {
                        Button("Save to Shelf") { model.saveCaptureToShelf() }
                        ShareLink(item: capture.url) { Text("Share…") }
                        Divider()
                        Button("Open") { NSWorkspace.shared.open(capture.url) }
                        Button("Show in Finder") { model.revealCapture() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 26, height: 24).help("More")
                }
                .reveal(.detail, stagger: 0.12)
            }
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .onAppear {
            withAnimation(reduced ? .easeOut(duration: 0.16) : .spring(response: 0.44, dampingFraction: 0.8)) { arrived = true }
        }
    }
}

/// A screenshot's thumbnail in its own aspect ratio, never cropped to a square.
private struct CaptureThumbnail: View {
    let image: NSImage?
    let aspect: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Ink.elevated.overlay(Image(systemName: "photo").foregroundStyle(Ink.secondary))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.silver.opacity(0.18), lineWidth: 0.5))
    }
}

enum CaptureWording {
    /// "1512 × 982 · 9:41 AM": the real pixel size and when it was taken.
    static func meta(_ capture: Capture) -> String {
        let time = capture.taken.formatted(date: .omitted, time: .shortened)
        guard capture.pixelSize.width > 0 else { return time }
        return "\(Int(capture.pixelSize.width)) × \(Int(capture.pixelSize.height)) · \(time)"
    }
}

/// The screenshot's surface after one of its actions: its text, or the annotation editor.
struct CaptureSurface: View {
    @ObservedObject var model: AppModel
    let mode: CaptureMode
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if model.capture == nil {
                CompactEmptyState(symbol: "photo", title: "No screenshot", detail: "Take a screenshot and it appears here.")
            } else {
                switch mode {
                case .text: CaptureTextView(model: model)
                case .annotate: AnnotationEditor(model: model)
                }
            }
        }
        .padding(Metrics.pad)
    }
}

private struct CaptureTextView: View {
    @ObservedObject var model: AppModel
    /// Vision prepares its text model the first time it's used (it can take several seconds); say so
    /// rather than look stuck.
    @State private var slow = false
    var body: some View {
        BackHeader(title: "Text", back: { model.windows?.close() }) {
            if case .done(let text) = model.captureText, !text.isEmpty {
                Button { model.saveCaptureTextToShelf() } label: { Label("Save to Shelf", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(PillButtonStyle())
                Button { model.copyCaptureText() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .frame(height: Metrics.header)
        .reveal(.secondary)
        Group {
            switch model.captureText {
            case .idle:
                CompactEmptyState(symbol: "text.viewfinder", title: "Read the text", detail: "Recognised on this Mac. Nothing is uploaded.",
                                  actionTitle: "Read", action: model.readCaptureText)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .reading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Ink.silver)
                    Text(slow ? "Getting text recognition ready. The first read can take a little while."
                              : "Reading the text on this Mac…")
                        .font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(2)
                    Spacer()
                    Button("Cancel") { model.cancelCaptureText() }.buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, 14).frame(height: 52).nookMaterial(.ambient)
                .frame(maxHeight: .infinity, alignment: .top)
                .task { slow = false; try? await Task.sleep(for: .seconds(3)); slow = true }
            case .failed(let message):
                CompactEmptyState(symbol: "exclamationmark.triangle.fill", tone: .amber, title: "Couldn't read the text",
                                  detail: message, actionTitle: "Try Again", action: model.readCaptureText)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .done(let text) where text.isEmpty:
                CompactEmptyState(symbol: "text.viewfinder", title: "No text found", detail: "There's no text Vision could read in this screenshot.")
                    .frame(maxHeight: .infinity, alignment: .top)
            case .done(let text):
                ScrollView {
                    Text(text).font(TypeScale.body).foregroundStyle(Ink.primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .nookMaterial(.ambient)
            }
        }
        .frame(height: Metrics.captureTextArea)
        .reveal(.primary)
    }
}

/// Marks up a copy of the screenshot. Shapes are kept as fractions of the image, so what's drawn here
/// lands in the same place at full resolution. Blur is a visual effect; Redact removes the pixels.
private struct AnnotationEditor: View {
    @ObservedObject var model: AppModel
    @State private var draft: Annotation?
    @State private var textAt: AnnotationPoint?
    @State private var textDraft = ""
    @State private var display: NSImage?
    @FocusState private var typing: Bool

    var body: some View {
        if let capture = model.capture {
            let canvas = SurfaceLayout.annotationCanvas(model.geometry, ear: 14, aspect: Double(capture.aspect))
            BackHeader(title: "Annotate", back: { model.windows?.close() }) {
                Button { model.changeAnnotations { $0.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle(size: 26)).disabled(!model.annotations.canUndo)
                    .keyboardShortcut("z", modifiers: .command).help("Undo · ⌘Z").accessibilityLabel("Undo")
                Button { model.changeAnnotations { $0.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(IconButtonStyle(size: 26)).disabled(!model.annotations.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo · ⇧⌘Z").accessibilityLabel("Redo")
            }
            .frame(height: Metrics.header)
            HStack(spacing: 4) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    let selected = model.annotationTool == tool
                    Button { model.annotationTool = tool; commitText() } label: { Image(systemName: Self.symbol(tool)) }
                        .buttonStyle(IconButtonStyle(size: 28, tint: selected ? Ink.primary : Ink.secondary))
                        .background(Circle().fill(Ink.elevated).opacity(selected ? 1 : 0))
                        .help(Self.title(tool)).accessibilityLabel(Self.title(tool))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Text(Self.hint(model.annotationTool)).font(TypeScale.meta).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .frame(height: Metrics.annotateToolbar)
            surface(capture, size: canvas).frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if let saved = model.annotatedCopy {
                    Label("Saved “\(saved.lastPathComponent)”", systemImage: "checkmark.circle.fill")
                        .font(TypeScale.meta).foregroundStyle(Ink.green).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(PillButtonStyle())
                } else {
                    Text("The original stays as it is. Saving makes a copy beside it.")
                        .font(TypeScale.meta).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Copy") { commitText(); model.copyAnnotated() }.buttonStyle(PillButtonStyle()).disabled(model.captureBusy)
                Button("Save Copy") { commitText(); model.saveAnnotatedCopy() }.buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(model.annotations.items.isEmpty || model.captureBusy)
            }
            .frame(height: Metrics.annotateToolbar)
            .task(id: capture.id) { display = await Self.loadDisplay(capture.url, longest: max(canvas.width, canvas.height) * 2) }
        }
    }

    private func surface(_ capture: Capture, size: CGSize) -> some View {
        let shown = display ?? capture.thumbnail
        let items = model.annotations.items + (draft.map { [$0] } ?? [])
        let pixelScale = capture.pixelSize.width > 0 ? size.width / capture.pixelSize.width : 1
        return ZStack(alignment: .topLeading) {
            if let shown {
                Image(nsImage: shown).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                // Preview of blurs; the saved copy bakes them in at full resolution.
                Image(nsImage: shown).resizable().frame(width: size.width, height: size.height).blur(radius: 9, opaque: true)
                    .clipShape(Boxes(boxes: items.filter { $0.tool == .blur }.map(\.box)))
            }
            Boxes(boxes: items.filter { $0.tool == .redact }.map(\.box)).fill(Color.black)
            Canvas { context, canvasSize in
                AnnotationMarks.draw(items, in: &context, size: canvasSize,
                                     fontSize: max(11, min(capture.pixelSize.width, capture.pixelSize.height) * 0.028 * pixelScale))
            }
            if let textAt {
                TextField("Text", text: $textDraft)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .bold)).foregroundStyle(Color(cgColor: AnnotationRenderer.ink))
                    .frame(width: 180)
                    .padding(4).background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                    .position(x: textAt.x * size.width + 94, y: textAt.y * size.height + 12)
                    .focused($typing)
                    .onSubmit { commitText() }
                    .onAppear { typing = true }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.silver.opacity(0.15), lineWidth: 0.5))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.annotationTool != .text else { return }
                draft = Annotation(id: draft?.id ?? UUID(), tool: model.annotationTool,
                                   start: Self.point(value.startLocation, size), end: Self.point(value.location, size))
            }
            .onEnded { value in
                if model.annotationTool == .text {
                    commitText(); textAt = Self.point(value.location, size); textDraft = ""
                } else if let finished = draft {
                    model.changeAnnotations { $0.add(finished) }
                }
                draft = nil
            })
        .accessibilityLabel("Screenshot being annotated")
    }

    private func commitText() {
        defer { textAt = nil; textDraft = "" }
        guard let at = textAt, !textDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.changeAnnotations { $0.add(Annotation(tool: .text, start: at, end: at, text: textDraft)) }
    }

    private static func point(_ location: CGPoint, _ size: CGSize) -> AnnotationPoint {
        AnnotationPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height))
    }

    /// A sharper version of the image than the arrival thumbnail, sized for this canvas, off the main thread.
    private static func loadDisplay(_ url: URL, longest: CGFloat) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) { () -> ScreenshotService.Described? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: Int(longest),
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return ScreenshotService.Described(size: .zero, thumbnail: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        }.value
        return image?.thumbnail.map { NSImage(cgImage: $0, size: .zero) }
    }

    static func symbol(_ tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .blur: "drop"
        case .redact: "rectangle.fill"
        }
    }
    static func title(_ tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .highlight: "Highlight"
        case .text: "Text"
        case .blur: "Blur"
        case .redact: "Redact"
        }
    }
    static func hint(_ tool: AnnotationTool) -> String {
        switch tool {
        case .blur: "Blur softens; it isn't safe for secrets"
        case .redact: "Redact replaces the pixels with black"
        case .text: "Click where the text goes"
        default: "Drag on the image"
        }
    }
}

/// The union of annotation boxes (fractions of the frame) as one shape.
private struct Boxes: Shape {
    let boxes: [(x: Double, y: Double, width: Double, height: Double)]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for box in boxes {
            path.addRect(CGRect(x: rect.minX + box.x * rect.width, y: rect.minY + box.y * rect.height,
                                width: box.width * rect.width, height: box.height * rect.height))
        }
        return path
    }
}

/// Arrows, rectangles, highlights and text, drawn the way the saved copy draws them.
enum AnnotationMarks {
    static func draw(_ items: [Annotation], in context: inout GraphicsContext, size: CGSize, fontSize: CGFloat) {
        let ink = Color(cgColor: AnnotationRenderer.ink)
        let line = max(2, min(size.width, size.height) * 0.006)
        func rect(_ item: Annotation) -> CGRect {
            let box = item.box
            return CGRect(x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        func point(_ p: AnnotationPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        for item in items {
            switch item.tool {
            case .highlight:
                context.fill(Path(rect(item)), with: .color(Color(red: 1, green: 0.85, blue: 0.1).opacity(0.45)), style: FillStyle())
            case .rectangle:
                context.stroke(Path(rect(item).insetBy(dx: line / 2, dy: line / 2)), with: .color(ink), lineWidth: line)
            case .arrow:
                let from = point(item.start), to = point(item.end)
                let angle: CGFloat = atan2(to.y - from.y, to.x - from.x)
                let head: CGFloat = max(line * 4, 10)
                func back(_ turn: CGFloat, _ length: CGFloat) -> CGPoint {
                    CGPoint(x: to.x - cos(angle + turn) * length, y: to.y - sin(angle + turn) * length)
                }
                var shaft = Path()
                shaft.move(to: from)
                shaft.addLine(to: back(0, head * 0.8))
                context.stroke(shaft, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
                var tip = Path()
                tip.move(to: to)
                tip.addLine(to: back(-.pi / 7, head))
                tip.addLine(to: back(.pi / 7, head))
                tip.closeSubpath()
                context.fill(tip, with: .color(ink))
            case .text:
                guard let text = item.text, !text.isEmpty else { continue }
                context.draw(Text(text).font(.system(size: fontSize, weight: .bold)).foregroundColor(ink),
                             at: point(item.start), anchor: .topLeading)
            case .blur, .redact:
                continue
            }
        }
    }
}
