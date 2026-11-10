import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var gesture: GestureController
    @ObservedObject var preferences: WheelPreferences
    @StateObject private var model: RunningApps
    @StateObject private var interaction = WheelInteraction()
    @State private var showsExceptions = false

    init(preferences: WheelPreferences, favorites: AppFavorites? = nil) {
        self.preferences = preferences
        _model = StateObject(wrappedValue: RunningApps(favorites: favorites, capacity: preferences.wheelCapacity,
                                                         actionPreferences: preferences.appActions))
    }

    private var previewDiameter: CGFloat { min(CGFloat(preferences.wheelDiameter), 280) }

    private var selected: WheelApp? {
        model.apps.first { $0.id == interaction.id }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Radial")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(L10n.text("Seus aplicativos, a um gesto de distância."))
                    .foregroundStyle(.secondary)
            }

            WheelWithActions(model: model, interaction: interaction,
                             showsMemoryUsage: preferences.showsMemoryUsage, theme: preferences.theme, isMainWindowOpen: true)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): select(at: point)
                    case .ended: interaction.reset()
                    }
                }
                .onTapGesture { location in
                    if interaction.changeWindowPage(at: location, slots: model.slots) { return }
                    select(at: location)
                    if interaction.isChoosingWindow {
                        if let (window, action) = interaction.windowChoice { model.perform(action, on: window) }
                    } else if interaction.isOpenMainWindowHovered {
                        gesture.toggleMainWindow()
                    } else if let action = interaction.hoveredScriptAction, let selected {
                        model.perform(action, on: selected)
                    } else if interaction.isCloseHovered,
                       let target = model.apps.first(where: { $0.id == interaction.closeTargetID }) {
                        model.requestQuit(target)
                    } else if let selected { model.activate(selected) }
                    interaction.reset()
                }

            VStack(spacing: 7) {
                Text(L10n.text("Prévia interativa"))
                    .font(.headline)
                Text(L10n.text("Clique para trocar de app. Pause sobre um app para revelar a ação de fechar."))
                Text(preferences.gestureHint + L10n.text(" Centro superior ou Esc para cancelar."))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(gesture.isEnabled ? L10n.text("Desativar gesto") : L10n.text("Ativar gesto global")) {
                    if gesture.isEnabled { gesture.stop() } else { gesture.start() }
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.text("Prévia flutuante")) { gesture.preview() }
                    .buttonStyle(.bordered)
            }
            Text(gesture.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if gesture.needsPermission {
                Button(L10n.text("Abrir ajustes de Acessibilidade")) { gesture.openAccessibilitySettings() }
                    .font(.caption)
            }

            HStack {
                Button(L10n.text("Atualizar aplicativos"), systemImage: "arrow.clockwise") {
                    model.refresh()
                    interaction.reset()
                }
                SettingsLink { Label(L10n.text("Preferências"), systemImage: "slider.horizontal.3") }
                Button(L10n.text("Exceções por aplicativo"), systemImage: "hand.raised") {
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

            if model.pageCount > 1 {
                HStack {
                    Button {
                        changePage(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(L10n.text("Página anterior"))
                    .disabled(model.pageIndex == 0)

                    Text(L10n.text("Página %@ de %@", String(model.pageIndex + 1), String(model.pageCount)))
                        .font(.caption).monospacedDigit()

                    Button {
                        changePage(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel(L10n.text("Próxima página"))
                    .disabled(model.pageIndex + 1 == model.pageCount)
                }
            }
        }
        .padding(32)
        .frame(width: 640, height: 800)
        .overlay(alignment: .bottom) {
            HStack {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text(verbatim: "v\(version)")
                }
                Spacer()
                Text(verbatim: "by Firekeper")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(16)
            .allowsHitTesting(false)
        }
        .onAppear { interaction.diameter = previewDiameter }
        .onChange(of: preferences.wheelCapacity) { _, capacity in
            model.refresh(capacity: capacity)
            interaction.reset()
        }
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


    private func changePage(by step: Int) {
        if model.movePage(by: step) { interaction.reset() }
    }

    private func select(at point: CGPoint) {
        interaction.diameter = previewDiameter
        interaction.update(at: point, slots: model.slots, allowsBeyondEdge: false, actionDelay: preferences.actionDelay)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(preferences: WheelPreferences()).environmentObject(GestureController())
    }
}
