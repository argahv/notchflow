import Foundation

enum ProviderStatus: Equatable {
    case off
    case running(String)
    case failed(String)
    var label: String {
        switch self {
        case .off: "Off"
        case .running(let detail): detail
        case .failed(let reason): reason
        }
    }
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// What a provider may do: hand events to the activity engine and report its own health.
struct ProviderContext {
    let deliver: @MainActor (ActivityEvent) -> Void
    let report: @MainActor (ProviderStatus) -> Void
}

/// One source of activity (local inbox, GitHub Actions, downloads, …). Providers start and stop
/// independently and surface failures through their status instead of throwing into the app.
@MainActor protocol ActivityProvider: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func start(_ context: ProviderContext)
    func stop()
}

/// Owns the providers: enables them from preferences, keeps their status for Settings, and isolates
/// failures so one broken integration can't affect the notch.
@MainActor final class ProviderHub: ObservableObject {
    @Published private(set) var statuses: [String: ProviderStatus] = [:]
    private(set) var providers: [any ActivityProvider] = []
    private var running: Set<String> = []
    private let deliver: @MainActor (ActivityEvent) -> Void

    init(deliver: @escaping @MainActor (ActivityEvent) -> Void) { self.deliver = deliver }

    func register(_ provider: any ActivityProvider) {
        providers.append(provider)
        statuses[provider.identifier] = .off
    }

    func setEnabled(_ identifier: String, _ enabled: Bool) {
        guard let provider = providers.first(where: { $0.identifier == identifier }) else { return }
        if enabled, !running.contains(identifier) {
            running.insert(identifier)
            let context = ProviderContext(deliver: { [weak self] event in
                guard self?.running.contains(identifier) == true else { return }
                self?.deliver(event)
            }, report: { [weak self] status in self?.statuses[identifier] = status })
            provider.start(context)
        } else if !enabled, running.contains(identifier) {
            running.remove(identifier)
            provider.stop()
            statuses[identifier] = .off
        }
    }

    func isRunning(_ identifier: String) -> Bool { running.contains(identifier) }
    func stopAll() { for identifier in running { setEnabled(identifier, false) } }
}

/// The owner-only file inbox used by the CLI, the command wrapper and the agent hooks.
@MainActor final class InboxProvider: ActivityProvider {
    let identifier = "inbox"
    let displayName = "Local events (CLI and agent hooks)"
    let bridge: EventBridge
    var onError: ((String) -> Void)?
    init(bridge: EventBridge) { self.bridge = bridge }
    func start(_ context: ProviderContext) {
        bridge.onEvent = { event in context.deliver(event) }
        bridge.onError = { [weak self] error in
            self?.onError?(error)
            context.report(.running("Watching local inbox · last error: \(error)"))
        }
        bridge.start()
        context.report(bridge.status == "Watching local inbox" ? .running(bridge.status) : .failed(bridge.status))
    }
    func stop() { bridge.stop() }
}
