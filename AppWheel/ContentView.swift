import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var gesture: GestureController
    @ObservedObject var preferences: WheelPreferences
    @StateObject private var model: RunningApps
    @State private var selectedID: String?
    @State private var showsExceptions = false

    init(preferences: WheelPreferences, favorites: AppFavorites? = nil) {
        self.preferences = preferences
        _model = StateObject(wrappedValue: RunningApps(favorites: favorites))
    }

    private var previewDiameter: CGFloat { min(CGFloat(preferences.wheelDiameter), 400) }

    private var selected: WheelApp? {
        model.apps.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("AppWheel")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Seus aplicativos, a um gesto de distância.")
                    .foregroundStyle(.secondary)
            }

            WheelView(model: model, selectedID: selectedID)
                .scaleEffect(previewDiameter / WheelGeometry.size)
                .frame(width: previewDiameter, height: previewDiameter)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): select(at: point)
                    case .ended: selectedID = nil
                    }
                }
                .onTapGesture { location in
                    select(at: location)
                    if let selected { model.activate(selected) }
                }

            VStack(spacing: 7) {
                Text("Prévia interativa")
                    .font(.headline)
                Text("Passe o mouse pela roda e clique para trocar de app.")
                Text(preferences.gestureHint + " Centro ou Esc para cancelar.")
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
                    selectedID = nil
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
        selectedID = WheelGeometry.index(at: point, count: model.slots.count, allowsBeyondEdge: false, diameter: previewDiameter)
            .flatMap { model.slots[$0].app?.id }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(preferences: WheelPreferences()).environmentObject(GestureController())
    }
}
