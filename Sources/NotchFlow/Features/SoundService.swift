import AppKit
import CoreAudio
import AudioToolbox

/// Spatial Sound Island. Listens with CoreAudio property listeners (no polling, no permission) for the
/// default output, the list of devices, and the current output's volume and mute, and reports when sound
/// moves to another output. It knows nothing about what's playing and records nothing.
@MainActor final class SoundService: ObservableObject {
    @Published private(set) var output: AudioOutput?
    @Published private(set) var bluetooth = false
    @Published private(set) var volume: Float?
    @Published private(set) var muted: Bool?
    var onTransition: ((SoundTransition) -> Void)?

    private var snapshot: AudioSnapshot?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var levelListener: AudioObjectPropertyListenerBlock?
    private var watched: AudioDeviceID?
    private var refreshWork: DispatchWorkItem?
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let systemProperties = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
    private static let levelProperties = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    func start() {
        guard systemListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        for selector in Self.systemProperties {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, block)
        }
        systemListener = block
        refresh(announce: false)
    }

    func stop() {
        refreshWork?.cancel()
        if let block = systemListener {
            for selector in Self.systemProperties {
                var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, block)
            }
        }
        systemListener = nil
        watchLevels(of: nil)
    }

    func setVolume(_ value: Float) {
        guard let id = watched else { return }
        if AudioDevices.setVolume(value, of: id) { volume = value }
        if muted == true, value > 0, AudioDevices.setMuted(false, of: id) { muted = false }
    }

    func toggleMute() {
        guard let id = watched, let muted else { return }
        if AudioDevices.setMuted(!muted, of: id) { self.muted = !muted }
    }

    /// A device appearing fires several property changes at once; one look follows the burst.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(announce: true) }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh(announce: Bool) {
        let id = AudioDevices.defaultOutput()
        let name = id.flatMap(AudioDevices.name(of:))
        let next = AudioSnapshot(output: id, outputName: name, bluetooth: id.map(AudioDevices.isBluetooth) ?? false,
                                 devices: Set(AudioDevices.outputs().map(\.id)))
        let change = SoundRules.transition(from: snapshot, to: next)
        snapshot = next
        output = id.flatMap { id in name.map { AudioOutput(id: id, name: $0) } }
        bluetooth = next.bluetooth
        watchLevels(of: id)
        if announce, let change { onTransition?(change) }
    }

    private func watchLevels(of id: AudioDeviceID?) {
        if let old = watched, let block = levelListener {
            for selector in Self.levelProperties {
                var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(old, &address, .main, block)
            }
        }
        watched = id; levelListener = nil
        readLevels()
        guard let id else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readLevels() }
        }
        for selector in Self.levelProperties {
            var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(id, &address) { AudioObjectAddPropertyListenerBlock(id, &address, .main, block) }
        }
        levelListener = block
    }

    private func readLevels() {
        volume = watched.flatMap(AudioDevices.volume(of:))
        muted = watched.flatMap(AudioDevices.isMuted)
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
