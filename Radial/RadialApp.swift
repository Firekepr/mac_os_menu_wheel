import SwiftUI

@main
struct RadialApp: App {
    @StateObject private var gesture = GestureController()

    var body: some Scene {
        Settings {
            AppSettingsView(preferences: gesture.preferences, favorites: gesture.favorites)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("Abrir Radial")) { gesture.openMainWindow() }
            }
        }
        MenuBarExtra("Radial", systemImage: "circle.hexagongrid.fill") {
            Button(L10n.text("Abrir Radial")) { gesture.openMainWindow() }
            Divider()
            Button(gesture.isEnabled ? L10n.text("Desativar gesto") : L10n.text("Ativar gesto global")) {
                if gesture.isEnabled { gesture.stop() } else { gesture.start() }
            }
            Button(L10n.text("Prévia flutuante")) { gesture.preview() }
            SettingsLink { Text(L10n.text("Preferências…")) }
            Divider()
            Button(L10n.text("Sair do Radial")) {
                gesture.shutDown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

private struct AppSettingsView: View {
    let preferences: WheelPreferences
    let favorites: AppFavorites
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WheelPreferencesView(preferences: preferences)
                .tabItem { Label(L10n.text("Geral"), systemImage: "slider.horizontal.3") }
                .tag(0)
            AppFavoritesView(favorites: favorites)
                .tabItem { Label(L10n.text("Favoritos"), systemImage: "star") }
                .tag(1)
            AppActionSettingsView(preferences: preferences.appActions)
                .tabItem { Label(L10n.text("Ações por aplicativo"), systemImage: "bolt.circle") }
                .tag(2)
        }
        .frame(width: 600, height: selectedTab == 0 ? 640 : 620)
    }
}
