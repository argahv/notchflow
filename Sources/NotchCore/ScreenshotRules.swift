import Foundation

// Pure rules behind Screenshot Magnet, kept here so they're tested without a screenshot folder,
// extended attributes or Vision.

/// Which new files in the screenshot folder are screenshots macOS just took. macOS has no public
/// screenshot event, so NotchFlow watches the folder screenshots are saved to and trusts only files
/// that are new, recent, of an image type, and carry the marker `screencapture` writes on its files.
public enum ScreenshotRules {
    /// Image formats `screencapture` can save. PDF screenshots aren't shown: there's no pixel preview to give.
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"]
    /// How recent a file must be to count as just taken. macOS saves a screenshot once its floating
    /// thumbnail goes away (about five seconds), so this leaves room for that.
    public static let freshness: TimeInterval = 30

    /// A file worth checking: visible, an image type, created after watching began and not long ago.
    /// An image downloaded or copied into the folder still fails `isScreenCapture`.
    public static func isCandidate(name: String, created: Date?, watchingSince: Date, now: Date) -> Bool {
        guard !name.hasPrefix("."), extensions.contains((name as NSString).pathExtension.lowercased()),
              let created else { return false }
        return created >= watchingSince.addingTimeInterval(-1) && now.timeIntervalSince(created) <= freshness
    }

    /// The `com.apple.metadata:kMDItemIsScreenCapture` extended attribute: a binary property list
    /// holding `true` on files `screencapture` wrote.
    public static func isScreenCapture(attribute data: Data?) -> Bool {
        guard let data, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    /// The folder screenshots go to: the `location` screencapture preference, with `~` expanded, or
    /// the Desktop when it's unset or not an absolute path.
    public static func folder(location: String?, home: URL) -> URL {
        guard var path = location?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if path == "~" { path = home.path } else if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
        guard path.hasPrefix("/") else { return home.appendingPathComponent("Desktop", isDirectory: true) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Whether screenshots are saved as files at all. They may instead go to the clipboard, Preview,
    /// Mail or Messages, which no folder can see.
    public static func savesToFile(target: String?) -> Bool {
        guard let target, !target.isEmpty else { return true }
        return target == "file"
    }
}

/// Recently reported keys, so a second write event, a rename or a re-scan never reports one file twice.
/// Bounded: the oldest key goes when it's full.
public struct RecentSet: Sendable {
    private var order: [String] = []
    private var members: Set<String> = []
    public let capacity: Int
    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    /// Adds a key. False when it was already there.
    public mutating func insert(_ key: String) -> Bool {
        guard members.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity { members.remove(order.removeFirst()) }
        return true
    }
    public func contains(_ key: String) -> Bool { members.contains(key) }
}

/// One line of recognised text. Coordinates are fractions of the image, origin top-left.
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var x: Double, y: Double, width: Double, height: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
    }
    var midY: Double { y + height / 2 }
}

/// Puts recognised lines in reading order: rows from top to bottom, lines left to right within a row,
/// a blank line where the gap between rows is more than one and a half lines (interfaces space their
/// lines about a line apart, which isn't a new paragraph). Columns side by side are read row by row,
/// which keeps a table's cells together; it doesn't reflow multi-column articles.
public enum TextLayout {
    public static func readingOrder(_ lines: [TextLine]) -> String {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return "" }
        var rows: [[TextLine]] = []
        for line in usable.sorted(by: { $0.midY < $1.midY }) {
            // Same row when the vertical centres are within half the taller line's height.
            if let last = rows.last?.last, abs(line.midY - last.midY) <= max(line.height, last.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var output = ""
        var previous: [TextLine]?
        for row in rows {
            let ordered = row.sorted { $0.x < $1.x }
            if let previous {
                let gap = (ordered.map(\.y).min() ?? 0) - (previous.map { $0.y + $0.height }.max() ?? 0)
                let lineHeight = previous.map(\.height).max() ?? 0
                output += gap > lineHeight * 1.5 ? "\n\n" : "\n"
            }
            output += ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            previous = ordered
        }
        return output
    }
}
