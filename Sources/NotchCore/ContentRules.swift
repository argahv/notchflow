import Foundation

// Pure rules behind the clipboard, meeting, download and battery features, kept here so they're
// tested without a pasteboard, calendar, file system or battery.

public enum ClipKind: String, Codable, Sendable { case text, link, email, color, code }

public enum ClipClassifier {
    public static func kind(of text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil { return .color }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return .link }
        if trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return .email }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let codeMarks = ["{", "}", ";", "=>", "->", "func ", "def ", "let ", "const ", "import ", "</", "#include"]
        if lines.count > 1, codeMarks.filter({ trimmed.contains($0) }).count >= 2 { return .code }
        return .text
    }

    /// Best effort only: catches common token formats and long random-looking strings. It will miss
    /// some secrets and flag some harmless text; it is not a password detector.
    public static func looksSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"#, #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
            #"\bsk-[A-Za-z0-9_-]{20,}\b"#, #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\bAKIA[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{35}\b"#,
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
            // `key = value`, `key: value`, and the quoted JSON or YAML form `"key": "value"`.
            #"(?i)\b(?:password|passwd|secret|api[_-]?key|token)["']?\s*[:=]\s*\S{6,}"#
        ]
        if patterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) { return true }
        // Compact JSON is data, not a key; a token inside it is caught by the patterns above.
        if JSONFormatter.isDocument(trimmed) { return false }
        // A single long word mixing letters and digits with no spaces (generated passwords, raw keys).
        guard !trimmed.contains(where: \.isWhitespace), (16...256).contains(trimmed.count),
              URL(string: trimmed)?.scheme == nil else { return false }
        let classes = [trimmed.contains(where: \.isLowercase), trimmed.contains(where: \.isUppercase),
                       trimmed.contains(where: \.isNumber), trimmed.contains(where: { !$0.isLetter && !$0.isNumber })]
        return classes.filter { $0 }.count >= 3 && entropy(trimmed) >= 3.5
    }

    static func entropy(_ text: String) -> Double {
        let counts = Dictionary(text.map { ($0, 1) }, uniquingKeysWith: +)
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}

/// Video-call join links from an event's URL, location and notes. Conservative: only well-known
/// meeting hosts over HTTPS, so an arbitrary link in a description is never offered as "Join".
public enum MeetingLinks {
    static let hosts: [(suffix: String, path: String?, name: String)] = [
        ("zoom.us", "/j/", "Zoom"), ("zoom.us", "/my/", "Zoom"), ("meet.google.com", nil, "Google Meet"),
        ("teams.microsoft.com", "/l/meetup-join/", "Teams"), ("teams.live.com", "/meet/", "Teams"),
        ("webex.com", nil, "Webex"), ("whereby.com", nil, "Whereby"), ("facetime.apple.com", "/join", "FaceTime")
    ]

    public static func join(in texts: [String?]) -> (url: URL, service: String)? {
        for text in texts.compactMap({ $0 }) {
            for candidate in candidates(in: text) {
                guard candidate.scheme?.lowercased() == "https", let host = candidate.host?.lowercased() else { continue }
                for entry in hosts where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
                    if let path = entry.path, !candidate.path.hasPrefix(path) { continue }
                    if entry.suffix == "meet.google.com", candidate.path.count < 4 { continue }
                    if entry.suffix == "webex.com" {
                        let pathComponents = candidate.path.split(separator: "/")
                        let isMeetingPath = (pathComponents.first == "meet" && pathComponents.count > 1)
                            || pathComponents.first == "join" || candidate.path == "/j.php"
                        guard host.hasSuffix(".webex.com"), host != "www.webex.com", isMeetingPath else { continue }
                    }
                    if entry.suffix == "whereby.com", candidate.path.split(separator: "/").count != 1 { continue }
                    return (candidate, entry.name)
                }
            }
        }
        return nil
    }

    static func candidates(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }
}

/// Browser download names. A partial file (Safari `.download` bundle, Chrome `.crdownload`, Firefox
/// `.part`, Opera `.opdownload`) becomes the finished name when the browser renames it.
public enum DownloadNames {
    static let partialExtensions = ["download", "crdownload", "part", "opdownload", "partial"]

    public static func isPartial(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    /// The name the finished file will have (Firefox's `.part` keeps a random prefix, so it can't be predicted).
    public static func finalName(forPartial name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard isPartial(name), ext != "part" else { return nil }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }
    public static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r" || name.hasSuffix(".tmp")
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Low-battery alerts fire once when the charge falls through a threshold while unplugged.
public enum BatteryAlerts {
    public static let thresholds = [20, 10, 5]
    public static func crossed(from previous: Int?, to current: Int, charging: Bool) -> Int? {
        guard !charging, let previous, current < previous else { return nil }
        return thresholds.filter { current <= $0 && previous > $0 }.min()
    }
}
