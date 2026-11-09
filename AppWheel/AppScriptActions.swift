import AppKit
import Carbon

struct AppScriptAction: Equatable, Sendable {
    let title: String
    let symbol: String
    let eventClass: UInt32
    let eventID: UInt32
}

enum AppScriptActions {
    private static let eventQueue = DispatchQueue(label: "AppWheel.AppleEvents", qos: .userInitiated)

    private static let playbackControls = [
        Control(command: "previous track", title: "Faixa anterior", symbol: "backward.end.fill"),
        Control(command: "playpause", title: "Reproduzir/Pausar", symbol: "playpause.fill"),
        Control(command: "next track", title: "Próxima faixa", symbol: "forward.end.fill")
    ]

    private static let profiles = [
        "com.spotify.client": playbackControls,
        "com.apple.Music": playbackControls
    ]

    private struct Control {
        let command: String
        let title: String
        let symbol: String
    }

    static func discover(in application: NSRunningApplication) -> [AppScriptAction] {
        guard let identifier = application.bundleIdentifier, profiles[identifier] != nil,
              let url = application.bundleURL,
              let bundle = Bundle(url: url),
              let definition = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let resources = bundle.resourceURL,
              let data = try? Data(contentsOf: resources.appendingPathComponent(definition)) else { return [] }
        return discover(in: data, bundleIdentifier: identifier)
    }

    static func discover(in dictionary: Data, bundleIdentifier: String) -> [AppScriptAction] {
        guard let profile = profiles[bundleIdentifier],
              let document = try? XMLDocument(data: dictionary, options: .nodeLoadExternalEntitiesNever),
              let commands = try? document.nodes(forXPath: "/dictionary/suite/command") else { return [] }
        return profile.compactMap { entry in
            for case let command as XMLElement in commands {
                guard command.attribute(forName: "name")?.stringValue == entry.command,
                      let code = command.attribute(forName: "code")?.stringValue,
                      code.utf8.count == 8, code.utf8.allSatisfy({ (32...126).contains($0) }),
                      !(command.children ?? []).contains(where: { node in
                          guard let parameter = node as? XMLElement,
                                parameter.name == "parameter" || parameter.name == "direct-parameter" else { return false }
                          return parameter.attribute(forName: "optional")?.stringValue != "yes"
                      }) else { continue }
                let eventClass = code.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let eventID = code.utf8.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return AppScriptAction(title: entry.title, symbol: entry.symbol, eventClass: eventClass, eventID: eventID)
            }
            return nil
        }
    }

    static func send(_ action: AppScriptAction, to pid: pid_t) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            eventQueue.async {
                continuation.resume(with: Result { try sendEvent(action, to: pid) })
            }
        }
    }

    // Send the same Apple event that the dictionary maps the AppleScript verb to.
    // Target the running process so an action cannot reopen a closed app.
    private static func sendEvent(_ action: AppScriptAction, to pid: pid_t) throws {
        let event = NSAppleEventDescriptor(eventClass: action.eventClass, eventID: action.eventID,
                                          targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            let description = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(code),
                          userInfo: description.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
        }
    }
}
