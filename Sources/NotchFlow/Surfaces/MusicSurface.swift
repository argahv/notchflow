import SwiftUI

/// A compact player. The artwork is the shared element: it travels between the band, the glance
/// and this player, so collapsing condenses the player back toward it.
struct MusicSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaService
    @EnvironmentObject var preferences: Preferences
    @Environment(\.nookNamespace) private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !preferences.mediaEnabled {
                connect
            } else if !media.running {
                row(art: ArtworkView(image: nil, size: 64), title: "\(media.player) isn't open", detail: "Open it to see what's playing.") {
                    Button("Open \(media.player)") { media.openPlayer() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            } else {
                player
                if let error = media.error {
                    Text(error).font(TypeScale.secondary).foregroundStyle(Ink.amber).lineLimit(1).frame(height: 20, alignment: .bottomLeading)
                }
            }
        }
        .padding(Metrics.pad)
    }

    /// One prominent action; the alternative player is a quiet second choice.
    private var connect: some View {
        HStack(spacing: 12) {
            ToneGlyph(symbol: "music.note", tone: .iris, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect your music").font(TypeScale.cardTitle)
                Text("macOS asks before NotchFlow can control the player.").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 8)
            Button("Spotify") { preferences.mediaPlayer = "Spotify"; preferences.mediaEnabled = true }.buttonStyle(PillButtonStyle())
            Button("Music") { preferences.mediaPlayer = "Music"; preferences.mediaEnabled = true }.buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.emptyRow)
        .nookMaterial(.ambient)
        .reveal(.primary)
    }

    private var player: some View {
        HStack(spacing: 14) {
            ArtworkView(image: media.artwork, size: 64)
                .nookMatched("music-art", in: namespace)
                .reveal(.primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(media.hasTrack ? media.title : "Nothing playing")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .contentTransition(.opacity).animation(Motion.quick, value: media.title)
                Text(media.artist.isEmpty ? media.player : media.artist)
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Self.clock(media.elapsed))
                    ProgressLine(value: media.progress, tone: .iris)
                    Text(Self.clock(media.duration))
                }
                .font(TypeScale.meta.monospacedDigit()).foregroundStyle(Ink.secondary)
                .padding(.top, 5)
                .opacity(media.duration > 0 ? 1 : 0)
            }
            .reveal(.primary, stagger: 0.03)
            HStack(spacing: 2) {
                Button { media.command(.previous) } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(IconButtonStyle(size: 32)).accessibilityLabel("Previous track")
                Button { media.command(.toggle) } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 42)).accessibilityLabel(media.playing ? "Pause" : "Play")
                Button { media.command(.next) } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(IconButtonStyle(size: 32)).accessibilityLabel("Next track")
            }
            .reveal(.secondary)
        }
        .frame(height: 64)
    }

    private func row<Action: View>(art: ArtworkView, title: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            art.nookMatched("music-art", in: namespace).reveal(.primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            .reveal(.primary, stagger: 0.03)
            Spacer(minLength: 8)
            action().reveal(.secondary)
        }
        .frame(height: 64)
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
