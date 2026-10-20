import Foundation

/// macOS suspends distributed-notification delivery to an app that isn't active, and an accessory
/// app like this one is almost never active. Only observers registered with `.deliverImmediately`
/// bypass that, which the block-based API can't request; this wraps the selector-based one.
final class DistributedObserver: NSObject {
    private let handler: (Notification) -> Void
    init(name: String, handler: @escaping (Notification) -> Void) {
        self.handler = handler
        super.init()
        // AppKit marks the centre suspended for apps that aren't frontmost; an accessory app never is.
        DistributedNotificationCenter.default().suspended = false
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)), name: Notification.Name(name),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }
    @objc private func receive(_ note: Notification) {
        if Thread.isMainThread { handler(note) } else { DispatchQueue.main.async { self.handler(note) } }
    }
    func invalidate() { DistributedNotificationCenter.default().removeObserver(self) }
    deinit { invalidate() }
}
