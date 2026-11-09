import AppKit
import SwiftUI
import Combine

struct WheelApp: Identifiable {
    let application: NSRunningApplication?
    var favorite: FavoriteApp? = nil
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

struct WheelSlot: Identifiable {
    let id: Int
    let app: WheelApp?
}

@MainActor
final class RunningApps: ObservableObject {
    @Published private(set) var slots: [WheelSlot] = []
    var apps: [WheelApp] { slots.compactMap(\.app) }
    var visibleRunningCount: Int { apps.filter { $0.application != nil }.count }
    private let favorites: AppFavorites
    private var favoritesSubscription: AnyCancellable?
    private var workspaceSubscription: AnyCancellable?
    @Published private(set) var runningApplicationIDs: Set<String> = []
    @Published private(set) var total = 0
    @Published private(set) var activationError: String?

    init(favorites: AppFavorites? = nil, observesFavorites: Bool = true) {
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

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        var seen = Set<String>()
        let entries = running.map { WheelApp(application: $0) }.filter { seen.insert($0.id).inserted }
        let ids = Set(entries.map(\.id))
        if runningApplicationIDs != ids { runningApplicationIDs = ids }
        total = entries.count
        let pinned = Dictionary(uniqueKeysWithValues: favorites.apps.map { ($0.position, $0.id) })
        let conditional = Set(favorites.apps.filter { $0.visibility == .whenRunning }.map(\.id))
        let identifiers = FavoriteLayout.arrange(runningIDs: entries.map(\.id), favorites: pinned, onlyWhenRunning: conditional)
        slots = identifiers.enumerated().map { position, id in
            guard let id else { return WheelSlot(id: position, app: nil) }
            let favorite = favorites.apps.first { $0.id == id }
            let app = entries.first { $0.id == id }.map { entry -> WheelApp in
                var entry = entry
                entry.favorite = favorite
                return entry
            } ?? favorite.map { WheelApp(application: nil, favorite: $0) }
            return WheelSlot(id: position, app: app)
        }
    }

    func isRunning(_ app: WheelApp) -> Bool { runningApplicationIDs.contains(app.id) }

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
