import SwiftUI

struct WheelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: RunningApps
    let selectedID: String?
    var isOpenMainWindowHovered = false
    var isActive = true
    @State private var memory: AppMemoryUsage?
    @State private var memoryPID: pid_t?
    @State private var isLoadingMemory = false

    private var selected: WheelApp? {
        model.apps.first { $0.id == selectedID }
    }

    private var selectedPID: pid_t? {
        guard isActive else { return nil }
        guard let application = selected?.application, !application.isTerminated else { return nil }
        return application.processIdentifier
    }

    private var memoryLabel: String? {
        guard selectedPID != nil else { return nil }
        guard memoryPID == selectedPID else { return L10n.text("RAM: consultando…") }
        if let memory { return "RAM ≈ \(memory.formatted)" }
        return isLoadingMemory ? L10n.text("RAM: consultando…") : L10n.text("RAM indisponível")
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
                        .modifier(SelectedIconFloat(isSelected: active && isActive))
                        .overlay(alignment: .bottom) {
                            if app.favorite != nil && model.isRunning(app) {
                                RunningAppIndicator().offset(y: 12)
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
                Text(selected?.name ?? L10n.text("Escolha um app"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if let memoryLabel {
                    Text(memoryLabel)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(memory?.help ?? L10n.text("Consumo de memória do aplicativo selecionado."))
                }
            }
            .offset(y: selected == nil ? -16 : 0)
            .padding(8)
            .frame(width: WheelGeometry.centerDiameter, height: WheelGeometry.centerDiameter)
            .background(.background.opacity(0.45), in: Circle())
            .overlay {
                if selected == nil {
                    CenterOpenArea()
                        .fill(Color.accentColor.opacity(isOpenMainWindowHovered ? 0.45 : 0.12))
                        .overlay(alignment: .bottom) {
                            Label(L10n.text("Abrir"), systemImage: "macwindow")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isOpenMainWindowHovered ? Color.white : Color.primary)
                                .padding(.top, 6)
                                .frame(width: WheelGeometry.centerDiameter,
                                       height: WheelGeometry.centerDiameter * WheelGeometry.centerOpenFraction,
                                       alignment: .top)
                        }
                        .clipShape(CenterOpenArea())
                        .overlay { CenterOpenArea().stroke(.primary.opacity(0.12), lineWidth: 1) }
                        .help(L10n.text("Abrir AppWheel"))
                }
            }
            .overlay {
                Circle()
                    .stroke(Color.accentColor.opacity(selected == nil ? 0 : 0.30), lineWidth: 1)
            }
        }
        .frame(width: 380, height: 380)
        .contentShape(Circle())
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0.15), value: selectedID)
        .animation(.easeOut(duration: 0.12), value: isOpenMainWindowHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Roda de aplicativos"))
        .accessibilityValue([selected?.name ?? L10n.text("Nenhum aplicativo selecionado"),
                             selected.map { L10n.text(model.isRunning($0) ? "Em execução" : "Fechado") },
                             memoryLabel].compactMap { $0 }.joined(separator: ", "))
        .task(id: selectedPID) {
            memory = nil
            memoryPID = selectedPID
            isLoadingMemory = true
            guard let pid = selectedPID else { isLoadingMemory = false; return }
            let bundlePath = selected?.application?.bundleURL?.path
            // Sweeping across icons should not enumerate every process for
            // every transient selection. Cancellation stops this debounce.
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            while !Task.isCancelled {
                let worker = Task.detached(priority: .utility) {
                    AppMemory.sample(root: pid, bundlePath: bundlePath)
                }
                let sample = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                memory = sample
                isLoadingMemory = false
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .accessibilityActions {
            ForEach(model.apps) { app in
                Button(L10n.text("Abrir %@", app.name)) { model.activate(app) }
                if app.canRequestQuit {
                    Button(L10n.text("Fechar %@", app.name)) { model.requestQuit(app) }
                }
            }
            Button(L10n.text("Abrir AppWheel")) {
                NotificationCenter.default.post(name: .appWheelOpenMainWindow, object: nil)
            }
        }
    }

}

/// A static Dock-style marker; no timers or continuous animations.
struct RunningAppIndicator: View {
    var body: some View {
        Circle()
            .fill(.primary.opacity(0.8))
            .frame(width: 4, height: 4)
            .accessibilityHidden(true)
    }
}

private struct CenterOpenArea: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let angle = asin(1 - 2 * WheelGeometry.centerOpenFraction)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .radians(angle), endAngle: .radians(.pi - angle), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct SelectedIconFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    @State private var startedAt: Date?

    private var isFloating: Bool { isSelected && !reduceMotion }

    func body(content: Content) -> some View {
        // Keep the exact same image subtree when selection changes. Conditionally
        // wrapping it in a phase animator replaces its identity and can flicker.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isFloating)) { context in
            let elapsed = startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            let lift = isFloating ? -2 * (1 - cos(elapsed * 2 * .pi / 2.3)) : 0
            content.offset(y: lift)
        }
        .onChange(of: isFloating, initial: true) { _, floating in
            // Start at zero displacement and velocity on every selection.
            startedAt = floating ? .now : nil
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

