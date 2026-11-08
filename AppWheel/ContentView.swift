import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var gesture: GestureController
    @ObservedObject var preferences: WheelPreferences
    @StateObject private var model: RunningApps
    @StateObject private var interaction = WheelInteraction()
    @State private var showsExceptions = false

    init(preferences: WheelPreferences, favorites: AppFavorites? = nil) {
        self.preferences = preferences
        _model = StateObject(wrappedValue: RunningApps(favorites: favorites))
    }

    private var previewDiameter: CGFloat { min(CGFloat(preferences.wheelDiameter), 280) }

    private var selected: WheelApp? {
        model.apps.first { $0.id == interaction.id }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("AppWheel")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Seus aplicativos, a um gesto de distância.")
                    .foregroundStyle(.secondary)
            }

            WheelWithActions(model: model, interaction: interaction)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): select(at: point)
                    case .ended: interaction.reset()
                    }
                }
                .onTapGesture { location in
                    select(at: location)
                    if interaction.isOpenMainWindowHovered {
                        gesture.openMainWindow()
                    } else if interaction.isCloseHovered,
                       let target = model.apps.first(where: { $0.id == interaction.closeTargetID }) {
                        model.requestQuit(target)
                    } else if let selected { model.activate(selected) }
                    interaction.reset()
                }

            VStack(spacing: 7) {
                Text("Prévia interativa")
                    .font(.headline)
                Text("Clique para trocar de app. Pause sobre um app para revelar a ação de fechar.")
                Text(preferences.gestureHint + " Centro superior ou Esc para cancelar.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(gesture.isEnabled ? "Desativar gesto" : "Ativar gesto global") {
                    if gesture.isEnabled { gesture.stop() } else { gesture.start() }
                }
                .buttonStyle(.borderedProminent)
                Button("Prévia flutuante") { gesture.preview() }
                    .buttonStyle(.bordered)
            }
            Text(gesture.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if gesture.needsPermission {
                Button("Abrir ajustes de Acessibilidade") { gesture.openAccessibilitySettings() }
                    .font(.caption)
            }

            HStack {
                Button("Atualizar aplicativos", systemImage: "arrow.clockwise") {
                    model.refresh()
                    interaction.reset()
                }
                SettingsLink { Label("Preferências", systemImage: "slider.horizontal.3") }
                Button("Exceções por aplicativo", systemImage: "hand.raised") {
                    showsExceptions = true
                }
            }
            .buttonStyle(.bordered)

            if let error = model.activationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if model.total > model.visibleRunningCount {
                Text("\(model.visibleRunningCount) de \(model.total) aplicativos abertos na roda.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 640, height: 800)
        .onAppear { interaction.diameter = previewDiameter }
        .onChange(of: previewDiameter) { _, diameter in
            interaction.reset()
            interaction.diameter = diameter
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            interaction.reset()
        }
        .sheet(isPresented: $showsExceptions) {
            AppExceptionsView(exceptions: gesture.exceptions)
        }
        .background {
            LinearGradient(
                colors: [.blue.opacity(0.12), .clear, .mint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }


    private func select(at point: CGPoint) {
        interaction.diameter = previewDiameter
        interaction.update(at: point, slots: model.slots, allowsBeyondEdge: false)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(preferences: WheelPreferences()).environmentObject(GestureController())
    }
}
