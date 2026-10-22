import SwiftUI

/// Actions for what was dropped or picked from the shelf, in the same surface. Every action says what
/// it does with the data: stays on this Mac, adds a new file to the shelf, or uses the internet.
struct ActionsSurface: View {
    @ObservedObject var model: AppModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: Metrics.actionColumns)

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if let context = model.actionContext {
                BackHeader(title: context.title, back: { model.back() })
                    .frame(height: Metrics.header)
                    .reveal(.secondary)
                ActionContextRow(context: context)
                    .frame(height: Metrics.actionContext)
                    .reveal(.primary)
                let actions = ActionRegistry.actions(for: context)
                if actions.isEmpty {
                    CompactEmptyState(symbol: "square.dashed", title: "Nothing to do with these together",
                                      detail: "Open them one at a time from the shelf.")
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                            ActionButton(action: action, busy: model.actionRun.isProcessing) { model.perform(action) }
                                .reveal(.detail, stagger: Double(index) * 0.015)
                        }
                    }
                }
                let chains = model.actionChains
                if !chains.isEmpty {
                    // A few multi-step workflows that fit these items, run as one task.
                    HStack(spacing: 6) {
                        Text("Workflows").font(TypeScale.meta).foregroundStyle(Ink.secondary)
                        ForEach(chains) { chain in
                            Button { model.runChain(chain) } label: { Label(chain.title, systemImage: "arrow.triangle.branch") }
                                .buttonStyle(PillButtonStyle()).help("\(chain.summary). Originals aren't changed.")
                                .disabled(model.actionRun.isProcessing)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Metrics.chainRow)
                    .reveal(.detail)
                }
                ActionResultPanel(model: model)
            } else {
                CompactEmptyState(symbol: "tray", title: "Nothing to act on", detail: "Drop something on the notch, or pick an item on the shelf.")
            }
        }
        .padding(Metrics.pad)
        .animation(Motion.quick, value: model.actionRun)
    }
}

/// What the item is, in a line: its kind, size or pages, and that it's on the shelf.
private struct ActionContextRow: View {
    let context: ContentContext
    var body: some View {
        HStack(spacing: 12) {
            ToneGlyph(symbol: Self.symbol(context.kind), tone: .silver, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.kindName(context)).font(TypeScale.cardTitle).foregroundStyle(Ink.primary)
                Text(Self.detail(context)).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if context.sensitive {
                Label("Looks like a secret", systemImage: "lock.fill").font(TypeScale.meta).foregroundStyle(Ink.amber)
                    .help("Only copying and counting are offered, so it isn't copied anywhere new.")
            }
        }
    }

    static func symbol(_ kind: ContentKind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .audio: "waveform"
        case .video: "film"
        case .folder: "folder"
        case .file: "doc"
        case .collection: "square.stack"
        }
    }
    static func kindName(_ context: ContentContext) -> String {
        switch context.kind {
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .code: "Code"
        case .link: "Link"
        case .audio: "Audio"
        case .video: "Video"
        case .folder: "Folder"
        case .file: "File"
        case .collection: "\(context.members.count) items"
        }
    }
    static func detail(_ context: ContentContext) -> String {
        var parts: [String] = []
        if let pages = context.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let bytes = context.byteCount, context.kind != .text, context.kind != .code {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        // Only claim "on this Mac" when it's true of every action offered.
        let local = ActionRegistry.actions(for: context).allSatisfy { $0.effect != .network }
        parts.append(local ? "On your shelf · actions run on this Mac" : "On your shelf")
        return parts.joined(separator: " · ")
    }
}

private struct ActionButton: View {
    let action: ContentAction
    let busy: Bool
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            HStack(spacing: 7) {
                Image(systemName: action.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.silver).frame(width: 16)
                Text(action.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if let mark = action.effectMark {
                    Image(systemName: mark).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
            }
            .padding(.horizontal, 10).frame(height: Metrics.actionRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(busy)
        .help(action.effectHelp)
        .accessibilityHint(action.effectHelp)
    }
}

/// The current run: progress (measured or not), then its result, or what went wrong.
private struct ActionResultPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.actionRun.phase {
        case .available:
            EmptyView()
        case .processing(let action, let progress):
            HStack(spacing: 10) {
                if let progress { ProgressLine(value: progress).frame(width: 120) } else { ProgressView().controlSize(.small).tint(Ink.silver) }
                Text(model.chainProgress.map { "\($0.chain.title) · \($0.label)…" } ?? "\(action.title)…")
                    .font(TypeScale.secondary).foregroundStyle(Ink.secondary).contentTransition(.opacity)
                Spacer()
                Button("Cancel") { model.cancelAction() }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 12).frame(height: Metrics.actionProcessing).nookMaterial(.ambient)
            .transition(.opacity)
        case .failed(let action, let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(action.title) didn't work").font(TypeScale.cardTitle)
                    Text(message).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer()
                Button("Try Again") { model.perform(action) }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 12).frame(height: Metrics.actionFailed).nookMaterial(.ambient)
            .transition(.opacity)
        case .completed(let action, let outcome):
            CompletedPanel(model: model, action: action, outcome: outcome).transition(.opacity)
        }
    }
}

private struct CompletedPanel: View {
    @ObservedObject var model: AppModel
    let action: ContentAction
    let outcome: ActionOutcome
    var body: some View {
        switch outcome {
        case .text(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            note("text.viewfinder", "No text found", tone: .neutral)
        case .text(let text):
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(text).font(TypeScale.body).foregroundStyle(Ink.primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: Metrics.actionText).nookMaterial(.ambient)
                HStack(spacing: 6) {
                    Spacer()
                    Button("Save to Shelf") { model.keepActionText(asNote: false) }.buttonStyle(PillButtonStyle())
                    Button("New Note") { model.keepActionText(asNote: true) }.buttonStyle(PillButtonStyle())
                    Button { model.copyActionText() } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(PillButtonStyle(prominent: true))
                }
                .frame(height: 26)
            }
        case .details(let details):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(details, id: \.label) { detail in
                    HStack {
                        Text(detail.label).font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(width: 96, alignment: .leading)
                        Text(detail.value).font(TypeScale.secondary.monospacedDigit()).foregroundStyle(Ink.primary).textSelection(.enabled).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Metrics.actionDetail)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).nookMaterial(.ambient)
        case .created(let names):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Added to your shelf").font(TypeScale.cardTitle)
                    Text(names.joined(separator: ", ")).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Undo") { model.undoAction() }.buttonStyle(PillButtonStyle()).help("Remove what this made")
                // The step that usually follows what was just made; Show stays one click away.
                if let next = model.nextSteps.first {
                    Button("Show") { model.navigate(.shelf) }.buttonStyle(PillButtonStyle())
                    Button { model.runNext(next) } label: { Label(next.action.title, systemImage: "arrow.forward") }
                        .buttonStyle(PillButtonStyle(prominent: true)).help(next.reason).accessibilityHint(next.reason)
                } else {
                    Button("Show") { model.navigate(.shelf) }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .padding(.horizontal, 12).frame(height: Metrics.actionCreated).nookMaterial(.ambient)
        case .done(let message):
            note("checkmark.circle.fill", message, tone: .green)
        }
    }

    private func note(_ symbol: String, _ text: String, tone: Tone) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tone.color)
            Text(text).font(TypeScale.secondary).foregroundStyle(Ink.primary)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: Metrics.actionNote).nookMaterial(.ambient)
    }
}

extension ContentAction {
    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .quickLook: "eye"
        case .open: "arrow.up.forward.app"
        case .reveal: "folder"
        case .createNote: "note.text.badge.plus"
        case .annotate: "pencil.tip.crop.circle"
        case .extractText, .pdfText: "text.viewfinder"
        case .removeBackground: "person.crop.rectangle"
        case .convertPNG, .convertJPEG, .convertHEIC: "arrow.triangle.2.circlepath"
        case .resizeHalf: "arrow.down.right.and.arrow.up.left"
        case .compress, .compressVideo: "arrow.down.circle"
        case .exportPages: "photo.on.rectangle"
        case .splitPages: "doc.on.doc.fill"
        case .mergePDFs: "rectangle.stack"
        case .cleanWhitespace: "text.justify.left"
        case .uppercase, .lowercase, .titleCase: "textformat"
        case .wordCount: "number"
        case .detectLanguage: "chevron.left.forwardslash.chevron.right"
        case .linkPreview: "globe"
        case .qrCode: "qrcode"
        case .createArchive: "archivebox"
        case .mediaInfo: "info.circle"
        case .extractFrame: "photo"
        case .convertM4A: "waveform"
        }
    }
    /// A small mark for actions that do more than read: a new file, or the internet.
    var effectMark: String? {
        switch effect {
        case .local: nil
        case .createsFile: "plus.square.on.square"
        case .network: "network"
        }
    }
    var effectHelp: String {
        switch effect {
        case .local: "Runs on this Mac. Nothing new is saved and nothing is uploaded."
        case .createsFile: "Runs on this Mac and adds a new file to the shelf. The original isn't changed."
        case .network: "Fetches the page's title from the internet, only when you choose this."
        }
    }
}
