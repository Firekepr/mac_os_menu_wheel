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
    print("Script actions checks passed: dictionary filtering, event codes and outer hit targets.")
}
