import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// What was dropped on the notch or added here: files by reference (originals are never moved,
/// copied or modified), and the text, links and images a drop carried without a file of its own.
/// Dropping lands an item with a small arrival; dragging one out hands it to the system as what it is.
struct ShelfSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: ShelfService
    @Query(sort: \ShelfFile.addedAt, order: .reverse) private var files: [ShelfFile]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gap), count: Metrics.filesPerRow)

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if files.isEmpty {
                DropZone(active: model.dropTargeted, choose: model.chooseShelfFiles)
                    .frame(height: Metrics.dropZone)
                    .reveal(.primary)
                Text("Files stay where they are. Text, links and images are saved here.")
                    .font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: 16)
                    .reveal(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(files.count == 1 ? "1 item" : "\(files.count) items").font(TypeScale.cardTitle)
                    Text("Originals stay where they are").font(TypeScale.meta).foregroundStyle(Ink.secondary)
                    Spacer()
                    Button { model.clearShelf() } label: { Label("Clear", systemImage: "xmark.bin") }
                        .buttonStyle(PillButtonStyle())
                        .help("Remove everything from the shelf. Originals aren't touched, and Undo brings it back.")
                    Button { model.chooseShelfFiles() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle())
                }
                .frame(height: Metrics.header)
                .reveal(.secondary)
                let rows = min(2, (files.count + Metrics.filesPerRow - 1) / Metrics.filesPerRow)
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: Metrics.gap) {
                        ForEach(files) { item in
                            FileTile(item: item, model: model, service: service, arrived: model.lastArrival == item.id) { model.removeFromShelf(item) }
                        }
                    }
                }
                .frame(height: Double(rows) * Metrics.fileTile + Double(max(0, rows - 1)) * Metrics.gap)
                .reveal(.primary)
                if model.dropTargeted {
                    DropZone(active: true, choose: nil).frame(height: Metrics.dropZone).transition(.opacity)
                }
            }
            if !service.removed.isEmpty {
                Button { model.undoShelfRemoval() } label: {
                    Label(service.removed.count == 1 ? "Undo removal" : "Undo clear (\(service.removed.count) items)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(PillButtonStyle()).frame(height: 26)
            } else if let error = service.error {
                Text(error).font(TypeScale.secondary).foregroundStyle(Ink.amber).lineLimit(1).frame(height: 26)
            }
        }
        .padding(Metrics.pad)
        .animation(Motion.quick, value: model.dropTargeted)
    }
}

/// While a drag hovers, the target brightens and says what will happen.
struct DropZone: View {
    let active: Bool
    let choose: (() -> Void)?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: active ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Ink.silver)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(active ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(active ? "Release to add to the shelf" : "Drop files here").font(TypeScale.cardTitle)
                if let choose {
                    Button("or choose files…", action: choose).font(TypeScale.secondary).foregroundStyle(Ink.silver)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Ink.silver.opacity(active ? 0.14 : 0.06)))
        .overlay(shape.strokeBorder(Ink.silver.opacity(active ? 0.85 : 0.35), style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [4, 3])))
        .animation(Motion.quick, value: active)
    }
}

private struct FileTile: View {
    let item: ShelfFile
    @ObservedObject var model: AppModel
    @ObservedObject var service: ShelfService
    let arrived: Bool
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var landed = false
    @State private var glow = 0.0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Ink.secondary) }
            }
            .frame(width: 40, height: 40)
            Text(item.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.primary)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 26, alignment: .top)
            Text(meta).font(.system(size: 9.5, weight: .medium)).monospacedDigit().foregroundStyle(Ink.secondary)
                .lineLimit(1).truncationMode(.middle).frame(height: 12)
        }
        .frame(maxWidth: .infinity).frame(height: Metrics.fileTile)
        .nookMaterial(.interactive, radius: 12, hovering: hovering)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.green, lineWidth: 1.5).opacity(glow))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 18, tint: Ink.secondary))
                .opacity(hovering ? 1 : 0).padding(3)
                .accessibilityLabel("Remove \(item.name) from shelf")
        }
        // A file that just landed settles in from slightly small and glows mint once.
        .scaleEffect(arrived && !landed ? 0.6 : 1)
        .opacity(arrived && !landed ? 0 : 1)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        // Text has nothing to open; a double-click copies it instead.
        .onTapGesture(count: 2) { if item.kind == .text { model.copyShelfItem(item) } else { service.open(item) } }
        .onDrag { service.itemProvider(for: item) }
        .contextMenu {
            Button("Actions…") { model.openActions([item.id]) }
            Divider()
            if item.isFile { Button("Quick Look") { model.quickLook(item) } }
            if item.kind != .text { Button(item.kind == .link ? "Open Link" : "Open") { service.open(item) } }
            Button("Copy") { model.copyShelfItem(item) }
            if item.isFile { Button("Show in Finder") { service.reveal(item) } }
            Divider()
            Button("Remove from shelf", role: .destructive, action: remove)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(meta)
        .accessibilityAction(named: item.kind == .text ? "Copy" : "Open") {
            if item.kind == .text { model.copyShelfItem(item) } else { service.open(item) }
        }
        .task(id: item.id) {
            thumbnail = await service.thumbnail(for: item, size: CGSize(width: 88, height: 88), scale: displayScale)
        }
        .onAppear {
            guard arrived else { landed = true; return }
            withAnimation(Motion.expressive) { landed = true }
            withAnimation(.easeOut(duration: 0.15)) { glow = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.25)) { glow = 0 }
        }
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .reference, .copy: item.contentType == UTType.folder.identifier ? "folder" : "doc"
        }
    }

    /// Size (or host, or word count) and when it was added: a time today, a date before.
    private var meta: String {
        let detail: String? = switch item.kind {
        case .link: item.linkURL?.host
        case .text: item.text.map { text in
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return words == 1 ? "1 word" : "\(words) words"
        }
        case .reference, .copy:
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                ?? (item.contentType == UTType.folder.identifier ? "Folder" : nil)
        }
        let added = Calendar.current.isDateInToday(item.addedAt)
            ? item.addedAt.formatted(date: .omitted, time: .shortened)
            : item.addedAt.formatted(.dateTime.month(.abbreviated).day())
        return [detail, added].compactMap { $0 }.joined(separator: " · ")
    }

    private var help: String {
        let kind = switch item.kind {
        case .reference: "Reference to your file"
        case .copy: "Saved copy"
        case .text: "Text"
        case .link: item.text ?? "Link"
        }
        let origin = item.origin == "picker" ? "added with Add" : item.origin == "drop" ? "dropped" : "added"
        return "\(item.name)\n\(kind) · \(origin) \(item.addedAt.formatted(.relative(presentation: .named)))"
    }
}
