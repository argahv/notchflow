import AppKit
import Combine

/// Music / Spotify adapter. Track, artist and play state arrive through each player's public
/// distributed notification — no polling and no Automation permission. Position, duration and
/// Music artwork are read with AppleScript only while the Music view is visible.
@MainActor final class MediaService: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var running = false
    @Published var error: String?
    var progress: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
    var hasTrack: Bool { !title.isEmpty }
    private(set) var player = "Music"

    private var observer: DistributedObserver?
    private var poll: Timer?
    private var trackID: String?
    private var artworkTrack: String?
    private var bundleID: String { player == "Spotify" ? "com.spotify.client" : "com.apple.Music" }
    private var notificationName: String {
        player == "Spotify" ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo"
    }
    private var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    func configure(player: String, enabled: Bool, polling: Bool) {
        if self.player != player { stopObserving(); stopPolling(); self.player = player; reset() }
        if enabled { startObserving() } else { stopObserving(); stopPolling(); reset(); return }
        if polling { startPolling() } else { stopPolling() }
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = DistributedObserver(name: notificationName) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.apply(info) }
        }
        running = isRunning
    }
    private func stopObserving() {
        observer?.invalidate()
        observer = nil
    }

    private func apply(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        running = true; error = nil
        guard state != "Stopped" else { reset(); running = isRunning; return }
        playing = state == "Playing"
        if let name = info["Name"] as? String { title = name }
        if let by = info["Artist"] as? String { artist = by }
        // Music reports milliseconds in "Total Time"; Spotify in "Duration".
        if let total = (info["Total Time"] as? NSNumber) ?? (info["Duration"] as? NSNumber) { duration = total.doubleValue / 1000 }
        if let position = info["Playback Position"] as? NSNumber { elapsed = position.doubleValue }
        let id = (info["PersistentID"] as? NSNumber)?.stringValue ?? (info["Track ID"] as? String) ?? title
        if id != trackID {
            trackID = id; artwork = nil
            if poll != nil { fetchArtwork() }
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }
    private func stopPolling() { poll?.invalidate(); poll = nil }

    private func refresh() {
        running = isRunning
        guard running else { playing = false; return }
        let durationExpression = player == "Spotify" ? "(duration of current track) / 1000" : "duration of current track"
        let idExpression = player == "Spotify" ? "id of current track" : "persistent ID of current track"
        guard let result = script("""
            if player state is stopped then return {"", "", false, 0, 0, ""}
            return {name of current track, artist of current track, player state is playing, player position, \(durationExpression), \(idExpression)}
            """) else { return }
        title = result.atIndex(1)?.stringValue ?? ""
        artist = result.atIndex(2)?.stringValue ?? ""
        playing = result.atIndex(3)?.booleanValue ?? false
        elapsed = result.atIndex(4)?.doubleValue ?? 0
        duration = result.atIndex(5)?.doubleValue ?? 0
        let id = result.atIndex(6)?.stringValue
        if let id, !id.isEmpty, id != trackID { trackID = id; artwork = nil }
        if artwork == nil { fetchArtwork() }
    }

    /// Music exposes artwork bytes locally. Spotify only offers a remote URL, which this app does
    /// not fetch (no network access); its views use a generated placeholder.
    private func fetchArtwork() {
        guard player == "Music", let id = trackID, artworkTrack != id else { return }
        artworkTrack = id
        if let data = script("return raw data of artwork 1 of current track", reportErrors: false)?.data, let image = NSImage(data: data) {
            artwork = image
        }
    }

    func command(_ command: Command) {
        if !isRunning { openPlayer(); return }
        _ = script(command.rawValue)
        if command == .toggle { playing.toggle() }
        if poll != nil { refresh() }
    }
    enum Command: String { case toggle = "playpause", next = "next track", previous = "previous track" }

    /// Moves playback to a fraction of the current track (both players accept `player position` in seconds).
    func seek(to fraction: Double) {
        guard isRunning, duration > 0 else { return }
        let seconds = max(0, min(duration - 0.5, fraction * duration))
        _ = script("set player position to \(String(format: "%.2f", seconds))")
        elapsed = seconds
        if poll != nil { refresh() }
    }

    func openPlayer() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            error = "\(player) isn't installed."; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func script(_ body: String, reportErrors: Bool = true) -> NSAppleEventDescriptor? {
        guard isRunning else { return nil }
        var info: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 2 seconds\ntell application id \"\(bundleID)\"\n\(body)\nend tell\nend timeout")?
            .executeAndReturnError(&info)
        if let info {
            if reportErrors {
                // -1743: the person declined Automation; say how to recover instead of quoting AppleScript.
                let code = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                error = code == -1743
                    ? "Allow \(player) control in System Settings › Privacy › Automation."
                    : "\(player) didn't respond. Try again in a moment."
            }
            return nil
        }
        if reportErrors { error = nil }
        return result
    }

    #if DEBUG
    /// Scripted QA only: stands in for a playing track so layouts can be checked without a player.
    func debugNowPlaying(title: String?, artist: String) {
        if let title { self.title = title; self.artist = artist; playing = true; running = true }
        else { reset(); running = isRunning }
    }
    #endif

    private func reset() { title = ""; artist = ""; playing = false; elapsed = 0; duration = 0; artwork = nil; trackID = nil; artworkTrack = nil }
    func stop() { stopPolling(); stopObserving() }
}
