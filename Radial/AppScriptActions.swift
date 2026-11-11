import AppKit
import ApplicationServices
import Carbon
import SwiftUI

struct AppScriptAction: Equatable, Sendable {
    let title: String
    var symbol: String
    let eventClass: UInt32
    let eventID: UInt32
    var targetsActiveWorkspace = false
    var finderFolder: FileManager.SearchPathDirectory?
    var customTitle: String?
    var menuCommand: AppMenuCommand?

    var preferenceID: String {
        if let menuCommand { return menuCommand.id }
        if let finderFolder { return "folder-\(finderFolder.rawValue)" }
        return "event-\(eventClass)-\(eventID)"
    }

    var displayTitle: String { customTitle ?? menuCommand?.path.last ?? L10n.text(title) }
}

enum AppScriptActions {
    static let finderID = "com.apple.finder"
    private static let finderActions = [
        AppScriptAction(title: "Downloads", symbol: "arrow.down.to.line", eventClass: 0, eventID: 0,
                        finderFolder: .downloadsDirectory),
        AppScriptAction(title: "Pasta Pessoal", symbol: "house", eventClass: 0, eventID: 0,
                        finderFolder: .userDirectory)
    ]
    static let mailID = "com.apple.mail"
    static let authorizeMailBadge = AppScriptAction(title: "Autorizar badge do Mail", symbol: "exclamationmark.triangle.fill",
                                                    eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData))
    private static let eventQueue = DispatchQueue(label: "Radial.AppleEvents", qos: .userInitiated)
    private static let playbackQueue = DispatchQueue(label: "Radial.PlaybackState", qos: .utility)

    private static let playbackControls = [
        Control(command: "previous track", title: "Faixa anterior", symbol: "backward.end.fill"),
        Control(command: "playpause", title: "Reproduzir/Pausar", symbol: "playpause.fill"),
        Control(command: "next track", title: "Próxima faixa", symbol: "forward.end.fill")
    ]

    private static let playbackAppIDs: Set<String> = ["com.spotify.client", "com.apple.Music"]
    private static let xcodeID = "com.apple.dt.Xcode"
    private static let xcodeControls = [
        Control(command: "build", title: "Compilar", symbol: "hammer.fill"),
        Control(command: "run", title: "Executar", symbol: "play.fill"),
        Control(command: "test", title: "Testar", symbol: "checkmark.diamond.fill"),
        Control(command: "stop", title: "Parar", symbol: "stop.fill")
    ]
    private static let mailControls = [
        Control(command: "synchronize", title: "Sincronizar", symbol: "arrow.clockwise"),
        Control(command: "mailto", title: "Nova mensagem", symbol: "square.and.pencil")
    ]

    static func supportsPlaybackState(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map { playbackAppIDs.contains($0) } ?? false
    }

    private struct Control {
        let command: String
        let title: String
        let symbol: String
    }

    static var supportedBundleIDs: [String] {
        [finderID, mailID, xcodeID] + playbackAppIDs.sorted()
    }

    static func discover(in application: NSRunningApplication) -> [AppScriptAction] {
        guard let id = application.bundleIdentifier else { return [] }
        if id == finderID { return finderActions }
        return application.bundleURL.map { discover(bundleIdentifier: id, bundleURL: $0) } ?? []
    }

    static func discover(bundleIdentifier: String, bundleURL: URL) -> [AppScriptAction] {
        if bundleIdentifier == finderID { return finderActions }
        guard supportedBundleIDs.contains(bundleIdentifier),
              let bundle = Bundle(url: bundleURL),
              let definition = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let resources = bundle.resourceURL,
              let data = try? Data(contentsOf: resources.appendingPathComponent(definition)) else { return [] }
        return discover(in: data, bundleIdentifier: bundleIdentifier)
    }

    static func discover(in dictionary: Data, bundleIdentifier: String) -> [AppScriptAction] {
        let targetsWorkspace = bundleIdentifier == xcodeID
        let isMail = bundleIdentifier == mailID
        guard targetsWorkspace || isMail || supportsPlaybackState(bundleIdentifier),
              let document = try? XMLDocument(data: dictionary, options: .nodeLoadExternalEntitiesNever),
              let commands = try? document.nodes(forXPath: "/dictionary/suite/command") else { return [] }
        if targetsWorkspace {
            let path = "/dictionary/suite/class-extension[@extends='application']/property[@code='awks' and @type='workspace document']"
            guard let properties = try? document.nodes(forXPath: path), !properties.isEmpty else { return [] }
        }
        let profile = isMail ? mailControls : (targetsWorkspace ? xcodeControls : playbackControls)
        return profile.compactMap { entry in
            for case let command as XMLElement in commands {
                guard command.attribute(forName: "name")?.stringValue == entry.command,
                      let code = command.attribute(forName: "code")?.stringValue,
                      code.utf8.count == 8, code.utf8.allSatisfy({ (32...126).contains($0) }),
                      acceptsParameters(command, targetsWorkspace: targetsWorkspace, isMail: isMail) else { continue }
                let eventClass = code.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let eventID = code.utf8.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return AppScriptAction(title: entry.title, symbol: entry.symbol, eventClass: eventClass,
                                       eventID: eventID, targetsActiveWorkspace: targetsWorkspace)
            }
            return nil
        }
    }

    private static func acceptsParameters(_ command: XMLElement, targetsWorkspace: Bool, isMail: Bool) -> Bool {
        let parameters = (command.children ?? []).compactMap { $0 as? XMLElement }
        let direct = parameters.first { $0.name == "direct-parameter" }
        if isMail {
            switch command.attribute(forName: "code")?.stringValue {
            case "emalemto":
                return direct?.attribute(forName: "type")?.stringValue == "text"
            case "emalsyac":
                return parameters.contains {
                    $0.name == "parameter" && $0.attribute(forName: "code")?.stringValue == "acna"
                        && $0.attribute(forName: "type")?.stringValue == "account"
                }
            default:
                return false
            }
        }
        if targetsWorkspace {
            guard direct?.attribute(forName: "type")?.stringValue == "specifier" else { return false }
        } else if let direct, direct.attribute(forName: "optional")?.stringValue != "yes" {
            return false
        }
        return parameters.filter { $0.name == "parameter" }.allSatisfy {
            $0.attribute(forName: "optional")?.stringValue == "yes"
        }
    }

    static func send(_ action: AppScriptAction, to pid: pid_t) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            eventQueue.async {
                continuation.resume(with: Result { try sendEvent(action, to: pid) })
            }
        }
    }

    static func navigateFrontFinderWindow(to directory: URL, pid: pid_t) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventQueue.async {
                continuation.resume(with: Result {
                    guard let window = try firstFolderWindow(pid: pid) else { return false }
                    guard let target = property(0x66767467, of: window) else { // fvtg
                        throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
                    }

                    let event = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAESetData), pid: pid)
                    event.setParam(target, forKeyword: AEKeyword(keyDirectObject))
                    let folder = NSAppleEventDescriptor(fileURL: directory)
                    event.setParam(folder.coerce(toDescriptorType: DescType(typeAlias)) ?? folder,
                                   forKeyword: AEKeyword(keyAEData))
                    _ = try checkedReply(to: event)
                    let activate = makeEvent(eventClass: AEEventClass(kAEMiscStandards),
                                             eventID: AEEventID(kAEActivate), pid: pid)
                    _ = try checkedReply(to: activate)
                    return true
                })
            }
        }
    }

    private static func firstFolderWindow(pid: pid_t) throws -> NSAppleEventDescriptor? {
        var index: Int32 = 1
        while true {
            let descriptor = NSAppleEventDescriptor.record()
            descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: 0x62726F77),
                                     forKeyword: AEKeyword(keyAEDesiredClass)) // brow
            descriptor.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
            descriptor.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)),
                                     forKeyword: AEKeyword(keyAEKeyForm))
            descriptor.setDescriptor(NSAppleEventDescriptor(int32: index), forKeyword: AEKeyword(keyAEKeyData))
            guard let window = descriptor.coerce(toDescriptorType: DescType(typeObjectSpecifier)),
                  let closeable = property(0x68636C62, of: window) else { // hclb
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
            }
            let query = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), pid: pid)
            query.setParam(closeable, forKeyword: AEKeyword(keyDirectObject))
            do {
                let reply = try checkedReply(to: query)
                if reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.booleanValue == true {
                    return window
                }
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain
                && [Int(errAENoSuchObject), Int(errAEIllegalIndex)].contains(error.code) {
                return nil
            }
            // The desktop is a Finder window in the dictionary, but has no close box.
            index += 1
        }
    }

    static func isPlaying(pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            playbackQueue.async {
                continuation.resume(returning: readPlaybackState(pid: pid))
            }
        }
    }

    static func applicationProperty(_ code: OSType) -> NSAppleEventDescriptor? {
        property(code, of: .null())
    }

    private static func property(_ code: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return property.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private static func readPlaybackState(pid: pid_t) -> Bool {
        guard let specifier = applicationProperty(0x70506C53) else { return false } // pPlS
        return readProperty(specifier, pid: pid)?.enumCodeValue == 0x6B505350 // kPSP
    }

    static func unreadMailCount(pid: pid_t) async -> Int? {
        await withCheckedContinuation { continuation in
            playbackQueue.async {
                let count = unreadMailProperty().flatMap { readProperty($0, pid: pid) }?.int32Value
                continuation.resume(returning: count.map { max(0, Int($0)) })
            }
        }
    }

    static func mailBadgeNeedsAuthorization(pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            playbackQueue.async {
                let target = NSAppleEventDescriptor(processIdentifier: pid)
                guard let address = target.aeDesc else {
                    continuation.resume(returning: false)
                    return
                }
                let status = AEDeterminePermissionToAutomateTarget(
                    address, authorizeMailBadge.eventClass, authorizeMailBadge.eventID, false)
                continuation.resume(returning: status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent)
            }
        }
    }

    private static func unreadMailProperty() -> NSAppleEventDescriptor? {
        applicationProperty(0x696E6D62).flatMap { property(0x6D627563, of: $0) } // inmb, mbuc
    }

    private static func readProperty(_ specifier: NSAppleEventDescriptor, pid: pid_t) -> NSAppleEventDescriptor? {
        let event = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), pid: pid)
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        // The first explicit control action can request Automation permission.
        // Polling must stay silent when permission has not been granted.
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let address = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(address, event.eventClass, event.eventID, false) == noErr,
              let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.5),
              (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0 else { return nil }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    // Send the same Apple event that the dictionary maps the AppleScript verb to.
    // Target the running process so an action cannot reopen a closed app.
    private static func makeEvent(eventClass: AEEventClass, eventID: AEEventID, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                                          targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
    }

    private static func sendEvent(_ action: AppScriptAction, to pid: pid_t) throws {
        if action.eventClass == 0x656D616C, action.eventID == 0x73796163 { // emal, syac
            try synchronizeMail(pid: pid, action: action)
            return
        }
        let event = makeEvent(eventClass: action.eventClass, eventID: action.eventID, pid: pid)
        if action == authorizeMailBadge {
            guard let unread = unreadMailProperty() else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
            }
            event.setParam(unread, forKeyword: AEKeyword(keyDirectObject))
        } else if action.targetsActiveWorkspace {
            // Xcode resolves its active workspace when handling the command.
            guard let workspace = applicationProperty(0x61776B73) else { // awks
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
            }
            event.setParam(workspace, forKeyword: AEKeyword(keyDirectObject))
        } else if action.eventClass == 0x656D616C, action.eventID == 0x656D746F { // emal, emto
            event.setParam(NSAppleEventDescriptor(string: "mailto:"), forKeyword: AEKeyword(keyDirectObject))
        }
        _ = try checkedReply(to: event)
    }

    private static func synchronizeMail(pid: pid_t, action: AppScriptAction) throws {
        // "Every IMAP account" includes iCloud accounts, which inherit that class.
        let accounts = NSAppleEventDescriptor.record()
        accounts.setDescriptor(NSAppleEventDescriptor(typeCode: 0x69616374), forKeyword: AEKeyword(keyAEDesiredClass)) // iact
        accounts.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        accounts.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        let allCode = NSAppleEventDescriptor(typeCode: OSType(kAEAll))
        guard let all = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), data: allCode.data) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
        }
        accounts.setDescriptor(all, forKeyword: AEKeyword(keyAEKeyData))
        guard let specifier = accounts.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
        }
        let query = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), pid: pid)
        query.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        let result = try checkedReply(to: query).paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        guard let result, result.descriptorType == DescType(typeAEList), result.numberOfItems > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAENoSuchObject),
                          userInfo: [NSLocalizedDescriptionKey: L10n.text("Nenhuma conta IMAP para sincronizar.")])
        }
        var firstError: Error?
        for index in 1...result.numberOfItems {
            guard let account = result.atIndex(index) else { continue }
            let event = makeEvent(eventClass: action.eventClass, eventID: action.eventID, pid: pid)
            event.setParam(account, forKeyword: 0x61636E61) // acna
            do { _ = try checkedReply(to: event) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private static func checkedReply(to event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            let description = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(code),
                          userInfo: description.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
        }
        return reply
    }
}


struct AppMenuCommand: Codable, Hashable, Identifiable, Sendable {
    let path: [String]

    var id: String { "menu-" + path.map { "\($0.utf8.count):\($0)" }.joined() }
    var breadcrumb: String { path.joined(separator: " › ") }

    var action: AppScriptAction {
        AppScriptAction(title: path.last ?? "", symbol: "menubar.rectangle", eventClass: 0, eventID: 0,
                        menuCommand: self)
    }
}

enum AppMenuCommands {
    private static let queue = DispatchQueue(label: "Radial.AppMenuCommands", qos: .userInitiated)

    enum Failure: LocalizedError {
        case permission, appClosed, unavailable

        var errorDescription: String? {
            switch self {
            case .permission: L10n.text("Autorize o Radial em Acessibilidade para ler e executar comandos do menu.")
            case .appClosed: L10n.text("Abra o aplicativo para consultar os comandos do menu.")
            case .unavailable: L10n.text("Esse comando não está disponível no menu atual do aplicativo.")
            }
        }
    }

    static func discover(pid: pid_t, appID: String) async throws -> [AppMenuCommand] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    let menuBar = try menuBar(pid: pid, appID: appID)
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    var commands: [AppMenuCommand] = []

                    func walk(_ items: [AXUIElement], path: [String]) {
                        guard path.count < 8 else { return }
                        let entries = titled(items, deadline: deadline)
                        let counts = Dictionary(grouping: entries, by: \.title).mapValues(\.count)
                        for entry in entries {
                            guard commands.count < 400, ProcessInfo.processInfo.systemUptime < deadline else { break }
                            guard counts[entry.title] == 1 else { continue }
                            if path.isEmpty, appID != AppScriptActions.finderID {
                                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                if title == "Apple" || title == "" { continue }
                            }
                            let next = path + [entry.title]
                            let children = children(of: entry.element)
                            if children.isEmpty {
                                if path.count > 0, role(of: entry.element) == kAXMenuItemRole {
                                    commands.append(AppMenuCommand(path: next))
                                }
                            } else {
                                walk(menuItems(in: children), path: next)
                            }
                        }
                    }

                    walk(children(of: menuBar), path: [])
                    return commands
                })
            }
        }
    }

    static func perform(_ command: AppMenuCommand, pid: pid_t, appID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    guard (2...8).contains(command.path.count) else { throw Failure.unavailable }
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    var element = try menuBar(pid: pid, appID: appID)
                    for title in command.path {
                        let entries = titled(menuItems(in: children(of: element)), deadline: deadline)
                        let matches = entries.filter { $0.title == title }
                        guard matches.count == 1, let match = matches.first else { throw Failure.unavailable }
                        element = match.element
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline,
                          role(of: element) == kAXMenuItemRole, children(of: element).isEmpty,
                          attribute(element, kAXEnabledAttribute) as? Bool == true,
                          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == appID,
                          AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                        throw Failure.unavailable
                    }
                })
            }
        }
    }

    private static func menuBar(pid: pid_t, appID: String) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == appID else { throw Failure.appClosed }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard let value = attribute(element, kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unavailable }
        return value as! AXUIElement
    }

    private static func titled(_ elements: [AXUIElement], deadline: TimeInterval) -> [(element: AXUIElement, title: String)] {
        var entries: [(AXUIElement, String)] = []
        guard elements.count <= 400 else { return [] }
        for element in elements {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            guard let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
            entries.append((element, title))
        }
        return entries
    }

    private static func menuItems(in elements: [AXUIElement]) -> [AXUIElement] {
        guard let first = elements.first, role(of: first) == kAXMenuRole else { return elements }
        return elements.prefix(8).flatMap { children(of: $0) }
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

struct AppActionPreference: Codable, Identifiable {
    let id: String
    var isVisible = true
    var title = ""
    var symbol = ""
    var menuCommand: AppMenuCommand?
}

@MainActor
final class AppActionPreferences: ObservableObject {
    static let visibleLimit = 5
    private let defaults: UserDefaults
    private let key = "appActionProfiles"
    @Published private(set) var profiles: [String: [AppActionPreference]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: [AppActionPreference]].self, from: $0) } ?? [:]
    }

    func rows(for appID: String, actions: [AppScriptAction]) -> [AppActionPreference] {
        let ids = Set(actions.map(\.preferenceID))
        var seen = Set<String>()
        let saved = (profiles[appID] ?? []).filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        return saved + actions.compactMap { action in
            seen.insert(action.preferenceID).inserted ? AppActionPreference(id: action.preferenceID) : nil
        }
    }

    func availableActions(for appID: String, builtIn: [AppScriptAction]) -> [AppScriptAction] {
        builtIn + (profiles[appID] ?? []).compactMap { $0.menuCommand?.action }
    }

    func importCommand(_ command: AppMenuCommand, for appID: String, builtIn: [AppScriptAction]) {
        var rows = rows(for: appID, actions: availableActions(for: appID, builtIn: builtIn))
        guard !rows.contains(where: { $0.id == command.id }) else { return }
        let hasSpace = rows.lazy.filter(\.isVisible).count < Self.visibleLimit
        rows.append(AppActionPreference(id: command.id, isVisible: hasSpace, menuCommand: command))
        save(rows, for: appID)
    }

    func removeCommand(_ command: AppMenuCommand, for appID: String) {
        guard var rows = profiles[appID] else { return }
        rows.removeAll { $0.menuCommand == command }
        save(rows, for: appID)
    }

    func apply(to builtIn: [AppScriptAction], appID: String) -> [AppScriptAction] {
        let actions = availableActions(for: appID, builtIn: builtIn)
        let visible = rows(for: appID, actions: actions).lazy.filter(\.isVisible).prefix(Self.visibleLimit)
        return visible.compactMap { row in
            guard var action = actions.first(where: { $0.preferenceID == row.id }) else { return nil }
            let name = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            action.customTitle = name.isEmpty ? nil : name
            if !row.symbol.isEmpty, NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) != nil {
                action.symbol = row.symbol
            }
            return action
        }
    }

    func save(_ rows: [AppActionPreference], for appID: String) {
        profiles[appID] = rows
        persist()
    }

    func reset(_ appID: String) {
        profiles.removeValue(forKey: appID)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: key) }
    }
}

struct AppActionSettingsView: View {
    private struct Application: Identifiable {
        let id: String
        let name: String
        let builtIn: [AppScriptAction]
        let pid: pid_t?
    }

    private let icons = [
        (symbol: "bolt.fill", title: "Raio"),
        (symbol: "star.fill", title: "Estrela"),
        (symbol: "play.fill", title: "Reproduzir"),
        (symbol: "pause.fill", title: "Pausar"),
        (symbol: "forward.fill", title: "Avançar"),
        (symbol: "hammer.fill", title: "Martelo"),
        (symbol: "checkmark.circle.fill", title: "Confirmação"),
        (symbol: "folder.fill", title: "Pasta"),
        (symbol: "envelope.fill", title: "Envelope"),
        (symbol: "magnifyingglass", title: "Busca"),
        (symbol: "pencil", title: "Lápis"),
        (symbol: "scissors", title: "Tesoura"),
        (symbol: "doc.on.doc", title: "Copiar"),
        (symbol: "clipboard", title: "Área de transferência"),
        (symbol: "arrow.uturn.backward", title: "Desfazer"),
        (symbol: "arrow.uturn.forward", title: "Refazer"),
        (symbol: "trash", title: "Lixeira"),
        (symbol: "plus.circle", title: "Adicionar item"),
        (symbol: "minus.circle", title: "Remover item"),
        (symbol: "doc.text", title: "Documento"),
        (symbol: "tray.and.arrow.down", title: "Salvar arquivo"),
        (symbol: "arrow.down.circle", title: "Baixar"),
        (symbol: "arrow.up.circle", title: "Carregar arquivo"),
        (symbol: "square.and.arrow.up", title: "Compartilhar"),
        (symbol: "link", title: "Link"),
        (symbol: "bookmark", title: "Marcador"),
        (symbol: "printer", title: "Impressora"),
        (symbol: "macwindow", title: "Janela do app"),
        (symbol: "sidebar.left", title: "Barra lateral"),
        (symbol: "arrow.clockwise", title: "Atualizar"),
        (symbol: "arrow.left", title: "Seta para a esquerda"),
        (symbol: "arrow.right", title: "Seta para a direita"),
        (symbol: "gearshape", title: "Engrenagem"),
        (symbol: "terminal", title: "Terminal"),
        (symbol: "camera", title: "Câmera"),
        (symbol: "photo", title: "Imagem"),
        (symbol: "mic", title: "Microfone"),
        (symbol: "speaker.wave.2.fill", title: "Alto-falante"),
        (symbol: "speaker.slash.fill", title: "Silenciar"),
        (symbol: "backward.fill", title: "Retroceder"),
        (symbol: "stop.fill", title: "Parar reprodução")
    ]
    @ObservedObject var preferences: AppActionPreferences
    let capacity: WheelCapacity
    let theme: WheelTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var wheelApps: RunningApps
    @State private var closedApplications: [Application] = []
    @State private var selectedID: String?
    @State private var revealedAppID: String?
    @State private var page = 0
    @State private var importTarget: Application?
    @State private var editing = false

    init(preferences: AppActionPreferences, favorites: AppFavorites, capacity: WheelCapacity, theme: WheelTheme) {
        self.preferences = preferences
        self.capacity = capacity
        self.theme = theme
        _wheelApps = StateObject(wrappedValue: RunningApps(favorites: favorites, capacity: capacity,
                                                          actionPreferences: preferences))
    }

    private var pageCount: Int { wheelApps.pageCount }
    private var pageSlots: [WheelSlot] {
        wheelApps.pages.indices.contains(page) ? wheelApps.pages[page] : []
    }
    private var layoutIDs: [[String?]] { wheelApps.pages.map { $0.map { $0.app?.id } } }
    private var hasWheelApps: Bool { wheelApps.pages.contains { $0.contains { $0.app != nil } } }
    private var selectedWheelApp: WheelApp? {
        wheelApps.pages.lazy.flatMap { $0 }.first { $0.app?.id == selectedID }?.app
    }
    private var selectedApp: Application? {
        guard let selectedID else { return nil }
        if let app = selectedWheelApp {
            let builtIn = app.url.map { AppScriptActions.discover(bundleIdentifier: app.id, bundleURL: $0) } ?? []
            return Application(id: app.id, name: app.name, builtIn: builtIn, pid: app.application?.processIdentifier)
        }
        return closedApplications.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 14) {
            if selectedApp != nil {
                HStack {
                    Button { selectedID = nil } label: {
                        Label(L10n.text("Voltar para a roda"), systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            } else {
                Text(L10n.text("Escolha quais ações aparecem na roda e personalize a ordem, o nome e o ícone."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if hasWheelApps, selectedApp == nil || selectedWheelApp != nil {
                wheel
            } else if selectedApp == nil {
                Text(L10n.text("Nenhum aplicativo aberto."))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }

            if let app = selectedApp {
                actionPreview(for: app)
            } else {
                HStack {
                    if pageCount > 1 {
                        Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0)
                            .accessibilityLabel(L10n.text("Página anterior"))
                        Text("\(page + 1) / \(pageCount)").monospacedDigit()
                        Button { page += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(page + 1 >= pageCount)
                            .accessibilityLabel(L10n.text("Próxima página"))
                    }
                    let closedApps = closedApplications.filter { app in !layoutIDs.contains { $0.contains(app.id) } }
                    if !closedApps.isEmpty {
                        Menu(L10n.text("Apps fechados")) {
                            ForEach(closedApps) { app in
                                Button(app.name) { selectedID = app.id }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { refreshApplications() }
        .task(id: selectedID) {
            revealedAppID = nil
            guard let selectedID else { return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(280)) }
                catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                revealedAppID = selectedID
            }
        }
        .onChange(of: capacity) { _, _ in refreshApplications() }
        .onChange(of: layoutIDs) { _, _ in updatePage() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApplications()
        }
        .sheet(isPresented: $editing) {
            if let app = selectedApp { actionEditor(for: app) }
        }
        .sheet(item: $importTarget) { app in
            if let pid = app.pid {
                AppMenuImportView(appID: app.id, name: app.name, pid: pid,
                                  builtIn: app.builtIn, preferences: preferences)
            }
        }
    }

    private var wheel: some View {
        let diameter: CGFloat = 320
        let wheelScale = diameter / WheelGeometry.size
        let radius = diameter * 0.35
        let focusedIndex = pageSlots.first { $0.app != nil && $0.app?.id == selectedID }?.id
        let zoom: CGFloat = focusedIndex == nil || reduceMotion ? 1 : 1.6
        let zoomedDiameter = diameter * zoom
        let outerRadius = WheelActionGeometry.outerSize(diameter: zoomedDiameter) / 2
        let focusRadius = (radius * zoom + outerRadius) / 2
        let offset = focusedIndex.map { sectorOffset($0, radius: -focusRadius) } ?? .zero
        let iconSize = 36 * zoom

        return WheelSurface(theme: theme, diameter: diameter) {
            ForEach(pageSlots) { slot in
                let index = slot.id
                let sector = WheelSector(index: index, count: pageSlots.count, innerRadius: 77 * wheelScale)
                let app = slot.app
                let active = focusedIndex == index
                Button {
                    guard let app else { return }
                    selectedID = active ? nil : app.id
                } label: {
                    WheelSectorDecoration(sector: sector, diameter: diameter, theme: theme, selected: active)
                        .contentShape(sector)
                }
                .buttonStyle(.plain)
                .disabled(app == nil)
                .opacity(focusedIndex == nil || active ? 1 : 0.3)
                .accessibilityLabel(app?.name ?? "")
                .accessibilityHidden(app == nil)
                .accessibilityAddTraits(active ? .isSelected : [])
                .help(app?.name ?? "")
            }
        } center: {
            WheelCenterBackdrop(theme: theme)
                .frame(width: WheelGeometry.centerDiameter * wheelScale,
                       height: WheelGeometry.centerDiameter * wheelScale)
                .overlay {
                    if focusedIndex == nil {
                        Text(L10n.text("Escolha um app"))
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                }
                .allowsHitTesting(false)
        }
        .scaleEffect(zoom)
        .offset(offset)
        .overlay {
            ZStack {
                ForEach(pageSlots) { slot in
                    if let app = slot.app {
                        Image(nsImage: wheelApps.icon(for: app))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: iconSize, height: iconSize)
                            .overlay(alignment: .bottomTrailing) {
                                if app.favorite != nil { FavoriteAppBadge() }
                            }
                            .modifier(SelectedIconFloat(isSelected: focusedIndex == slot.id))
                            .overlay(alignment: .bottom) {
                                if app.favorite != nil && wheelApps.isRunning(app) {
                                    RunningAppIndicator().offset(y: 8)
                                }
                            }
                            .offset(sectorOffset(slot.id, radius: radius * zoom))
                            .opacity(focusedIndex == nil || focusedIndex == slot.id ? 1 : 0.3)
                    }
                }
            }
            .offset(offset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay {
            if let index = focusedIndex, let app = selectedWheelApp, revealedAppID == app.id {
                actionSectors(for: app, at: index, diameter: zoomedDiameter)
                    .environment(\.colorScheme, theme.usesDarkAppearance ? .dark : colorScheme)
                    .offset(offset)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: focusedIndex == nil ? diameter : 360)
        .clipped()
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedID)
    }

    private func actionSectors(for app: WheelApp, at index: Int, diameter: CGFloat) -> some View {
        let actions = app.scriptActions.map(Optional.some) + (app.canRequestQuit ? [nil] : [])
        return ZStack {
            ForEach(actions.indices, id: \.self) { part in
                let action = actions[part]
                AppActionSector(diameter: diameter, index: index, count: pageSlots.count,
                                part: part, parts: actions.count, action: action, theme: theme)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(action?.displayTitle ?? L10n.text("Fechar %@", app.name))
            }
        }
        .allowsHitTesting(false)
    }

    private func sectorOffset(_ index: Int, radius: CGFloat) -> CGSize {
        let angle = WheelGeometry.angle(for: index, count: pageSlots.count)
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private func actionPreview(for app: Application) -> some View {
        let actions = preferences.apply(to: app.builtIn, appID: app.id)
        return VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(app.name).font(.headline)
                Text(L10n.text("Ações na roda: %@ de %@", String(actions.count), String(AppActionPreferences.visibleLimit)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if selectedWheelApp == nil, !actions.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(actions, id: \.preferenceID) { action in
                        VStack(spacing: 6) {
                            Image(systemName: action.symbol)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(.quaternary, in: Circle())
                            Text(action.displayTitle)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(action.displayTitle)
                        .help(action.displayTitle)
                    }
                }
            }
            HStack {
                Button { importTarget = app } label: {
                    Label(L10n.text("Importar do menu…"), systemImage: "plus")
                }
                .disabled(app.pid == nil || actions.count >= AppActionPreferences.visibleLimit)
                Button(L10n.text("Editar ações…")) { editing = true }
            }
            if app.pid == nil {
                Text(L10n.text("Abra o aplicativo para consultar os comandos do menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actionEditor(for app: Application) -> some View {
        let actions = availableActions(for: app)
        let rows = preferences.rows(for: app.id, actions: actions)
        let visibleCount = rows.lazy.filter(\.isVisible).count

        return VStack(alignment: .leading, spacing: 12) {
            Text(app.name).font(.title2.bold())
            Form {
                Section {
                    Text(L10n.text("Até %@ ações visíveis por aplicativo.", String(AppActionPreferences.visibleLimit)))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if let action = actions.first(where: { $0.preferenceID == row.id }) {
                            actionRow(app: app, action: action, index: index, count: rows.count,
                                      canToggle: row.isVisible || visibleCount < AppActionPreferences.visibleLimit)
                        }
                    }
                    Button(L10n.text("Restaurar ações padrão")) { preferences.reset(app.id) }
                        .disabled(preferences.profiles[app.id] == nil)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.text("Concluído")) { editing = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }

    private func availableActions(for app: Application) -> [AppScriptAction] {
        preferences.availableActions(for: app.id, builtIn: app.builtIn)
    }

    private func actionRow(app: Application, action: AppScriptAction, index: Int, count: Int,
                           canToggle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(action.displayTitle, isOn: binding(\.isVisible, app: app, action: action))
                    .disabled(!canToggle)
                Spacer()
                Button { move(app, from: index, to: index - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel(L10n.text("Mover ação para cima"))
                Button { move(app, from: index, to: index + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index + 1 == count)
                    .accessibilityLabel(L10n.text("Mover ação para baixo"))
            }
            if let command = action.menuCommand {
                Text(command.breadcrumb)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(L10n.text("Nome personalizado"), text: binding(\.title, app: app, action: action),
                          prompt: Text(action.displayTitle))
                Picker(L10n.text("Ícone"), selection: binding(\.symbol, app: app, action: action)) {
                    Label(L10n.text("Padrão"), systemImage: action.symbol).tag("")
                    ForEach(icons, id: \.symbol) { icon in
                        Label(L10n.text(icon.title), systemImage: icon.symbol).tag(icon.symbol)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Ícone"))
                if let command = action.menuCommand {
                    Button(role: .destructive) {
                        preferences.removeCommand(command, for: app.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L10n.text("Remover comando importado"))
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppActionPreference, Value>,
                                app: Application, action: AppScriptAction) -> Binding<Value> {
        Binding {
            let row = preferences.rows(for: app.id, actions: availableActions(for: app)).first { $0.id == action.preferenceID }
            return (row ?? AppActionPreference(id: action.preferenceID))[keyPath: keyPath]
        } set: { value in
            var rows = preferences.rows(for: app.id, actions: availableActions(for: app))
            guard let index = rows.firstIndex(where: { $0.id == action.preferenceID }) else { return }
            rows[index][keyPath: keyPath] = value
            preferences.save(rows, for: app.id)
        }
    }

    private func move(_ app: Application, from index: Int, to destination: Int) {
        var rows = preferences.rows(for: app.id, actions: availableActions(for: app))
        guard rows.indices.contains(index), rows.indices.contains(destination) else { return }
        rows.swapAt(index, destination)
        preferences.save(rows, for: app.id)
    }

    private func refreshApplications() {
        wheelApps.refresh(capacity: capacity)
        let workspace = NSWorkspace.shared
        let ids = Set(AppScriptActions.supportedBundleIDs).union(preferences.profiles.keys)
        closedApplications = ids.subtracting(wheelApps.runningApplicationIDs).compactMap { id in
            guard let url = workspace.urlForApplication(withBundleIdentifier: id) else { return nil }
            let builtIn = AppScriptActions.discover(bundleIdentifier: id, bundleURL: url)
            guard !preferences.availableActions(for: id, builtIn: builtIn).isEmpty else { return nil }
            let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return Application(id: id, name: name, builtIn: builtIn, pid: nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        updatePage()
    }

    private func updatePage() {
        if let selectedID, let index = layoutIDs.firstIndex(where: { $0.contains(selectedID) }) {
            page = index
        } else {
            page = min(page, max(0, pageCount - 1))
            if selectedApp == nil {
                selectedID = nil
                editing = false
            }
        }
    }
}

private struct AppMenuImportView: View {
    let appID: String
    let name: String
    let pid: pid_t
    let builtIn: [AppScriptAction]
    @ObservedObject var preferences: AppActionPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [AppMenuCommand] = []
    @State private var menuTitles: [String] = []
    @State private var selectedMenu: String?
    @State private var search = ""
    @State private var isLoading = true
    @State private var error: String?
    @State private var needsPermission = false

    private var results: [AppMenuCommand] {
        commands.filter { command in
            command.path.first == selectedMenu &&
                (search.isEmpty || command.path.dropFirst().contains { $0.localizedStandardContains(search) })
        }
    }

    var body: some View {
        let actionCount = preferences.apply(to: builtIn, appID: appID).count
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.title2.bold())
            HStack {
                Text(L10n.text("Importar do menu…"))
                Spacer()
                Text(L10n.text("Ações na roda: %@ de %@", String(actionCount), String(AppActionPreferences.visibleLimit)))
            }
            .foregroundStyle(.secondary)
            TextField(L10n.text("Buscar comando do menu"), text: $search)
                .textFieldStyle(.roundedBorder)
                .disabled(menuTitles.isEmpty)

            if !menuTitles.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(menuTitles, id: \.self) { title in
                            let tab = Button {
                                selectedMenu = title
                            } label: {
                                Text(title).fixedSize()
                            }
                            if selectedMenu == title {
                                tab.buttonStyle(.borderedProminent)
                                    .accessibilityAddTraits(.isSelected)
                            } else {
                                tab.buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    if needsPermission {
                        Button(L10n.text("Abrir ajustes de Acessibilidade")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                Text(L10n.text("Nenhum comando de menu encontrado."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { command in
                    let added = preferences.profiles[appID]?.contains { $0.id == command.id } == true
                    HStack {
                        Text(command.path.dropFirst().joined(separator: " › "))
                        Spacer()
                        Button(L10n.text(added ? "Adicionado" : "Adicionar")) {
                            preferences.importCommand(command, for: appID, builtIn: builtIn)
                        }
                        .disabled(added || actionCount >= AppActionPreferences.visibleLimit)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("Concluído")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
        .task {
            do {
                let discovered = try await AppMenuCommands.discover(pid: pid, appID: appID)
                var seen = Set<String>()
                menuTitles = discovered.compactMap(\.path.first).filter { seen.insert($0).inserted }
                selectedMenu = menuTitles.first
                commands = discovered
            } catch {
                self.error = error.localizedDescription
                needsPermission = (error as? AppMenuCommands.Failure) == .permission
            }
            isLoading = false
        }
    }
}
