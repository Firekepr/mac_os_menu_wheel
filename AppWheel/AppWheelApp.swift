import SwiftUI

@main
struct AppWheelApp: App {
    @StateObject private var gesture = GestureController()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(gesture)
        }
        .defaultSize(width: 640, height: 800)
        .windowResizability(.contentSize)
        MenuBarExtra("AppWheel", systemImage: "circle.hexagongrid.fill") {
            Button(gesture.isEnabled ? "Desativar gesto" : "Ativar gesto global") {
                if gesture.isEnabled { gesture.stop() } else { gesture.start() }
            }
            Button("Prévia flutuante") { gesture.preview() }
            Divider()
            Button("Sair do AppWheel") {
                gesture.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
