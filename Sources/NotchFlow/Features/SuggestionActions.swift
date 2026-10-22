import AppKit
import SwiftData

/// Runs a suggested action after `ActionGuard` has cleared it. Every action either hands off to another
/// app, or does one local thing and says how to undo it. Nothing here touches the network, runs a
/// script, or changes a file that already exists.
@MainActor struct SuggestionActionRunner {
    enum Result {
        /// Another app took it from here (Maps, Mail, Finder, the browser).
        case handedOff
        /// Done here; `undo` reverses it while the result is showing.
        case done(String, detail: String?, undo: (() -> Void)?)
        case failed(String)
    }

    let clipboard: ClipboardService
    let shelf: ShelfService
    let calendar: CalendarService
    let notes: () -> ModelContext?
    let save: () -> Void

    func run(_ action: SuggestedAction) -> Result {
        switch action {
        case .openURL(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .failed("Only web links open from here.") }
            return open(url)
        case .copyText(let text, _):
            let previous = NSPasteboard.general.string(forType: .string)
            clipboard.write(text)
            return .done("Copied", detail: SuggestionText.preview(text), undo: previous.map { previous in { clipboard.write(previous) } })
        case .openMaps(let query):
            var components = URLComponents()
            components.scheme = "maps"; components.host = ""
            components.queryItems = [URLQueryItem(name: "address", value: query)]
            guard let url = components.url else { return .failed("That address couldn't be opened in Maps.") }
            return open(url)
        case .composeEmail(let address):
            var components = URLComponents()
            components.scheme = "mailto"; components.path = address
            guard let url = components.url else { return .failed("That address couldn't be opened.") }
            return open(url)
        case .call(let number):
            let dialable = number.filter { $0.isNumber || $0 == "+" }
            guard dialable.count >= 3, let url = URL(string: "tel:" + dialable) else { return .failed("That number can't be dialled.") }
            return open(url)
        case .remind(let title, let due):
            do {
                let identifier = try calendar.addReminder(title: title, due: due)
                return .done("Reminder added", detail: DateFormatter.localizedString(from: due, dateStyle: .medium, timeStyle: .short),
                             undo: { calendar.removeReminder(identifier) })
            } catch { return .failed(error.localizedDescription) }
        case .reveal(let path):
            guard FileManager.default.fileExists(atPath: path) else { return .failed("It's no longer there.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return .handedOff
        case .openFile(let path):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return .failed("It's no longer there.") }
            // Opening an app, installer or script from a copied path would run it. Show it instead.
            if Self.runsCode(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .done("Shown in Finder", detail: "NotchFlow doesn't open apps or scripts from a copied path.", undo: nil)
            }
            return open(url)
        case .keepOnShelf(let text):
            let incoming: ShelfIncoming = ShelfPolicy.link(from: text).map { .link($0) } ?? .text(text, rich: nil)
            let result = shelf.intake([incoming], origin: "suggestion")
            if result.added.isEmpty {
                return result.duplicates > 0 ? .done("Already on the shelf", detail: nil, undo: nil)
                    : .failed(result.message ?? "It couldn't be kept on the shelf.")
            }
            return .done("Kept on the shelf", detail: "Shelf › Actions has more for it", undo: { shelf.discardCreated(result.added) })
        case .newNote(let text):
            guard let store = notes() else { return .failed("Notes aren't available right now.") }
            let note = Note(text: text)
            store.insert(note); save()
            return .done("Saved as a note", detail: "Tools › Notes", undo: { store.delete(note); save() })
        }
    }

    private func open(_ url: URL) -> Result {
        NSWorkspace.shared.open(url) ? .handedOff : .failed("macOS has no app to open that.")
    }

    static func runsCode(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey, .isPackageKey, .isExecutableKey])
        if values?.isApplication == true { return true }
        if ["command", "tool", "sh", "zsh", "bash", "pkg", "mpkg", "app", "workflow", "scpt", "applescript", "terminal"]
            .contains(url.pathExtension.lowercased()) { return true }
        return values?.isDirectory != true && values?.isExecutable == true
    }
}

enum SuggestionText {
    /// One line of a value, short enough for the glance.
    static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 56 ? String(line.prefix(55)) + "…" : line
    }
}
