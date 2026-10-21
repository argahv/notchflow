import SwiftUI

/// Sound moved to another output: the device, its volume and mute, a quick switch to another output,
/// and the player's controls when music is on. Retracts by itself; no permanent overlay.
struct SoundGlance: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sound: SoundService
    @ObservedObject var media: MediaService
    let transition: SoundTransition

    var body: some View {
        HStack(spacing: 12) {
            ToneGlyph(symbol: Self.symbol(transition.name, bluetooth: sound.bluetooth), tone: .silver, size: 34).reveal(.primary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(Self.title(transition)).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.dismissSound() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 22, tint: Ink.secondary)).accessibilityLabel("Dismiss")
                }
                HStack(spacing: 8) {
                    Button { model.toggleSoundMute() } label: {
                        Image(systemName: sound.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(IconButtonStyle(size: 24)).disabled(sound.muted == nil)
                    .accessibilityLabel(sound.muted == true ? "Unmute" : "Mute")
                    if let volume = sound.volume {
                        Slider(value: Binding(get: { Double(volume) }, set: { model.setSoundVolume(Float($0)) }), in: 0...1)
                            .controlSize(.small).frame(width: 130).tint(Ink.silver)
                            .accessibilityLabel("Volume")
                    } else {
                        Text("Volume is set on the device").font(TypeScale.meta).foregroundStyle(Ink.secondary)
                    }
                    Menu {
                        ForEach(model.audioOutputs) { device in
                            Button { model.chooseSoundOutput(device) } label: {
                                if device.id == sound.output?.id { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                            }
                        }
                    } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24, height: 24)
                    .help("Choose an output").accessibilityLabel("Choose an output")
                    if model.preferences.mediaEnabled, media.hasTrack {
                        Button { media.command(.toggle) } label: { Image(systemName: media.playing ? "pause.fill" : "play.fill") }
                            .buttonStyle(IconButtonStyle(size: 24)).accessibilityLabel(media.playing ? "Pause" : "Play")
                        Button { media.command(.next) } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(IconButtonStyle(size: 24)).accessibilityLabel("Next track")
                    }
                }
                .reveal(.detail)
            }
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
    }

    static func title(_ transition: SoundTransition) -> String {
        switch transition {
        case .connected(let name): "\(name) connected"
        case .switched(let name, _): "Playing through \(name)"
        }
    }

    static func symbol(_ name: String, bluetooth: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("homepod") { return "homepod" }
        if bluetooth || lower.contains("headphone") { return "headphones" }
        if lower.contains("display") || lower.contains("tv") { return "tv" }
        return "speaker.wave.2"
    }
}
