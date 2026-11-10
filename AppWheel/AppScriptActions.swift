import AppKit
import Carbon

struct AppScriptAction: Equatable, Sendable {
    let title: String
    let symbol: String
    let eventClass: UInt32
    let eventID: UInt32
    var targetsActiveWorkspace = false
}

enum AppScriptActions {
    static let mailID = "com.apple.mail"
    static let authorizeMailBadge = AppScriptAction(title: "Autorizar badge do Mail", symbol: "exclamationmark.triangle.fill",
                                                    eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData))
    private static let eventQueue = DispatchQueue(label: "AppWheel.AppleEvents", qos: .userInitiated)
    private static let playbackQueue = DispatchQueue(label: "AppWheel.PlaybackState", qos: .utility)

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

    static func discover(in application: NSRunningApplication) -> [AppScriptAction] {
        guard let identifier = application.bundleIdentifier,
              identifier == xcodeID || identifier == mailID || supportsPlaybackState(identifier),
              let url = application.bundleURL,
              let bundle = Bundle(url: url),
              let definition = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let resources = bundle.resourceURL,
              let data = try? Data(contentsOf: resources.appendingPathComponent(definition)) else { return [] }
        return discover(in: data, bundleIdentifier: identifier)
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
