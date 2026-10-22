import SwiftUI

/// A suggested next step, grown out of the notch like any other glance: what was noticed, one or two
/// actions, "Why?", and dismiss. After an action it becomes that action's result, with Undo when the
/// action can be undone, then retracts on its own.
struct SuggestionGlance: View {
    @ObservedObject var model: AppModel
    let suggestion: Suggestion

    var body: some View {
        let result = model.suggestionResult
        let detail: String? = result == nil ? suggestion.detail : result?.detail
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: 12) {
                leading(result)
                    .reveal(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result?.title ?? suggestion.title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if let detail {
                        Text(detail).font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .reveal(.primary, stagger: 0.03)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                // Actions keep their size; the text truncates instead.
                Group { if let result { resultControls(result) } else { actionControls } }
                    .fixedSize()
            }
            .frame(height: 44)
            if model.suggestionWhy, result == nil {
                Text(suggestion.reason)
                    .font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 42)
                    .transition(.opacity.combined(with: .offset(y: -4)))
                    .accessibilityLabel("Why: \(suggestion.reason)")
            }
        }
        .padding(.vertical, 11)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion")
    }

    @ViewBuilder private func leading(_ result: AppModel.SuggestionResult?) -> some View {
        if let result {
            ToneGlyph(symbol: result.failed ? "exclamationmark.triangle" : "checkmark", tone: result.failed ? .amber : .green, size: 30)
        } else if let swatch = suggestion.swatch {
            Circle()
                .fill(Color(.sRGB, red: Double(swatch.red) / 255, green: Double(swatch.green) / 255, blue: Double(swatch.blue) / 255,
                            opacity: swatch.alpha))
                .overlay(Circle().strokeBorder(Ink.silver.opacity(0.35), lineWidth: 1))
                .frame(width: 30, height: 30)
                .accessibilityLabel("Color \(swatch.hex)")
        } else {
            ToneGlyph(symbol: suggestion.symbol, tone: .silver, size: 30)
        }
    }

    private var actionControls: some View {
        HStack(spacing: 6) {
            ForEach(Array(suggestion.actions.prefix(2)), id: \.self) { action in
                Button(action.title) { model.runSuggestion(action) }
                    .buttonStyle(PillButtonStyle(prominent: action == suggestion.actions.first))
                    .help(SuggestionWording.help(action))
                    .accessibilityHint(SuggestionWording.help(action))
            }
            if suggestion.actions.count > 2 {
                Menu {
                    ForEach(Array(suggestion.actions.dropFirst(2)), id: \.self) { action in
                        Button(action.title) { model.runSuggestion(action) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 24, height: 24).help("More").accessibilityLabel("More actions")
            }
            Button { model.toggleSuggestionWhy() } label: { Image(systemName: model.suggestionWhy ? "info.circle.fill" : "info.circle") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary))
                .help("Why this suggestion?").accessibilityLabel("Why this suggestion?")
            Button { model.dismissSuggestion() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary))
                .help("Not now. Suggestions like this come back less often.").accessibilityLabel("Dismiss suggestion")
        }
        .reveal(.detail)
    }

    private func resultControls(_ result: AppModel.SuggestionResult) -> some View {
        HStack(spacing: 6) {
            if result.canUndo {
                Button("Undo") { model.undoSuggestion() }.buttonStyle(PillButtonStyle()).help("Put it back as it was")
            }
            Button { model.dismissSuggestion() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).accessibilityLabel("Close")
        }
        .reveal(.detail)
    }
}

/// What each action will do, said before it's chosen.
enum SuggestionWording {
    static func help(_ action: SuggestedAction) -> String {
        switch action {
        case .openURL: "Opens the link in your browser"
        case .copyText(let text, _): "Copies \(SuggestionText.preview(text)). Undo puts back what you copied."
        case .openMaps: "Opens the address in Maps"
        case .composeEmail: "Starts an email in your mail app"
        case .call: "Calls the number. macOS asks before dialling."
        case .remind: "Adds a reminder on this Mac. NotchFlow asks for Reminders access the first time. Undo removes it."
        case .reveal: "Shows it in Finder"
        case .openFile: "Opens it with its usual app. Apps and scripts are only shown in Finder."
        case .keepOnShelf: "Keeps it on the shelf, where Actions can do more with it. Undo removes it."
        case .newNote: "Saves it as a note in Tools › Notes. Undo removes it."
        case .extractArchive: "Expands it next to the archive with Archive Utility. The archive stays where it is."
        case .openActions(_, let then): (then.map { "\($0.title), on this Mac. " } ?? "") + "Keeps it on the shelf by reference; the original isn't changed."
        }
    }
}
