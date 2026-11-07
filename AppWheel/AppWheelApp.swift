import SwiftUI

@main
struct AppWheelApp: App {
    @StateObject private var gesture = GestureController()

    var body: some Scene {
        WindowGroup {
            ContentView(preferences: gesture.preferences, favorites: gesture.favorites).environmentObject(gesture)
        }
        .defaultSize(width: 640, height: 800)
        .windowResizability(.contentSize)
        Settings {
            AppSettingsView(preferences: gesture.preferences, favorites: gesture.favorites)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("AppWheel", systemImage: "circle.hexagongrid.fill") {
            Button(gesture.isEnabled ? "Desativar gesto" : "Ativar gesto global") {
                if gesture.isEnabled { gesture.stop() } else { gesture.start() }
            }
            Button("Prévia flutuante") { gesture.preview() }
            SettingsLink { Text("Preferências…") }
            Divider()
            Button("Sair do AppWheel") {
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
                .tabItem { Label("Geral", systemImage: "slider.horizontal.3") }
                .tag(0)
            AppFavoritesView(favorites: favorites)
                .tabItem { Label("Favoritos", systemImage: "star") }
                .tag(1)
        }
        .frame(width: 600, height: selectedTab == 0 ? 410 : 620)
    }
}
