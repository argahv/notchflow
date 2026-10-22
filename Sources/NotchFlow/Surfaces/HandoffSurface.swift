import SwiftUI

/// Agent Rescue: the brief for a failed run, to read and edit before copying it for an agent. Nothing is
/// sent from here; Copy puts it on the clipboard, and pasting it into an agent is the person's step.
struct HandoffSurface: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            BackHeader(title: "Agent handoff", back: { model.back() })
                .frame(height: Metrics.header)
                .reveal(.secondary)
            Text("Review and edit it. Nothing is sent: Copy puts it on the clipboard to paste into Claude Code, Codex or another agent.")
                .font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: Metrics.handoffNote, alignment: .topLeading)
                .reveal(.primary)
            TextEditor(text: $model.handoffDraft)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: Metrics.handoffEditor)
                .nookMaterial(.ambient)
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused ? Ink.accent.opacity(0.55) : .white.opacity(0.05), lineWidth: 1))
                .focused($focused)
                .accessibilityLabel("Handoff brief")
            HStack(spacing: 6) {
                if model.handoffCopied {
                    Label("Copied. Paste it into your agent.", systemImage: "checkmark.circle.fill")
                        .font(TypeScale.secondary).foregroundStyle(Ink.green)
                        .transition(.opacity)
                }
                Spacer()
                if let run = model.handoffRun {
                    Button("Open Run") { NSWorkspace.shared.open(run) }.buttonStyle(PillButtonStyle()).help(run.absoluteString)
                }
                Button { model.copyHandoff() } label: { Label("Copy for Agent", systemImage: "doc.on.doc") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(model.handoffDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Copies the brief as written above. Nothing leaves this Mac.")
            }
            .frame(height: 26)
            .reveal(.detail)
        }
        .padding(Metrics.pad)
        .animation(Motion.quick, value: model.handoffCopied)
        // Typing keeps the workspace open, as in Notes.
        .onChange(of: focused) { _, value in model.send(value ? .beginEditing : .endEditing) }
        .onDisappear { if focused { model.send(.endEditing) } }
    }
}
