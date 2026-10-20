import Foundation
import CoreAudio
import Darwin

struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Sound output devices through Core Audio's documented HAL properties.
enum AudioDevices {
    static func outputs() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), !isHidden(id), let name = name(of: id) else { return nil }
            return AudioOutput(id: id, name: name)
        }
    }

    static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// CPU, memory and thermal state, sampled only while the System tool is on screen.
struct SystemSample: Equatable {
    var cpu: Double?          // 0…1 since the previous sample
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var thermal: ProcessInfo.ThermalState
    var uptime: TimeInterval
}

struct SystemMetrics {
    private var previous: host_cpu_load_info?

    mutating func sample() -> SystemSample {
        let load = Self.cpuLoad()
        var cpu: Double?
        if let load, let previous {
            func ticks(_ info: host_cpu_load_info, _ state: Int32) -> Double {
                withUnsafeBytes(of: info.cpu_ticks) { Double($0.bindMemory(to: natural_t.self)[Int(state)]) }
            }
            let busy = [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_NICE].reduce(0.0) { $0 + ticks(load, $1) - ticks(previous, $1) }
            let idle = ticks(load, CPU_STATE_IDLE) - ticks(previous, CPU_STATE_IDLE)
            if busy + idle > 0 { cpu = busy / (busy + idle) }
        }
        previous = load
        return SystemSample(cpu: cpu, memoryUsed: Self.memoryUsed(), memoryTotal: ProcessInfo.processInfo.physicalMemory,
                            thermal: ProcessInfo.processInfo.thermalState, uptime: ProcessInfo.processInfo.systemUptime)
    }

    private static func cpuLoad() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Active, wired and compressed pages: the figure Activity Monitor calls "Memory Used", minus app cache.
    private static func memoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}
