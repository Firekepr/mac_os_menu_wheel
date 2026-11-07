import SwiftUI

@main
struct AppWheelApp: App {
    @StateObject private var gesture = GestureController()

    var body: some Scene {
        WindowGroup {
            ContentView(preferences: gesture.preferences).environmentObject(gesture)
        }
        .defaultSize(width: 640, height: 800)
        .windowResizability(.contentSize)
        Settings {
            WheelPreferencesView(preferences: gesture.preferences)
        }
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
