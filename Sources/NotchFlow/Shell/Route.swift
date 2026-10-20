import SwiftUI

enum Feature: String, CaseIterable, Identifiable {
    case activity, music, shelf, tools, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: "Activity"
        case .music: "Music"
        case .shelf: "Shelf"
        case .tools: "Tools"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .activity: "waveform.path"
        case .music: "music.note"
        case .shelf: "tray"
        case .tools: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        }
    }
    var shortcut: Int { (Feature.allCases.firstIndex(of: self) ?? 0) + 1 }
}

enum Tool: String, CaseIterable, Identifiable {
    case notes, todos, clipboard, calendar, timer, apps, sound, system, mirror, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .sound: "Sound"
        case .system: "System"
        case .notes: "Notes"
        case .todos: "To-dos"
        case .calendar: "Calendar"
        case .mirror: "Mirror"
        case .apps: "Quick apps"
        case .timer: "Timer"
        case .shortcuts: "Shortcuts"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .sound: "speaker.wave.2"
        case .system: "gauge.with.dots.needle.33percent"
        case .notes: "note.text"
        case .todos: "checklist"
        case .calendar: "calendar"
        case .mirror: "camera"
        case .apps: "square.grid.3x2"
        case .timer: "timer"
        case .shortcuts: "bolt.horizontal.circle"
        }
    }
}

/// Where the workspace is. Sub-routes stay inside their feature's view so they animate in place;
/// switching features replaces the content while the surface morphs between their sizes.
enum Route: Hashable {
    case activity(detail: String?)
    case music
    case shelf
    case tools(Tool?)
    case history(detail: String?)
    case command

    static func root(_ feature: Feature) -> Route {
        switch feature {
        case .activity: .activity(detail: nil)
        case .music: .music
        case .shelf: .shelf
        case .tools: .tools(nil)
        case .history: .history(detail: nil)
        }
    }
    var feature: Feature? {
        switch self {
        case .activity: .activity
        case .music: .music
        case .shelf: .shelf
        case .tools: .tools
        case .history: .history
        case .command: nil
        }
    }
    /// Identity of the content view; sub-routes share their feature's view.
    var surface: String { feature?.rawValue ?? "command" }
    var parent: Route? {
        switch self {
        case .activity(.some): .activity(detail: nil)
        case .tools(.some): .tools(nil)
        case .history(.some): .history(detail: nil)
        default: nil
        }
    }
}

/// What the compact glance is about. Summary picks the most relevant live item.
enum GlanceSubject: Equatable {
    case summary
    case notification(String)
}

/// The drawn silhouette. Size, ears and corners animate together in one transaction.
struct SurfaceForm: Equatable {
    var size: CGSize
    var ear: CGFloat
    var corner: CGFloat
}

/// Everything that decides the surface's geometry, so the next size can be computed before any
/// state changes and the panel can grow ahead of the animation.
struct PresentationSnapshot: Equatable {
    var interaction: InteractionState
    var route: Route
    var openNoteID: UUID?
}

extension Presentation {
    /// Ordering used to tell opening from closing transitions.
    var depth: Int {
        switch self { case .collapsed: 0; case .preview: 1; case .expanded: 2 }
    }
}

extension DisplayGeometry {
    /// Height of the menu-bar band beside the camera housing.
    var band: CGFloat { CGFloat(notchHeight) }
}
