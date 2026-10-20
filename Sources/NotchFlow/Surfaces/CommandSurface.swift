import SwiftUI

/// ⌘K: the command field grows out of the surface itself rather than opening a separate palette.
/// Arrows move the selection, Return runs it, Escape goes back to where you were.
struct CommandSurface: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    @Namespace private var selection

    var body: some View {
        let results = Array(model.commandResults.prefix(Metrics.maxCommandRows))
        VStack(spacing: Metrics.gap) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.secondary)
                TextField("Search or run a command", text: $model.commandQuery)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { model.runSelectedCommand() }
                Text("esc").font(TypeScale.meta).foregroundStyle(Ink.muted)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.hover, lineWidth: 1))
            }
            .padding(.horizontal, 10).frame(height: Metrics.field)
            .nookMaterial(.interactive, radius: 10, hovering: true)
            .reveal(.primary)

            VStack(spacing: 0) {
                if results.isEmpty {
                    Text("No matches").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                        .frame(height: Metrics.commandRow)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                    let selected = index == model.commandSelection
                    Button { item.run() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                                .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                            Text(item.title).font(TypeScale.body).foregroundStyle(Ink.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            if let hint = item.hint { Text(hint).font(TypeScale.meta).foregroundStyle(Ink.secondary) }
                        }
                        .padding(.horizontal, 10).frame(height: Metrics.commandRow)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.elevated)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { withAnimation(Motion.micro) { model.commandSelection = index } } }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .reveal(.secondary, stagger: Double(index) * 0.018)
                }
            }
        }
        .padding(Metrics.pad)
        .onChange(of: model.commandQuery) { _, _ in model.commandSelection = 0 }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { model.windows?.focus(); focused = true } }
    }
}
