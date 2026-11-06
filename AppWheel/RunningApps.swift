import AppKit
import SwiftUI

struct WheelApp: Identifiable {
    let application: NSRunningApplication
    var id: pid_t { application.processIdentifier }
    var name: String { application.localizedName ?? "Aplicativo" }
    var icon: NSImage { application.icon ?? NSImage(named: NSImage.applicationIconName)! }
}

@MainActor
final class RunningApps: ObservableObject {
    @Published private(set) var apps: [WheelApp] = []
    @Published private(set) var total = 0
    @Published private(set) var activationError: String?

    init() { refresh() }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        total = running.count
        apps = running.prefix(8).map { WheelApp(application: $0) }
    }

    func activate(_ app: WheelApp, completion: ((String?) -> Void)? = nil) {
        activationError = nil
        guard !app.application.isTerminated, let url = app.application.bundleURL else {
            let message = "\(app.name) não está mais disponível. Atualize a lista de aplicativos."
            activationError = message
            completion?(message)
            return
        }

        // The global wheel intentionally leaves AppWheel in the background.
        // Route activation through Launch Services rather than relying on a
        // background NSRunningApplication.activate() request being honored.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] running, error in
            Task { @MainActor in
                let message: String?
                if let error {
                    message = "Não foi possível ativar \(app.name): \(error.localizedDescription)"
                } else if running == nil {
                    message = "O macOS não confirmou a ativação de \(app.name)."
                } else {
                    message = nil
                }
                self?.activationError = message
                completion?(message)
            }
        }
    }
}
