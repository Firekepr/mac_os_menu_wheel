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
              identifier == xcodeID || supportsPlaybackState(identifier),
              let url = application.bundleURL,
              let bundle = Bundle(url: url),
              let definition = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let resources = bundle.resourceURL,
              let data = try? Data(contentsOf: resources.appendingPathComponent(definition)) else { return [] }
        return discover(in: data, bundleIdentifier: identifier)
    }

    static func discover(in dictionary: Data, bundleIdentifier: String) -> [AppScriptAction] {
        let targetsWorkspace = bundleIdentifier == xcodeID
        guard targetsWorkspace || supportsPlaybackState(bundleIdentifier),
              let document = try? XMLDocument(data: dictionary, options: .nodeLoadExternalEntitiesNever),
              let commands = try? document.nodes(forXPath: "/dictionary/suite/command") else { return [] }
        if targetsWorkspace {
            let path = "/dictionary/suite/class-extension[@extends='application']/property[@code='awks' and @type='workspace document']"
            guard let properties = try? document.nodes(forXPath: path), !properties.isEmpty else { return [] }
        }
        let profile = targetsWorkspace ? xcodeControls : playbackControls
        return profile.compactMap { entry in
            for case let command as XMLElement in commands {
                guard command.attribute(forName: "name")?.stringValue == entry.command,
                      let code = command.attribute(forName: "code")?.stringValue,
                      code.utf8.count == 8, code.utf8.allSatisfy({ (32...126).contains($0) }),
                      acceptsParameters(command, targetsWorkspace: targetsWorkspace) else { continue }
                let eventClass = code.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let eventID = code.utf8.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return AppScriptAction(title: entry.title, symbol: entry.symbol, eventClass: eventClass,
                                       eventID: eventID, targetsActiveWorkspace: targetsWorkspace)
            }
            return nil
        }
    }

    private static func acceptsParameters(_ command: XMLElement, targetsWorkspace: Bool) -> Bool {
        let parameters = (command.children ?? []).compactMap { $0 as? XMLElement }
        let direct = parameters.first { $0.name == "direct-parameter" }
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
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return property.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private static func readPlaybackState(pid: pid_t) -> Bool {
        guard let specifier = applicationProperty(0x70506C53) else { return false } // pPlS

        let event = makeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), pid: pid)
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        // The first explicit control action can request Automation permission.
        // Polling must stay silent when permission has not been granted.
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let address = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(address, event.eventClass, event.eventID, false) == noErr,
              let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.5),
              (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0 else { return false }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.enumCodeValue == 0x6B505350 // kPSP
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
        let event = makeEvent(eventClass: action.eventClass, eventID: action.eventID, pid: pid)
        if action.targetsActiveWorkspace {
            // Xcode resolves its active workspace when handling the command.
            guard let workspace = applicationProperty(0x61776B73) else { // awks
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
            }
            event.setParam(workspace, forKeyword: AEKeyword(keyDirectObject))
        }
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            let description = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(code),
                          userInfo: description.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
        }
    }
}
