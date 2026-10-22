import Foundation

/// Agent Rescue: a failed run or build turned into a short brief that the person reviews, edits and pastes into
/// a coding agent. It's built only from what the activity already carries (title, summary, project, branch,
/// link). Nothing is fetched and nothing is sent. A summary marked private, or anything that looks like a key
/// or password, is left out, and the agent is asked to propose a fix rather than push or change CI.
public enum AgentRescue {
    /// Failures worth handing to an agent: pipelines, builds, deploys, agents' own turns and wrapped commands.
    public static let categories: Set<ActivityCategory> = [.ci, .build, .deploy, .agent, .task]

    public static func canHandOff(_ event: ActivityEvent) -> Bool {
        event.lifecycle == .failed && categories.contains(event.kind)
    }

    /// The brief, or nil for anything that isn't a failure worth handing off.
    public static func brief(for event: ActivityEvent) -> String? {
        guard canHandOff(event) else { return nil }
        let what: String = switch event.kind {
        case .ci: "CI run"
        case .build: "Build"
        case .deploy: "Deploy"
        case .agent: "Agent turn"
        default: "Task"
        }
        let title = ClipClassifier.looksSecret(event.title) ? "(title left out: it looked like a key)" : String(event.title.prefix(160))
        var lines = ["## \(what) failed: \(title)", ""]
        let place = [event.project ?? event.agent?.repository, event.branch.map { "branch `\($0)`" }].compactMap { $0 }
        if !place.isEmpty { lines.append("- Where: " + place.joined(separator: ", ")) }
        lines.append("- Reported by: " + source(of: event))
        lines.append("- When: " + Self.timestamp.string(from: event.timestamp))
        if let link = event.actionURL.flatMap(URL.init(string:)), ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
            lines.append("- Run: " + link.absoluteString)
        }
        if let summary = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            if event.sensitive == true {
                lines.append("- Details: left out, marked private by the tool that reported them")
            } else if ClipClassifier.looksSecret(summary) {
                lines.append("- Details: left out, they looked like a key or password")
            } else {
                lines.append("- Details: " + String(summary.prefix(600)).replacingOccurrences(of: "\n", with: " "))
            }
        }
        lines += ["", "Please find out why this failed and propose a fix. Show me the change before applying it,",
                  "don't push, and don't change CI, deployment or credentials without asking."]
        return lines.joined(separator: "\n")
    }

    static func source(of event: ActivityEvent) -> String {
        if let provider = event.agent?.provider { return provider }
        switch event.source {
        case "github": return "GitHub Actions"
        case "cli", "notchflow": return "a command run through NotchFlow"
        default: return event.source
        }
    }

    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
