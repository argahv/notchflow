import SwiftUI
import SwiftData

/// Temporary file references. Dropping a file lands it with a small arrival; dragging one out hands
/// it straight to the system drag. Originals are never moved, copied or modified.
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
                Text("References only. Your original files stay where they are.")
                    .font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: 16)
                    .reveal(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(files.count == 1 ? "1 file" : "\(files.count) files").font(TypeScale.cardTitle)
                    Text("References only").font(TypeScale.meta).foregroundStyle(Ink.secondary)
                    Spacer()
                    Button { model.chooseShelfFiles() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle())
                }
                .frame(height: Metrics.header)
                .reveal(.secondary)
                let rows = min(2, (files.count + Metrics.filesPerRow - 1) / Metrics.filesPerRow)
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: Metrics.gap) {
                        ForEach(files) { item in
                            FileTile(item: item, service: service, arrived: model.lastArrival == item.id) { model.removeFromShelf(item) }
                        }
                    }
                }
                .frame(height: Double(rows) * Metrics.fileTile + Double(max(0, rows - 1)) * Metrics.gap)
                .reveal(.primary)
                if model.dropTargeted {
                    DropZone(active: true, choose: nil).frame(height: Metrics.dropZone).transition(.opacity)
                }
            }
            if service.removed != nil {
                Button { model.undoShelfRemoval() } label: { Label("Undo removal", systemImage: "arrow.uturn.backward") }
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
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Ink.iris)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(active ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(active ? "Release to add to the shelf" : "Drop files here").font(TypeScale.cardTitle)
                if let choose {
                    Button("or choose files…", action: choose).font(TypeScale.secondary).foregroundStyle(Ink.iris)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Ink.iris.opacity(active ? 0.14 : 0.06)))
        .overlay(shape.strokeBorder(Ink.iris.opacity(active ? 0.85 : 0.35), style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [4, 3])))
        .animation(Motion.quick, value: active)
    }
}

private struct FileTile: View {
    let item: ShelfFile
    @ObservedObject var service: ShelfService
    let arrived: Bool
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var landed = false
    @State private var glow = 0.0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(Ink.secondary) }
            }
            .frame(width: 44, height: 44)
            Text(item.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.primary)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity).frame(height: Metrics.fileTile)
        .nookMaterial(.interactive, radius: 12, hovering: hovering)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.mint, lineWidth: 1.5).opacity(glow))
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
        .onTapGesture(count: 2) { service.open(item) }
        .onDrag {
            guard let url = service.resolve(item) else { return NSItemProvider() }
            return NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            Button("Open") { service.open(item) }
            Button("Show in Finder") { service.reveal(item) }
            Divider()
            Button("Remove from shelf", role: .destructive, action: remove)
        }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityAction(named: "Open") { service.open(item) }
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
}
