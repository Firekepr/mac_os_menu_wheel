import AppKit
import ApplicationServices
import SwiftUI
import Combine

struct WheelApp: Identifiable {
    let application: NSRunningApplication?
    var favorite: FavoriteApp? = nil
    var scriptActions: [AppScriptAction] = []
    var id: String { favorite?.id ?? application?.bundleIdentifier ?? application?.bundleURL?.path ?? "pid:\(application?.processIdentifier ?? -1)" }
    var name: String { application?.localizedName ?? favorite?.name ?? L10n.text("Aplicativo") }
    var isQuitProtected: Bool {
        application?.bundleIdentifier == "com.apple.finder" || favorite?.id == "com.apple.finder"
    }
    var canRequestQuit: Bool { !isQuitProtected && application?.isTerminated == false }
    var url: URL? {
        if let url = application?.bundleURL { return url }
        guard let favorite else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: favorite.id)
            ?? URL(fileURLWithPath: favorite.path)
    }
    var icon: NSImage {
        application?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)!
    }
}

// AX references are immutable handles. All queries and actions run on the AX queue.
struct WheelWindow: Identifiable, @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    let title: String
    let element: AXUIElement
    let closeButton: AXUIElement?
    let scriptActions: [AppScriptAction]

    var actions: [WindowAction] {
        scriptActions.map(WindowAction.script) + (closeButton == nil ? [] : [.close])
    }
}

enum WindowAction: Equatable {
    case open
    case close
    case script(AppScriptAction)

    var title: String {
        switch self {
        case .open: L10n.text("Abrir")
        case .close: L10n.text("Fechar janela")
        case .script(let action): L10n.text(action.title)
        }
    }

    var symbol: String {
        switch self {
        case .open: "macwindow"
        case .close: "xmark.circle.fill"
        case .script(let action): action.symbol
        }
    }
}

enum AppWindows {
    private static let queue = DispatchQueue(label: "AppWheel.AccessibilityWindows", qos: .userInitiated)

    @MainActor
    static func list(for app: WheelApp) async -> [WheelWindow] {
        guard AXIsProcessTrusted(), app.application != nil else { return [] }
        let processes = NSWorkspace.shared.runningApplications.compactMap { application -> (pid_t, [AppScriptAction])? in
            guard !application.isTerminated, WheelApp(application: application).id == app.id else { return nil }
            let actions = application.processIdentifier == app.application?.processIdentifier
                ? app.scriptActions : AppScriptActions.discover(in: application)
            return (application.processIdentifier, actions)
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                var windows: [WheelWindow] = []
                for (pid, actions) in processes {
                    let application = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(application, 0.35)
                    let elements = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                    for element in elements {
                        if let subrole = attribute(element, kAXSubroleAttribute) as? String,
                           subrole != kAXStandardWindowSubrole && subrole != kAXUnknownSubrole { continue }
                        let title = (attribute(element, kAXTitleAttribute) as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let close = attribute(element, kAXCloseButtonAttribute)
                        let closeButton = close.flatMap { value in
                            CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
                        }
                        windows.append(WheelWindow(pid: pid, title: title, element: element,
                                                   closeButton: closeButton, scriptActions: actions))
                    }
                }
                continuation.resume(returning: windows)
            }
        }
    }

    static func perform(_ action: WindowAction, on window: WheelWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let succeeded: Bool
                if action == .close {
                    succeeded = window.closeButton.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
                } else {
                    let application = AXUIElementCreateApplication(window.pid)
                    AXUIElementSetMessagingTimeout(application, 0.5)
                    if attribute(window.element, kAXMinimizedAttribute) as? Bool == true {
                        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    succeeded = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}

struct WheelSlot: Identifiable {
    let id: Int
    let app: WheelApp?
}

@MainActor
final class RunningApps: ObservableObject {
    @Published private(set) var slots: [WheelSlot] = []
    var apps: [WheelApp] { slots.compactMap(\.app) }
    private var pages: [[WheelSlot]] = []
    private var capacity: WheelCapacity
    private(set) var pageIndex = 0
    private(set) var pageTurnDirection = 1
    private(set) var pageTurnRevision = 0
    var pageCount: Int { pages.count }
    private let favorites: AppFavorites
    private var favoritesSubscription: AnyCancellable?
    private var workspaceSubscription: AnyCancellable?
    @Published private(set) var runningApplicationIDs: Set<String> = []
    @Published private(set) var activationError: String?

    init(favorites: AppFavorites? = nil, observesFavorites: Bool = true, capacity: WheelCapacity = .eight) {
        self.capacity = capacity
        self.favorites = favorites ?? AppFavorites()
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        workspaceSubscription = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Update indicators without rearranging a wheel already in use.
                let ids = Set(NSWorkspace.shared.runningApplications
                    .filter { !$0.isTerminated && $0.activationPolicy == .regular
                        && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                    .map { WheelApp(application: $0).id })
                if self?.runningApplicationIDs != ids { self?.runningApplicationIDs = ids }
            }
        if observesFavorites {
            favoritesSubscription = self.favorites.$apps.sink { [weak self] _ in
                // Published sends before storage changes. Refresh the preview on the next turn.
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    func refresh(capacity: WheelCapacity? = nil) {
        if let capacity { self.capacity = capacity }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        var seen = Set<String>()
        let entries = running.map {
            WheelApp(application: $0, scriptActions: AppScriptActions.discover(in: $0))
        }.filter { seen.insert($0.id).inserted }
        let ids = Set(entries.map(\.id))
        if runningApplicationIDs != ids { runningApplicationIDs = ids }
        let pinned = Dictionary(uniqueKeysWithValues: favorites.apps.map { ($0.position, $0.id) })
        let conditional = Set(favorites.apps.filter { $0.visibility == .whenRunning }.map(\.id))
        let layouts = FavoriteLayout.pages(runningIDs: entries.map(\.id), favorites: pinned,
                                          onlyWhenRunning: conditional, capacity: self.capacity)
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let favoritesByID = Dictionary(uniqueKeysWithValues: favorites.apps.map { ($0.id, $0) })
        pages = layouts.map { identifiers in
            identifiers.enumerated().map { position, id in
                guard let id else { return WheelSlot(id: position, app: nil) }
                let favorite = favoritesByID[id]
                var app = entriesByID[id]
                if app != nil { app?.favorite = favorite }
                else if let favorite { app = WheelApp(application: nil, favorite: favorite) }
                return WheelSlot(id: position, app: app)
            }
        }
        pageIndex = 0
        slots = pages[pageIndex]
    }

    @discardableResult
    func movePage(by step: Int) -> Bool {
        let next = pageIndex + step
        guard pages.indices.contains(next), next != pageIndex else { return false }
        pageTurnDirection = step > 0 ? 1 : -1
        pageTurnRevision += 1
        pageIndex = next
        slots = pages[next]
        return true
    }

    func isRunning(_ app: WheelApp) -> Bool { runningApplicationIDs.contains(app.id) }

    func perform(_ action: AppScriptAction, on app: WheelApp, completion: ((String?) -> Void)? = nil) {
        guard let running = app.application, !running.isTerminated, app.scriptActions.contains(action) else {
            let message = L10n.text("A ação não está mais disponível para %@.", app.name)
            activationError = message
            completion?(message)
            return
        }
        let pid = running.processIdentifier
        activationError = nil
        Task {
            let message: String?
            do {
                try await AppScriptActions.send(action, to: pid)
                message = nil
            } catch let error as NSError {
                if error.domain == NSOSStatusErrorDomain && error.code == -1743 {
                    message = L10n.text("Autorize o AppWheel a controlar %@ em Privacidade e Segurança → Automação.", app.name)
                } else {
                    message = L10n.text("Não foi possível executar %@ em %@: %@.", L10n.text(action.title), app.name, error.localizedDescription)
                }
            }
            activationError = message
            completion?(message)
        }
    }

    @discardableResult
    func requestQuit(_ app: WheelApp,
                     isRunning: (NSRunningApplication) -> Bool = { !$0.isTerminated },
                     terminate: (NSRunningApplication) -> Bool = { $0.terminate() }) -> String? {
        guard !app.isQuitProtected else {
            let message = L10n.text("O Finder não pode ser fechado pelo AppWheel.")
            activationError = message
            return message
        }
        guard let running = app.application, isRunning(running) else {
            let message = L10n.text("%@ já está fechado.", app.name)
            activationError = message
            return message
        }
        guard terminate(running) else {
            let message = L10n.text("Não foi possível solicitar o encerramento de %@.", app.name)
            activationError = message
            return message
        }
        activationError = nil
        return nil
    }

    func perform(_ action: WindowAction, on window: WheelWindow, completion: ((String?) -> Void)? = nil) {
        activationError = nil
        Task {
            if case .script(let command) = action, !command.targetsActiveWorkspace {
                let running = NSRunningApplication(processIdentifier: window.pid)
                perform(command, on: WheelApp(application: running, scriptActions: window.scriptActions), completion: completion)
                return
            }
            let succeeded = await AppWindows.perform(action, on: window)
            if succeeded, case .script(let command) = action {
                let running = NSRunningApplication(processIdentifier: window.pid)
                perform(command, on: WheelApp(application: running, scriptActions: window.scriptActions), completion: completion)
                return
            }
            let error = succeeded ? nil : L10n.text("Não foi possível executar a ação na janela selecionada.")
            activationError = error
            completion?(error)
        }
    }

    func activate(_ app: WheelApp, completion: ((String?) -> Void)? = nil) {
        activationError = nil
        guard app.favorite?.visibility == .always || app.application.map({ !$0.isTerminated }) == true,
              let url = app.url, FileManager.default.fileExists(atPath: url.path) else {
            let message = L10n.text("%@ não está mais disponível. Atualize a lista de aplicativos.", app.name)
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
                    message = L10n.text("Não foi possível ativar %@: %@", app.name, error.localizedDescription)
                } else if running == nil {
                    message = L10n.text("O macOS não confirmou a ativação de %@.", app.name)
                } else {
                    message = nil
                }
                self?.activationError = message
                completion?(message)
            }
        }
    }
}
