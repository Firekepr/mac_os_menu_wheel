import AppKit

/// Native bundle localization uses macOS preferred languages and falls back to
/// the project's English development language. Overrides apply on next launch.
enum L10n {
    static func text(_ key: String, _ arguments: String...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", portuguese = "pt"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("Seguir o sistema")
        case .english: return "English"
        case .portuguese: return "Português"
        }
    }
}

@MainActor
enum AppRelaunch {
    static func restart() async throws {
        // Persist the language before the new process reads its preferences.
        UserDefaults.standard.synchronize()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let replacement = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration)
        // Keep the current app working if Launch Services reused this process.
        guard replacement.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw RelaunchError()
        }
        // The normal termination handler releases the gesture without clearing
        // its saved enabled state. Only quit after the replacement has launched.
        NSApplication.shared.terminate(nil)
    }

    private struct RelaunchError: LocalizedError {
        var errorDescription: String? {
            L10n.text("O macOS não conseguiu abrir uma nova instância do AppWheel.")
        }
    }
}
