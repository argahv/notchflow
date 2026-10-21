import SwiftUI

/// The notch as a drop portal, drawn inside the one silhouette. A drag nearby gets a small inward
/// cue; a close one, a target that names what's coming; one over the notch, an opening that reads
/// deeper and says what a drop does. A drop is drawn up into the housing, then a one-line result.
struct PortalView: View {
    @ObservedObject var model: AppModel
    let stage: PortalStage

    var body: some View {
        Group {
            switch stage {
            case .closed:
                Color.clear
            case .aware:
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.silver.opacity(0.8))
                    .reveal(.primary)
                    .accessibilityLabel("Drop here to keep it on the shelf")
            case .attracted, .open:
                PortalTarget(cargo: model.portalCargo, open: stage == .open)
            case .receiving:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(Ink.silver).frame(width: 40)
                    PortalText(title: "Receiving \(model.portalCargo?.title ?? "the drop")…", detail: "The app is handing it over")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            case .absorbing, .failed:
                if let result = model.portalResult {
                    PortalResultView(model: model, result: result).id(result.id)
                } else { Color.clear }
            }
        }
        .padding(.horizontal, model.form.ear + 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func symbol(for kind: PortalContentKind?) -> String {
        switch kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        case .link: "link"
        case .text: "text.alignleft"
        case .mixed: "square.stack"
        case nil: "tray.and.arrow.down"
        }
    }
}

/// Close: what's coming and how many. Over the notch: the opening deepens and says what a drop does.
private struct PortalTarget: View {
    let cargo: PortalCargo?
    let open: Bool
    var body: some View {
        let title = cargo?.title ?? "Drop here"
        let keptAs = [.link, .text].contains(cargo?.kind) ? "saved to your shelf" : "kept on your shelf"
        HStack(spacing: 12) {
            CargoGlyph(kind: cargo?.kind, count: cargo?.count ?? 1, open: open)
            PortalText(title: open ? "Drop to keep" : title, detail: open ? "\(title) · \(keptAs)" : "Bring it to the notch")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: open ? 62 : nil)
        .background { if open { PortalWell().transition(.opacity) } }
        .frame(maxHeight: .infinity)
        .animation(Motion.quick, value: open)
        .accessibilityElement(children: .combine)
    }
}

/// The open portal's interior: darkest at the centre, shaded from the top, with a faint lit lip at
/// the bottom, so it reads as depth rather than as a card.
private struct PortalWell: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape.fill(RadialGradient(colors: [Ink.void, Ink.surface.opacity(0.92)], center: .center, startRadius: 6, endRadius: 240))
            .overlay(shape.fill(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Ink.silver.opacity(0.04), Ink.silver.opacity(0.24)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .allowsHitTesting(false)
    }
}

/// The kind's glyph; more than one item stacks cards behind it and shows the count.
private struct CargoGlyph: View {
    let kind: PortalContentKind?
    let count: Int
    let open: Bool
    var body: some View {
        let card = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            // Lighter than the front card and fanned out, so the stack reads at a glance.
            ForEach(Array((0..<min(2, max(0, count - 1))).reversed()), id: \.self) { layer in
                card.fill(Ink.hover.opacity(layer == 0 ? 0.9 : 0.55))
                    .overlay(card.strokeBorder(Ink.silver.opacity(0.1), lineWidth: 0.5))
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(layer == 0 ? 9 : -8))
                    .offset(x: layer == 0 ? 6 : -5, y: layer == 0 ? -3 : -1)
            }
            card.fill(Ink.elevated)
                .overlay(card.strokeBorder(Ink.silver.opacity(0.12), lineWidth: 0.5))
                .overlay(Image(systemName: PortalView.symbol(for: kind)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.silver))
                .frame(width: 30, height: 30)
            if count > 1 {
                Text("\(count)").font(TypeScale.badge).monospacedDigit().foregroundStyle(Ink.void)
                    .padding(.horizontal, 5).frame(height: 16).background(Capsule().fill(Ink.silver))
                    .offset(x: 15, y: -13)
            }
        }
        .scaleEffect(open ? 1.08 : 1)
        .frame(width: 42, height: 38)
        .accessibilityHidden(true)
    }
}

private struct PortalText: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
            Text(detail).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A drop drawn in: the items shrink and rise into the housing, fading behind its edge, and the
/// result takes their place. Only shown after the shelf has stored them. Reduce Motion: a fade.
private struct PortalResultView: View {
    @ObservedObject var model: AppModel
    let result: AppModel.PortalResult
    @State private var drawnIn = false
    @State private var confirmed = false

    var body: some View {
        let reduced = Motion.reduced
        let traveling = result.kept && !result.previews.isEmpty
        ZStack {
            if traveling {
                PreviewStack(previews: result.previews)
                    .scaleEffect(drawnIn && !reduced ? 0.28 : 1)
                    .offset(y: drawnIn && !reduced ? -46 : 0)
                    .blur(radius: drawnIn && !reduced ? 2 : 0)
                    .opacity(drawnIn ? 0 : 1)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 12) {
                ToneGlyph(symbol: result.kept ? "checkmark" : "exclamationmark.triangle.fill", tone: result.kept ? .green : .amber, size: 28)
                PortalText(title: result.title, detail: result.detail)
                Spacer(minLength: 8)
                if result.kept {
                    Button("Open") { model.navigate(.shelf); model.windows?.focus() }
                        .buttonStyle(PillButtonStyle())
                        .help("Open the shelf · ⌘3")
                }
            }
            .padding(.horizontal, 14)
            .opacity(confirmed || !traveling ? 1 : 0)
            .offset(y: confirmed || !traveling || reduced ? 0 : 4)
            .accessibilityElement(children: .combine)
        }
        .onAppear {
            guard traveling else { return }
            withAnimation(reduced ? .easeOut(duration: 0.16) : .easeIn(duration: 0.4)) { drawnIn = true }
            withAnimation(reduced ? .easeOut(duration: 0.16) : .spring(response: 0.3, dampingFraction: 0.9).delay(0.26)) { confirmed = true }
        }
    }
}

/// Up to three dropped items, layered.
private struct PreviewStack: View {
    let previews: [AppModel.PortalPreview]
    var body: some View {
        ZStack {
            ForEach(Array(previews.prefix(3).enumerated().reversed()), id: \.element.id) { index, preview in
                Group {
                    if let icon = preview.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.elevated)
                            .overlay(Image(systemName: preview.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.silver))
                    }
                }
                .frame(width: 38, height: 38)
                .rotationEffect(.degrees(index == 0 ? 0 : index == 1 ? 7 : -7))
                .offset(x: CGFloat(index) * 8, y: CGFloat(index) * -2)
            }
        }
    }
}
