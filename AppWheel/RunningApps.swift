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
        application?.bundleIdentifier == AppScriptActions.finderID || favorite?.id == AppScriptActions.finderID
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
    static let braveBundleIdentifier = "com.brave.Browser"
    private static let queue = DispatchQueue(label: "AppWheel.AccessibilityWindows", qos: .userInitiated)

    static func braveHasAudibleTab(pid: pid_t) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                for window in windows {
                    guard let title = attribute(window, kAXTitleAttribute) as? String,
                          title.hasSuffix(" - Brave") else { continue }
                    if isBraveAudioLabel(String(title.dropLast(" - Brave".count))) {
                        continuation.resume(returning: true)
                        return
                    }
                }
                var pending = windows.reversed().map { ($0, 0) }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while let (element, depth) = pending.popLast(),
                      ProcessInfo.processInfo.systemUptime < deadline {
                    let role = attribute(element, kAXRoleAttribute) as? String
                    if role == kAXRadioButtonRole || role == "AXTab" {
                        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                        if labels.contains(where: { key in
                            guard let label = attribute(element, key) as? String else { return false }
                            return isBraveAudioLabel(label)
                        }) {
                            continuation.resume(returning: true)
                            return
                        }
                    }
                    // Browser chrome is outside the web area. Avoid inspecting page contents.
                    guard depth < 10, role != "AXWebArea", role != "AXTabPanel" else { continue }
                    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                }
                continuation.resume(returning: false)
            }
        }
    }

    private static func isBraveAudioLabel(_ label: String) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // The memory saver can append a size after Chromium's audio status.
        let status = label.replacingOccurrences(of: #":\s+[\d.,]+\s*(?:KB|MB|GB|TB)$"#,
                                                with: "", options: .regularExpression)
        return status.hasSuffix(" - Audio playing") || status.hasSuffix(" - Reprodução de áudio")
            || status.hasSuffix(" – áudio em reprodução") || status.hasSuffix(": reproducción de audio")
            || ["This tab is playing audio", "Esta guia está reproduzindo áudio",
                "Este separador está a reproduzir áudio", "Esta pestaña está reproduciendo audio"].contains(label)
    }

    @MainActor
    static func list(for app: WheelApp) async -> [WheelWindow] {
        guard AXIsProcessTrusted(), app.application != nil else { return [] }
        let isFinder = app.id == AppScriptActions.finderID
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
                        // Finder's desktop surface can appear in AXWindows.
                        if isFinder && closeButton == nil { continue }
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
    private var iconsByAppID: [String: NSImage] = [:]
    private var actionsByProcess: [pid_t: (application: NSRunningApplication, actions: [AppScriptAction])] = [:]
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
        iconsByAppID.removeAll(keepingCapacity: true)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        var seen = Set<String>()
        var currentActions: [pid_t: (application: NSRunningApplication, actions: [AppScriptAction])] = [:]
        let entries = running.compactMap { application -> WheelApp? in
            var entry = WheelApp(application: application)
            guard seen.insert(entry.id).inserted else { return nil }
            let pid = application.processIdentifier
            if let cached = actionsByProcess[pid], cached.application == application,
               cached.application.launchDate == application.launchDate, !cached.application.isTerminated {
                entry.scriptActions = cached.actions
            } else {
                entry.scriptActions = AppScriptActions.discover(in: application)
            }
            currentActions[pid] = (application, entry.scriptActions)
            return entry
        }
        actionsByProcess = currentActions
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

    func icon(for app: WheelApp) -> NSImage {
        if let icon = iconsByAppID[app.id] { return icon }
        let icon = app.icon
        iconsByAppID[app.id] = icon
        return icon
    }

    func perform(_ action: AppScriptAction, on app: WheelApp, completion: ((String?) -> Void)? = nil) {
        let authorizingBadge = action == AppScriptActions.authorizeMailBadge
        guard let running = app.application, !running.isTerminated,
              authorizingBadge ? running.bundleIdentifier == AppScriptActions.mailID : app.scriptActions.contains(action) else {
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
                if let folder = action.finderFolder, let finderURL = running.bundleURL {
                    let directory: URL
                    if folder == .userDirectory {
                        directory = FileManager.default.homeDirectoryForCurrentUser
                    } else {
                        directory = try FileManager.default.url(for: folder, in: .userDomainMask,
                                                                appropriateFor: nil, create: false)
                    }
                    let reusedWindow = folder == .downloadsDirectory
                        ? try await AppScriptActions.navigateFrontFinderWindow(to: directory, pid: pid)
                        : false
                    if !reusedWindow {
                        _ = try await NSWorkspace.shared.open([directory], withApplicationAt: finderURL,
                                                              configuration: NSWorkspace.OpenConfiguration())
                    }
                } else {
                    try await AppScriptActions.send(action, to: pid)
                }
                message = nil
            } catch let error as NSError {
                if error.domain == NSOSStatusErrorDomain && error.code == -1743 {
                    if authorizingBadge,
                       let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(settings)
                    }
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
