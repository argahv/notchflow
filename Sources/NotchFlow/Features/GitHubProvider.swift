import Foundation
import Security

/// A GitHub token in the login Keychain, readable only on this Mac. Never logged, never shown again
/// after saving, never written anywhere else.
enum GitHubToken {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "com.argahv.notchflow.github",
                                               kSecAttrAccount as String: "token"]

    static func read() -> String? {
        var result: AnyObject?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static var exists: Bool {
        var lookup = query
        lookup[kSecReturnData as String] = false
        return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, trimmed.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw EventError.invalid("That doesn't look like a GitHub token.")
        }
        delete()
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "NotchFlow · GitHub Actions"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw EventError.invalid("Keychain refused the token (\(status)).") }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

/// Polls GitHub Actions workflow runs for the repositories the user lists. Read-only REST calls,
/// conditional requests (ETag), adaptive cadence, backoff and rate-limit handling. No webhooks: a
/// Mac app has no public endpoint, so updates are as fresh as the polling interval.
@MainActor final class GitHubActionsProvider: ActivityProvider {
    let identifier = "github"
    let displayName = "GitHub Actions"
    var repositories: [String] = [] { didSet { if repositories != oldValue { restart() } } }

    /// How long a live run stays in the stack after the last successful poll.
    private let liveFor: TimeInterval = 900
    private var context: ProviderContext?
    private var startedAt = Date()
    private var etags: [String: String] = [:]
    private var live: [String: [ActivityEvent]] = [:]
    private var failures = 0
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral   // no cookies, no disk cache
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func start(_ context: ProviderContext) {
        self.context = context
        startedAt = Date()
        schedule(after: 0.5)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        context = nil; etags = [:]; live = [:]; failures = 0
    }

    /// Starts over (new repositories, a new or removed token).
    func restart() {
        guard let context else { return }
        stop(); start(context)
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0.5, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = max(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var policy: GitHubPolicy {
        GitHubPolicy(authenticated: GitHubToken.exists, repositories: repositories.count,
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func poll() {
        guard context != nil else { return }
        let repositories = self.repositories.filter(GitHubRuns.isRepository)
        guard !repositories.isEmpty else {
            context?.report(.running("Add a repository to follow its workflow runs"))
            return
        }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let token = GitHubToken.read()
            var delay: TimeInterval?
            var problem: String?
            for repository in repositories {
                if Task.isCancelled { return }
                switch await self.fetch(repository, token: token) {
                case .ok: break
                case .wait(let seconds, let reason): delay = max(delay ?? 0, seconds); problem = reason
                case .failed(let reason): problem = reason
                }
            }
            guard !Task.isCancelled, self.context != nil else { return }
            let active = self.live.values.contains { !$0.isEmpty }
            if let delay {
                self.context?.report(.failed(problem ?? "Rate limited"))
                self.schedule(after: delay)
            } else if let problem {
                self.failures += 1
                self.context?.report(.failed(problem))
                self.schedule(after: self.policy.backoff(failures: self.failures, active: active))
            } else {
                self.failures = 0
                let interval = self.policy.interval(active: active)
                let auth = token == nil ? "public repositories only" : "token in Keychain"
                self.context?.report(.running("\(repositories.count) \(repositories.count == 1 ? "repository" : "repositories") · every \(Int(interval)) s · \(auth)"))
                self.schedule(after: interval)
            }
        }
    }

    private enum Outcome { case ok, wait(TimeInterval, String), failed(String) }

    private func fetch(_ repository: String, token: String?) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/actions/runs?per_page=10") else {
            return .failed("\(repository) isn't a valid repository")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NotchFlow", forHTTPHeaderField: "User-Agent")
        if let etag = etags[repository] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let data: Data, response: HTTPURLResponse
        do {
            let (body, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { return .failed("GitHub sent an unexpected response") }
            data = body; response = http
        } catch is CancellationError {
            return .ok
        } catch {
            return .failed("Can't reach GitHub (\((error as? URLError)?.code.rawValue ?? 0))")
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = "\(pair.value)" }
        }
        if let wait = GitHubPolicy.rateLimitDelay(status: response.statusCode, headers: headers, now: Date()) {
            return .wait(wait, "GitHub rate limit reached; retrying in \(Int(wait / 60) + 1) min")
        }
        switch response.statusCode {
        case 304:
            refreshLive(repository)
            return .ok
        case 200:
            if let etag = headers.first(where: { $0.key.lowercased() == "etag" })?.value { etags[repository] = etag }
            do { ingest(try GitHubRuns.decode(data), repository: repository) } catch { return .failed("Couldn't read runs for \(repository)") }
            return .ok
        case 401: return .failed("GitHub rejected the token. Replace it in Settings.")
        case 403: return .failed("No access to \(repository)'s Actions with this token")
        case 404: return .failed(token == nil ? "\(repository) not found. Private repositories need a token." : "\(repository) not found")
        default: return .failed("GitHub returned \(response.statusCode) for \(repository)")
        }
    }

    /// Live runs are re-sent with a later expiry; finished runs only once, and never ones that
    /// finished before this provider started (no burst of old notifications at launch).
    private func ingest(_ runs: [GitHubRun], repository: String) {
        let now = Date()
        var stillLive: [ActivityEvent] = []
        for run in runs {
            guard let event = GitHubRuns.event(for: run, repository: repository, refreshedAt: now, liveFor: liveFor) else { continue }
            if event.lifecycle.terminal {
                let wasLive = live[repository]?.contains { $0.activityId == event.activityId } == true
                guard wasLive || run.updatedAt > startedAt else { continue }
            } else {
                stillLive.append(event)
            }
            context?.deliver(event)
        }
        live[repository] = stillLive
    }

    private func refreshLive(_ repository: String) {
        let now = Date()
        live[repository] = live[repository]?.map { event in
            var event = event
            event.expiresAt = now.addingTimeInterval(liveFor)
            context?.deliver(event)
            return event
        }
    }
}
