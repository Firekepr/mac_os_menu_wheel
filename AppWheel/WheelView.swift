import SwiftUI

struct WheelView: View {
    @ObservedObject var model: RunningApps
    let selectedID: pid_t?

    private var selected: WheelApp? {
        model.apps.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular, in: Circle())

            ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                let angle = Double(index) * 2 * .pi / Double(model.apps.count) - .pi / 2
                let active = selectedID == app.id

                WheelSector(index: index, count: model.apps.count)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.clear)

                WheelSector(index: index, count: model.apps.count)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)

                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .scaleEffect(active ? 1.14 : 1)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                    .offset(x: cos(angle) * 135, y: sin(angle) * 135)
            }

            VStack(spacing: 6) {
                Image(systemName: selected == nil ? "cursorarrow.rays" : "arrow.up.forward.app")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(selected?.name ?? "Escolha um app")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(width: 126, height: 126)
            .background(.background.opacity(0.45), in: Circle())
        }
        .frame(width: 380, height: 380)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.13), value: selectedID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Roda de aplicativos")
        .accessibilityValue(selected?.name ?? "Nenhum aplicativo selecionado")
        .accessibilityActions {
            ForEach(model.apps) { app in
                Button("Abrir \(app.name)") { model.activate(app) }
            }
        }
    }

}

private struct WheelSector: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let step = 360.0 / Double(max(count, 1))
        let start = Angle.degrees(Double(index) * step - 90 - step / 2)
        let end = Angle.degrees(Double(index) * step - 90 + step / 2)
        var path = Path()
        path.addArc(center: center, radius: rect.width / 2 - 5,
                    startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: 77,
                    startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

