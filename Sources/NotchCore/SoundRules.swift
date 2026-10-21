import Foundation

/// Spatial Sound Island: which audio changes are worth a moment in the notch. Only the output changing is
/// announced; volume keys already get macOS's own indicator, so NotchFlow doesn't add a second one.
public struct AudioSnapshot: Equatable, Sendable {
    public var output: UInt32?
    public var outputName: String?
    public var bluetooth: Bool
    public var devices: Set<UInt32>
    public init(output: UInt32?, outputName: String?, bluetooth: Bool, devices: Set<UInt32>) {
        self.output = output; self.outputName = outputName; self.bluetooth = bluetooth; self.devices = devices
    }
}

public enum SoundTransition: Equatable, Sendable {
    /// Sound moved to another output that was already there.
    case switched(name: String, bluetooth: Bool)
    /// A Bluetooth output (AirPods, a speaker) appeared and sound moved to it.
    case connected(name: String)

    public var name: String {
        switch self { case .switched(let name, _), .connected(let name): name }
    }
}

public enum SoundRules {
    /// The change between two looks at the audio system, if it's news. The first look never is.
    public static func transition(from old: AudioSnapshot?, to new: AudioSnapshot) -> SoundTransition? {
        guard let old, let output = new.output, let name = new.outputName, old.output != output else { return nil }
        return new.bluetooth && !old.devices.contains(output) ? .connected(name: name) : .switched(name: name, bluetooth: new.bluetooth)
    }
}
