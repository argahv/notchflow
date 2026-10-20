import SwiftUI
import SwiftData

/// Notes list ↔ editor. The card's background is the shared element: opening a note grows the
/// card into the editor, closing folds the editor back into the card.
struct NotesBody: View {
    @ObservedObject var model: AppModel
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var search = ""

    var body: some View {
        ZStack(alignment: .top) {
            if let id = model.openNoteID, let note = notes.first(where: { $0.id == id }) {
                NoteEditor(note: note, model: model).transition(.opacity)
            } else if notes.isEmpty {
                CompactEmptyState(symbol: "note.text", title: "No notes yet", detail: "Notes save on this Mac as you type.",
                                  actionTitle: "New note") { model.newNote() }
                    .frame(height: Metrics.emptyRow)
            } else {
                list.transition(.opacity)
            }
        }
    }

    private var list: some View {
        let filtered = search.isEmpty ? notes : notes.filter { $0.text.localizedCaseInsensitiveContains(search) }
        let visible = min(notes.count, Metrics.maxNoteRows)
        return VStack(spacing: Metrics.gap) {
            if notes.count >= 4 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Ink.secondary)
                    TextField("Search notes", text: $search).textFieldStyle(.plain).font(TypeScale.body)
                }
                .padding(.horizontal, 10).frame(height: Metrics.searchField)
                .nookMaterial(.interactive, radius: Radius.control)
            }
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(filtered) { note in
                        NoteCard(note: note) { model.openNote(note.id) }
                            .contextMenu { Button("Delete", role: .destructive) { model.deleteNote(note) } }
                    }
                    if filtered.isEmpty {
                        Text("No notes match").font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: Metrics.noteRow)
                    }
                }
            }
            .frame(height: Double(visible) * Metrics.noteRow + Double(max(0, visible - 1)) * 6)
        }
    }
}

struct NoteCard: View {
    let note: Note
    let open: () -> Void
    @Environment(\.nookNamespace) private var namespace
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: note.text)).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(Self.excerpt(for: note.text)).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(note.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(TypeScale.meta).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 12).frame(height: Metrics.noteRow)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Ink.elevated : Ink.surface.opacity(0.92))
                    .nookMatched("note-\(note.id)", in: namespace)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .accessibilityLabel(Self.title(for: note.text))
    }
    static func title(for text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled note" : line
    }
    static func excerpt(for text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.count > 1 ? String(lines[1]) : "No additional text"
    }
}

/// Plain-text editor. It grows two lines at a time to a ceiling, then scrolls inside; resizing waits
/// for a typing pause so the surface never resizes per keystroke or disturbs selection, undo or IME.
struct NoteEditor: View {
    @Bindable var note: Note
    @ObservedObject var model: AppModel
    @Environment(\.nookNamespace) private var namespace
    @FocusState private var focused: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var saved = true
    @State private var height: Double = 136

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $note.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Ink.surface.opacity(0.95))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(focused ? Ink.iris.opacity(0.45) : .white.opacity(0.05), lineWidth: 1))
                        .nookMatched("note-\(note.id)", in: namespace)
                }
                .focused($focused)
            Text(saved ? "Saved on this Mac" : "Saving…")
                .font(TypeScale.meta).foregroundStyle(Ink.secondary)
                .contentTransition(.opacity)
                .frame(height: 16)
        }
        .onAppear {
            height = SurfaceLayout.editorHeight(note.text)
            // Focus moves in once the editor has grown out of its card.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { model.windows?.focus(); focused = true }
        }
        .onChange(of: focused) { _, value in model.send(value ? .beginEditing : .endEditing) }
        .onChange(of: note.text) { _, _ in
            note.updatedAt = Date(); saved = false; saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                model.save(); saved = true
                let next = SurfaceLayout.editorHeight(note.text)
                if next != height {
                    withAnimation(Motion.quick) { height = next }
                    model.reflow()
                }
            }
        }
        .onDisappear {
            saveTask?.cancel(); model.save()
            if focused { model.send(.endEditing) }
        }
    }
}
