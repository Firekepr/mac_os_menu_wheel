import AppKit

MainActor.assumeIsolated {
    let dictionary = Data("""
        <dictionary><suite>
            <command name="next track" code="spfyNext"/>
            <command name="playpause" code="spfyPlPs"/>
            <command name="previous track" code="spfyPrev"/>
            <command name="play track" code="spfyPCtx"><direct-parameter type="text"/></command>
        </suite></dictionary>
        """.utf8)
    let actions = AppScriptActions.discover(in: dictionary, bundleIdentifier: "com.spotify.client")
    precondition(actions.map(\.eventID) == [0x50726576, 0x506C5073, 0x4E657874])
    precondition(actions.allSatisfy { $0.eventClass == 0x73706679 })
    precondition(AppScriptActions.discover(in: dictionary, bundleIdentifier: "other.app").isEmpty)
    let suite = "Radial.ActionPreferencesChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppActionPreferences(defaults: defaults)
    let appID = "com.spotify.client"
    precondition(preferences.apply(to: actions, appID: appID) == actions)
    var rows = preferences.rows(for: appID, actions: actions)
    rows[0].isVisible = false
    rows[2].title = "Minha próxima faixa"
    rows[2].symbol = "star.fill"
    rows.swapAt(1, 2)
    preferences.save(rows, for: appID)
    let restored = AppActionPreferences(defaults: defaults)
    let configured = restored.apply(to: actions, appID: appID)
    precondition(configured.map(\.eventID) == [actions[2].eventID, actions[1].eventID])
    precondition(configured[0].displayTitle == "Minha próxima faixa" && configured[0].symbol == "star.fill")
    precondition(restored.apply(to: actions, appID: "com.apple.Music") == actions)
    restored.reset(appID)
    precondition(AppActionPreferences(defaults: defaults).apply(to: actions, appID: appID) == actions)
    let imported = AppMenuCommand(path: ["Arquivo", "Nova janela"])
    precondition(imported.id != AppMenuCommand(path: ["Arquivo › Nova", "janela"]).id)
    restored.importCommand(imported, for: appID, builtIn: actions)
    restored.importCommand(imported, for: appID, builtIn: actions)
    let menuRestored = AppActionPreferences(defaults: defaults)
    let mixed = menuRestored.apply(to: actions, appID: appID)
    precondition(mixed.count == actions.count + 1 && mixed.last?.menuCommand == imported)
    precondition(mixed.last?.displayTitle == "Nova janela")
    for index in 1...5 {
        menuRestored.importCommand(AppMenuCommand(path: ["Arquivo", "Comando \(index)"]),
                                   for: appID, builtIn: actions)
    }
    precondition(menuRestored.apply(to: actions, appID: appID).count == AppActionPreferences.visibleLimit)
    precondition(menuRestored.availableActions(for: appID, builtIn: actions).count == actions.count + 6)
    menuRestored.removeCommand(imported, for: appID)
    precondition(!menuRestored.availableActions(for: appID, builtIn: actions).contains { $0.menuCommand == imported })
    menuRestored.reset(appID)
    let incompatible = Data("""
        <dictionary><suite>
            <command name="playpause" code="spfyPlPs"><direct-parameter type="text"/></command>
            <command name="next track" code="bad"/>
        </suite></dictionary>
        """.utf8)
    precondition(AppScriptActions.discover(in: incompatible, bundleIdentifier: "com.spotify.client").isEmpty)

    for count in [4, 8, 12] {
        for diameter in [260.0, 380.0, 520.0] {
            let parts = actions.count + 1
            let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
            let radius = WheelActionGeometry.actionRadius(diameter: diameter)
            for index in 0..<count {
                let paths = (0..<parts).map {
                    WheelActionGeometry.actionPath(diameter: diameter, index: index, count: count,
                                                  part: $0, parts: parts).cgPath
                }
                for part in paths.indices {
                    let angle = WheelActionGeometry.actionAngle(index: index, count: count,
                                                                 part: part, parts: parts) * .pi / 180
                    let point = CGPoint(x: center + cos(angle) * radius, y: center + sin(angle) * radius)
                    precondition(paths.indices.filter { paths[$0].contains(point) } == [part])
                }
            }
        }
    }

    if let path = CommandLine.arguments.dropFirst().first {
        let installed = try! Data(contentsOf: URL(fileURLWithPath: path))
        precondition(AppScriptActions.discover(in: installed, bundleIdentifier: "com.spotify.client").count == 3)
    }
    if let music = Bundle(url: URL(fileURLWithPath: "/System/Applications/Music.app")),
       let dictionary = music.url(forResource: "com.apple.Music", withExtension: "sdef") {
        let installed = try! Data(contentsOf: dictionary)
        let musicActions = AppScriptActions.discover(in: installed, bundleIdentifier: "com.apple.Music")
        precondition(musicActions.map(\.eventID) == actions.map(\.eventID))
        precondition(musicActions.allSatisfy { $0.eventClass == 0x686F6F6B }) // 'hook'
    }
    let xcodeDictionary = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Resources/Xcode.sdef")
    if let installed = try? Data(contentsOf: xcodeDictionary) {
        let xcodeActions = AppScriptActions.discover(in: installed, bundleIdentifier: "com.apple.dt.Xcode")
        precondition(xcodeActions.map(\.eventID) == [0x62756C64, 0x6572756E, 0x74657374, 0x73746F70])
        precondition(xcodeActions.allSatisfy { $0.eventClass == 0x78636F64 && $0.targetsActiveWorkspace })
        precondition(AppScriptActions.applicationProperty(0x61776B73) != nil)
        precondition(!AppScriptActions.supportsPlaybackState("com.apple.dt.Xcode"))
        print("Xcode dictionary checks passed: build, run, test and stop target the active workspace.")
    }
    let mailDictionary = URL(fileURLWithPath: "/System/Applications/Mail.app/Contents/Resources/Mail.sdef")
    if let installed = try? Data(contentsOf: mailDictionary) {
        let mailActions = AppScriptActions.discover(in: installed, bundleIdentifier: AppScriptActions.mailID)
        precondition(mailActions.map(\.title) == ["Sincronizar", "Nova mensagem"])
        precondition(mailActions.map(\.eventID) == [0x73796163, 0x656D746F])
    }
    print("Script actions checks passed: dictionary filtering, event codes and outer hit targets.")
}
