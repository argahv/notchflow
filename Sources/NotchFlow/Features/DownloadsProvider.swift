import Foundation
import Darwin

/// Follows the Downloads folder. Honest states only: a browser's partial file means "downloading"
/// (its size so far, never a guessed percentage); its rename to the final name means "downloaded";
/// a partial that vanishes without a finished file means the download stopped.
@MainActor final class DownloadsProvider: ActivityProvider {
    let identifier = "downloads"
    let displayName = "Download Center"
    private let folder: URL = {
        #if DEBUG
        // Scripted QA points this at a scratch folder instead of the real Downloads.
        if let path = UserDefaults.standard.string(forKey: "NotchFlowDebugDownloadsFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }()
    private var context: ProviderContext?
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var partials: [String: Date] = [:]   // partial name → first seen
    private var sizeTimer: Timer?

    func start(_ context: ProviderContext) {
        self.context = context
        guard let names = try? scan() else {
            context.report(.failed("Can't read Downloads. Allow NotchFlow under System Settings › Privacy & Security › Files and Folders."))
            return
        }
        known = names
        for name in names where DownloadNames.isPartial(name) { partials[name] = Date(); publish(partial: name) }
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { context.report(.failed("Can't watch the Downloads folder")); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.rescan() } }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        watcher.resume()
        source = watcher
        updateSizeTimer()
        context.report(.running("Watching Downloads"))
    }

    func stop() {
        source?.cancel(); source = nil
        sizeTimer?.invalidate(); sizeTimer = nil
        context = nil; known = []; partials = [:]
    }

    private func scan() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !DownloadNames.isIgnored($0) })
    }

    private func rescan() {
        guard let names = try? scan() else { return }
        let added = names.subtracting(known), removed = known.subtracting(names)
        let addedFiles = added.filter { !DownloadNames.isPartial($0) }
        var explained: Set<String> = []
        for name in added where DownloadNames.isPartial(name) {
            partials[name] = Date(); publish(partial: name)
        }
        for name in removed where partials[name] != nil {
            partials[name] = nil
            // The finished file is the predicted name, or (Firefox) the one new file that appeared with it.
            let predicted = DownloadNames.finalName(forPartial: name).flatMap { names.contains($0) ? $0 : nil }
            let finished = predicted ?? (addedFiles.count == 1 ? addedFiles.first : nil)
            if let finished {
                explained.insert(finished)
                publish(finished: finished, id: id(forPartial: name))
            } else {
                publish(stopped: name)
            }
        }
        for name in addedFiles where !explained.contains(name) {
            // Saved, copied or moved straight into Downloads: say exactly that.
            publish(finished: name, id: "file-" + name, title: "New in Downloads: \(name)")
        }
        known = names
        updateSizeTimer()
    }

    private func id(forPartial name: String) -> String { "dl-" + String((DownloadNames.finalName(forPartial: name) ?? name).prefix(120)) }

    private func publish(partial name: String) {
        let display = DownloadNames.finalName(forPartial: name) ?? "a file"
        let size = size(of: folder.appendingPathComponent(name))
        context?.deliver(ActivityEvent(source: "downloads", activityId: id(forPartial: name), state: .running,
                                       title: String("Downloading \(display)".prefix(160)), category: .download,
                                       summary: size > 0 ? "\(DownloadNames.size(size)) so far" : nil,
                                       expiresAt: Date().addingTimeInterval(1800)))
    }

    private func publish(finished name: String, id: String, title: String? = nil) {
        let url = folder.appendingPathComponent(name)
        let size = size(of: url)
        context?.deliver(ActivityEvent(source: "downloads", activityId: String(id.prefix(128)), state: .completed,
                                       title: String((title ?? "Downloaded \(name)").prefix(160)), category: .download,
                                       summary: size > 0 ? DownloadNames.size(size) : nil, actionURL: url.absoluteString))
    }

    private func publish(stopped name: String) {
        let display = DownloadNames.finalName(forPartial: name) ?? "a file"
        context?.deliver(ActivityEvent(source: "downloads", activityId: id(forPartial: name), state: .cancelled,
                                       title: String("Download stopped: \(display)".prefix(160)), category: .download))
    }

    /// Sizes update every few seconds only while something is downloading.
    private func updateSizeTimer() {
        if partials.isEmpty { sizeTimer?.invalidate(); sizeTimer = nil; return }
        guard sizeTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for name in self.partials.keys { self.publish(partial: name) }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        sizeTimer = timer
    }

    /// Bytes on disk; Safari's `.download` is a folder, so its contents are added up.
    private func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
