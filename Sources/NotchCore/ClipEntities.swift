import Foundation

// What a piece of copied text is, as far as local, deterministic detection can tell, and the exact
// transforms the suggestions offer for it. No model and no network: patterns, Foundation's data
// detectors and JSONSerialization decide.

public enum ClipEntity: Equatable, Sendable {
    case link(URL)
    case email(String)
    case phone(String)
    case color(ColorValue)
    case json
    case address(String)
    /// A date, with whether the text named a time of day. Without one, `date` is 9:00 that day.
    case date(Date, hasTime: Bool)
    case filePath(String)
    case code
    case prose(words: Int)
    case plain

    /// A short name for logs and the inspector. Never the content.
    public var kind: String {
        switch self {
        case .link: "link"
        case .email: "email address"
        case .phone: "phone number"
        case .color: "color"
        case .json: "JSON"
        case .address: "address"
        case .date: "date"
        case .filePath: "file path"
        case .code: "code"
        case .prose: "text"
        case .plain: "short text"
        }
    }
}

public struct ClipDetection: Equatable, Sendable {
    public var entity: ClipEntity
    /// 0…1: how sure the detection is, from how much of the text the entity covers.
    public var confidence: Double
    public init(_ entity: ClipEntity, confidence: Double) { self.entity = entity; self.confidence = confidence }
}

public enum ClipEntityDetector {
    /// Natural-language detection (addresses, phone numbers, dates) only looks at text this short; a
    /// long passage that happens to contain a date isn't "a date".
    static let detectorLimit = 300

    public static func detect(_ text: String, calendar: Calendar = .current) -> ClipDetection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ClipDetection(.plain, confidence: 0) }
        if let color = ColorValue(parsing: trimmed) { return ClipDetection(.color(color), confidence: 1) }
        if JSONFormatter.isDocument(trimmed) { return ClipDetection(.json, confidence: 0.95) }
        let singleWord = !trimmed.contains(where: \.isWhitespace)
        if singleWord, let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return ClipDetection(.link(url), confidence: 1)
        }
        if singleWord, trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return ClipDetection(.email(trimmed), confidence: 1)
        }
        if !trimmed.contains("\n"), trimmed.count < 1024, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return ClipDetection(.filePath(trimmed), confidence: 0.9)
        }
        if trimmed.utf16.count <= detectorLimit, let found = natural(trimmed, calendar: calendar) { return found }
        if ClipClassifier.kind(of: trimmed) == .code { return ClipDetection(.code, confidence: 0.7) }
        let words = TextTransforms.words(trimmed)
        return words >= 40 ? ClipDetection(.prose(words: words), confidence: 0.8) : ClipDetection(.plain, confidence: 0.5)
    }

    /// The data detector's best match, kept only when it is most of the text: "Lunch Tuesday at 1pm"
    /// is a date; a paragraph that mentions one isn't.
    static func natural(_ text: String, calendar: Calendar) -> ClipDetection? {
        let types: NSTextCheckingResult.CheckingType = [.address, .phoneNumber, .date]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: whole)
        guard let best = matches.max(by: { $0.range.length < $1.range.length }), whole.length > 0 else { return nil }
        let coverage = Double(best.range.length) / Double(whole.length)
        let matched = (text as NSString).substring(with: best.range)
        // How much of the text the match covers is how sure it is: 0.6 a fair guess, all of it certain.
        let confidence = min(1, coverage)
        switch best.resultType {
        case .address where coverage >= 0.6:
            return ClipDetection(.address(matched), confidence: confidence)
        case .phoneNumber where coverage >= 0.8:
            guard let number = best.phoneNumber else { return nil }
            return ClipDetection(.phone(number), confidence: confidence)
        case .date where coverage >= 0.5:
            guard let date = best.date else { return nil }
            let hasTime = matched.range(of: #"(?i)\d{1,2}[:.]\d{2}|\d\s?(am|pm)\b|\b(noon|midnight)\b"#, options: .regularExpression) != nil
            let due = hasTime ? date : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date)
            return ClipDetection(.date(due, hasTime: hasTime), confidence: max(0.6, confidence))
        default:
            return nil
        }
    }
}

/// An sRGB color from a CSS-style hex or `rgb()` value.
public struct ColorValue: Equatable, Hashable, Sendable {
    public var red: Int, green: Int, blue: Int
    /// 0…1.
    public var alpha: Double
    /// The notation it was written in, so the suggestions offer the others.
    public var notation: Notation
    public enum Notation: String, Sendable { case hex, rgb }

    public init(red: Int, green: Int, blue: Int, alpha: Double = 1, notation: Notation = .hex) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.notation = notation
    }

    public init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            let digits = Array(value.dropFirst())
            guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
            let expanded = digits.count == 3 ? digits.flatMap { [$0, $0] } : digits
            func byte(_ at: Int) -> Int { Int(String(expanded[at..<at + 2]), radix: 16) ?? 0 }
            self.init(red: byte(0), green: byte(2), blue: byte(4), alpha: expanded.count == 8 ? Double(byte(6)) / 255 : 1, notation: .hex)
            return
        }
        let pattern = #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*(0|1|0?\.\d+)\s*)?\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
        guard let r = group(1).flatMap(Int.init), let g = group(2).flatMap(Int.init), let b = group(3).flatMap(Int.init),
              [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.init(red: r, green: g, blue: b, alpha: group(4).flatMap(Double.init) ?? 1, notation: .rgb)
    }

    public var hex: String {
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha < 1 ? base + String(format: "%02X", Int((alpha * 255).rounded())) : base
    }
    public var rgb: String {
        alpha < 1 ? "rgba(\(red), \(green), \(blue), \(Self.trim(alpha)))" : "rgb(\(red), \(green), \(blue))"
    }
    /// Hue in degrees, saturation and lightness in whole percent, rounded the way design tools show them.
    public var hsl: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b), lightness = (high + low) / 2
        var hue = 0.0, saturation = 0.0
        if high != low {
            let delta = high - low
            saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
            switch high {
            case r: hue = (g - b) / delta + (g < b ? 6 : 0)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue *= 60
        }
        let h = Int(hue.rounded()) % 360, s = Int((saturation * 100).rounded()), l = Int((lightness * 100).rounded())
        return alpha < 1 ? "hsla(\(h), \(s)%, \(l)%, \(Self.trim(alpha)))" : "hsl(\(h), \(s)%, \(l)%)"
    }
    static func trim(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

/// Removes tracking parameters from a link and nothing else. Conservative: only parameters whose sole
/// purpose is attribution, so a cleaned link still opens the same page.
public enum LinkCleaner {
    static let exact: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "ref_src", "ref_url",
    ]
    /// `si` identifies who shared a link, but only these hosts use it that way.
    static let shareHosts = ["youtube.com", "youtu.be", "spotify.com"]

    /// The link without its trackers, or nil when it has none.
    public static func clean(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let host = components.host?.lowercased() ?? ""
        let sharing = shareHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") || exact.contains(name) { return false }
            return !(sharing && name == "si")
        }
        guard kept.count < items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }

    public static func trackerCount(_ url: URL) -> Int {
        guard let cleaned = clean(url) else { return 0 }
        let before = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.count ?? 0
        let after = URLComponents(url: cleaned, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.count ?? 0
        return before - after
    }
}

/// Reformats JSON exactly: keys keep their order, strings and numbers are untouched, only whitespace
/// between tokens changes. Input that isn't a JSON object or array is refused.
public enum JSONFormatter {
    public static func isDocument(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"), trimmed.count > 2,
              let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// The number of keys in an object or elements in an array.
    public static func topLevelCount(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = value as? [String: Any] { return object.count }
        if let array = value as? [Any] { return array.count }
        return nil
    }

    public static func pretty(_ text: String, indent: Int = 2) -> String? { reformat(text, indent: indent) }
    public static func minified(_ text: String) -> String? { reformat(text, indent: nil) }

    static func reformat(_ text: String, indent: Int?) -> String? {
        guard isDocument(text) else { return nil }
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var output = "", depth = 0, index = 0, inString = false, escaped = false
        func newline() { if let indent { output += "\n" + String(repeating: " ", count: indent * depth) } }
        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true; output.append(character)
            case "{", "[":
                // An empty container stays on one line.
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == (character == "{" ? "}" : "]") {
                    output += character == "{" ? "{}" : "[]"
                    index = next
                } else {
                    output.append(character); depth += 1; newline()
                }
            case "}", "]":
                depth -= 1; newline(); output.append(character)
            case ",":
                output.append(character); newline()
            case ":":
                output += indent == nil ? ":" : ": "
            case _ where character.isWhitespace:
                break
            default:
                output.append(character)
            }
        }
        return output
    }
}
