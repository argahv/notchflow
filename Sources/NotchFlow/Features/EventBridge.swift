import Foundation
import Darwin

/// Owner-only atomic file spool. No network listener, authentication token, or shell execution.
@MainActor final class EventBridge {
    var onEvent: ((ActivityEvent) -> Void)?
    var onError: ((String) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let inbox = AppFiles.root.appendingPathComponent("inbox", isDirectory: true)
    private(set) var status = "Disabled"
    func start() {
        guard source == nil else { return }
        do {
            try AppFiles.prepare()
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
            descriptor = Darwin.open(inbox.path, O_EVTONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw EventError.invalid("Could not watch activity inbox") }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            watcher.setEventHandler { [weak self] in self?.drain() }
            let fd = descriptor; watcher.setCancelHandler { Darwin.close(fd) }
            source = watcher; watcher.resume(); status = "Watching local inbox"; drain()
        } catch { status = error.localizedDescription; onError?(status) }
    }
    private func drain() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.prefix(500)
            var accepted: [ActivityEvent] = []
            for url in urls {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular,
                          (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                          ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 16384 else {
                        throw EventError.invalid("Rejected unsafe inbox file")
                    }
                    let data = try Data(contentsOf: url)
                    let event = try ActivityEvent.decoder().decode(ActivityEvent.self, from: data)
                    try event.validate(); accepted.append(event)
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Move invalid events out of the hot path; never retry forever.
                    let rejected = inbox.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".rejected")
                    try? FileManager.default.moveItem(at: url, to: rejected)
                    onError?("Rejected activity: \(error.localizedDescription)")
                }
            }
            // A directory listing has no order; a burst (tool started, tool finished) applies oldest first.
            for event in accepted.sorted(by: { $0.timestamp < $1.timestamp }) { onEvent?(event) }
            // Rejected payloads are intentionally not retained indefinitely.
            let rejected = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "rejected" }
            for url in rejected {
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                if date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: url) }
            }
        } catch { onError?(error.localizedDescription) }
    }
    func stop() { source?.cancel(); source = nil; descriptor = -1; status = "Disabled" }
}
