import SwiftUI

struct WheelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: RunningApps
    let selectedID: String?

    private var selected: WheelApp? {
        model.apps.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular, in: Circle())

            ForEach(model.slots) { slot in
                let index = slot.id
                let app = slot.app
                let angle = Double(index) * 2 * .pi / Double(model.slots.count) - .pi / 2
                let active = app != nil && selectedID == app?.id
                let iconRadius: CGFloat = active && !reduceMotion ? 140 : 135

                WheelSector(index: index, count: model.slots.count)
                    .fill(
                        RadialGradient(
                            colors: [.accentColor.opacity(0.05), .accentColor.opacity(0.30)],
                            center: .center, startRadius: 75, endRadius: 190
                        )
                    )
                    .opacity(active ? 1 : 0)

                WheelSector(index: index, count: model.slots.count)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)

                WheelSector(index: index, count: model.slots.count)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
                    .opacity(active ? 1 : 0)

                WheelRim(index: index, count: model.slots.count)
                    .stroke(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.70), .white.opacity(0.95), .accentColor.opacity(0.70)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .shadow(color: .accentColor.opacity(0.65), radius: 7)
                    .opacity(active ? 1 : 0)

                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 64, height: 64)
                    .blur(radius: 12)
                    .opacity(active ? 1 : 0)
                    .offset(x: cos(angle) * iconRadius, y: sin(angle) * iconRadius)

                if let app {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .scaleEffect(active && !reduceMotion ? 1.16 : 1)
                        .shadow(color: .black.opacity(active ? 0.24 : 0.15), radius: active ? 10 : 6, y: active ? 6 : 4)
                        .overlay(alignment: .bottomTrailing) {
                            if app.favorite != nil {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.accentColor, in: Circle())
                            }
                        }
                        .offset(x: cos(angle) * iconRadius, y: sin(angle) * iconRadius)
                } else {
                    Circle().fill(.secondary.opacity(0.25)).frame(width: 5, height: 5)
                        .offset(x: cos(angle) * 135, y: sin(angle) * 135)
                }
            }

            VStack(spacing: 6) {
                Image(systemName: selected == nil ? "cursorarrow.rays" : "arrow.up.forward.app")
                    .font(.title2)
                    .foregroundStyle(selected == nil ? Color.secondary : Color.accentColor)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                Text(selected?.name ?? "Escolha um app")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(8)
            .frame(width: 126, height: 126)
            .background(.background.opacity(0.45), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.accentColor.opacity(selected == nil ? 0 : 0.30), lineWidth: 1)
            }
        }
        .frame(width: 380, height: 380)
        .contentShape(Circle())
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0.15), value: selectedID)
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

/// Just the outside arc, so the light follows the selected sector's rim.
private struct WheelRim: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let step = 360.0 / Double(max(count, 1))
        let middle = Double(index) * step - 90
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 5,
                    startAngle: .degrees(middle - step / 2 + 2),
                    endAngle: .degrees(middle + step / 2 - 2), clockwise: false)
        return path
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

