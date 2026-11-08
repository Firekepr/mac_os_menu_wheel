import AppKit
import Foundation

MainActor.assumeIsolated {
    let state = WheelInteraction(dwellDelay: 0.03)
    state.select("editor", canRevealClose: true)
    precondition(state.closeTargetID == nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
    state.select("editor", canRevealClose: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    precondition(state.closeTargetID == "editor" && !state.isCloseHovered)
    // Crossing the gap preserves the action; selecting a different app clears it.
    state.select(nil, canRevealClose: false)
    precondition(state.id == nil && state.closeTargetID == "editor")
    state.hoverClose()
    precondition(state.id == "editor" && state.isCloseHovered)
    state.select("browser", canRevealClose: true)
    precondition(state.closeTargetID == nil && !state.isCloseHovered, "Selection focus retained the old action")
    state.reset()
    precondition(state.id == nil && state.closeTargetID == nil && !state.isCloseHovered)

    state.select("editor", canRevealClose: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
    state.select("browser", canRevealClose: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    precondition(state.closeTargetID == nil, "An old timer revealed the wrong app")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
    precondition(state.closeTargetID == "browser")
    state.reset()
    state.select("closed-favorite", canRevealClose: false)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    precondition(state.closeTargetID == nil)
    state.select("editor", canRevealClose: true)
    state.reset()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    precondition(state.closeTargetID == nil, "Dismissal left a dwell timer alive")

    let suite = "AppWheel.CloseChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = RunningApps(favorites: AppFavorites(defaults: defaults), observesFavorites: false)
    for diameter in [260.0, 380.0, 520.0] {
        state.diameter = diameter
        let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
        let point = CGPoint(x: center + WheelGeometry.deadZone * diameter / WheelGeometry.size / 2, y: center)
        state.select("editor", canRevealClose: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        precondition(state.closeTargetID == "editor")
        state.update(at: point, slots: model.slots, allowsBeyondEdge: true)
        precondition(state.closeTargetID == nil && state.id == nil && !state.isCloseHovered,
                     "Returning to center retained the close sector")
        state.select("editor", canRevealClose: true)
        state.update(at: point, slots: model.slots, allowsBeyondEdge: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        precondition(state.closeTargetID == nil, "The center did not cancel the pending dwell")
    }
    let editor = WheelApp(application: nil, favorite: FavoriteApp(id: "editor", name: "Editor", path: "/fake.app", position: 0))
    let sparseSlots = (0..<8).map { WheelSlot(id: $0, app: $0 == 0 ? editor : nil) }
    for diameter in [260.0, 380.0, 520.0] {
        state.diameter = diameter
        let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
        let emptyPoint = CGPoint(x: center + diameter * 0.35, y: center)
        state.select("editor", canRevealClose: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        precondition(state.closeTargetID == "editor")
        let gap = CGPoint(x: center, y: center - diameter / 2 - diameter * 5 / WheelGeometry.size)
        state.update(at: gap, slots: sparseSlots, allowsBeyondEdge: true)
        precondition(state.closeTargetID == "editor", "The gap lost its action")
        state.update(at: emptyPoint, slots: sparseSlots, allowsBeyondEdge: true)
        precondition(state.closeTargetID == nil && state.id == nil && !state.isCloseHovered,
                     "An empty sector retained the close action")
        state.select("editor", canRevealClose: true)
        state.update(at: emptyPoint, slots: sparseSlots, allowsBeyondEdge: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        precondition(state.closeTargetID == nil, "An empty sector left the dwell timer alive")
    }
    for diameter in [260.0, 380.0, 520.0] {
        state.diameter = diameter
        let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
        let radius = WheelGeometry.centerDiameter / 2 * diameter / WheelGeometry.size
        let openPoint = CGPoint(x: center, y: center + radius * 0.6)
        let local = CGPoint(x: diameter / 2, y: diameter / 2 + radius * 0.6)
        precondition(WheelGeometry.isOpenMainWindowArea(at: local, diameter: diameter))
        precondition(!WheelGeometry.isOpenMainWindowArea(at: CGPoint(x: diameter / 2, y: diameter / 2), diameter: diameter))
        precondition(!WheelGeometry.isOpenMainWindowArea(at: CGPoint(x: diameter / 2 + radius, y: local.y), diameter: diameter))
        state.select("editor", canRevealClose: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        state.update(at: openPoint, slots: [], allowsBeyondEdge: true)
        precondition(state.isOpenMainWindowHovered && state.id == nil && state.closeTargetID == nil && !state.isCloseHovered)
        state.update(at: CGPoint(x: center, y: center), slots: [], allowsBeyondEdge: true)
        precondition(!state.isOpenMainWindowHovered && state.id == nil)
        state.update(at: openPoint, slots: [], allowsBeyondEdge: false)
        precondition(state.isOpenMainWindowHovered)
        state.select("editor", canRevealClose: false)
        precondition(!state.isOpenMainWindowHovered)
        state.reset()
    }
    let app = WheelApp(application: NSRunningApplication.current)
    var requests = 0
    precondition(model.requestQuit(app, isRunning: { _ in true }, terminate: { _ in requests += 1; return true }) == nil)
    precondition(requests == 1)
    precondition(model.requestQuit(app, isRunning: { _ in true }, terminate: { _ in requests += 1; return false }) != nil)
    precondition(model.requestQuit(app, isRunning: { _ in false }, terminate: { _ in requests += 1; return true }) != nil)
    let closed = WheelApp(application: nil, favorite: FavoriteApp(id: "closed", name: "Fechado", path: "/fake.app", position: 0))
    precondition(model.requestQuit(closed, terminate: { _ in requests += 1; return true }) != nil)
    precondition(requests == 2, "A closed favorite received a quit request")

    let finder = WheelApp(application: NSRunningApplication.current,
                          favorite: FavoriteApp(id: "com.apple.finder", name: "Nome personalizado", path: "/Finder.app", position: 0))
    precondition(finder.isQuitProtected && !finder.canRequestQuit)
    precondition(model.requestQuit(finder, isRunning: { _ in true }, terminate: { _ in requests += 1; return true }) != nil)
    precondition(requests == 2, "A Finder quit request reached the termination API")
    state.reset()
    state.diameter = 380
    let finderSlots = (0..<8).map { WheelSlot(id: $0, app: $0 == 0 ? finder : nil) }
    let finderCenter = WheelActionGeometry.outerSize(diameter: 380) / 2
    state.update(at: CGPoint(x: finderCenter, y: finderCenter - 135), slots: finderSlots, allowsBeyondEdge: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    precondition(state.id == "com.apple.finder" && state.closeTargetID == nil, "Finder exposed a close action")

    var posted: [CGEvent] = []
    let controller = GestureController(defaults: defaults, frontmostBundleIdentifier: { "test.editor" },
                                       postEvent: { posted.append($0) })
    let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                       mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .right)!
    precondition(controller.handle(.rightMouseDown, event: down) == nil)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                     mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .right)!
    precondition(controller.handle(.rightMouseUp, event: up) == nil)
    precondition(posted.isEmpty, "Focus change replayed a click into the newly active app")
    controller.shutDown()

    let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
    for diameter in [260.0, 380.0, 520.0] {
        for point in [screen.origin, CGPoint(x: -1, y: 699), CGPoint(x: -700, y: 250)] {
            let panel = WheelActionGeometry.panelFrame(around: point, diameter: diameter, visibleFrame: screen)
            precondition(screen.contains(panel))
            precondition(panel.height == WheelActionGeometry.outerSize(diameter: diameter))
        }
        let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
        let radius = WheelActionGeometry.actionRadius(diameter: diameter)
        for count in 1...8 {
            for index in 0..<count {
                let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
                let point = CGPoint(x: center + cos(angle) * radius, y: center + sin(angle) * radius)
                let hit = WheelActionGeometry.closePath(diameter: diameter, index: index, count: count)
                precondition(hit.cgPath.contains(point), "Action does not follow its app's direction")
                precondition(!hit.cgPath.contains(CGPoint(x: center, y: center)), "Center is not a close target")
                let inner = CGPoint(x: center + cos(angle) * diameter * 0.35, y: center + sin(angle) * diameter * 0.35)
                precondition(!hit.cgPath.contains(inner), "The main wheel must never trigger close")
                let gapRadius = diameter / 2 + diameter * 5 / WheelGeometry.size
                precondition(!hit.cgPath.contains(CGPoint(x: center + cos(angle) * gapRadius, y: center + sin(angle) * gapRadius)), "Gap hit: diameter \(diameter), count \(count), index \(index)")
                for other in 0..<count where other != index {
                    precondition(!WheelActionGeometry.closePath(diameter: diameter, index: other, count: count).cgPath.contains(point))
                }
            }
        }
    }
    let smallScreen = CGSize(width: 400, height: 300)
    let fitted = WheelActionGeometry.fittingDiameter(520, available: smallScreen)
    precondition(WheelActionGeometry.outerSize(diameter: fitted) <= 300.001)
    print("Close-action checks passed: dwell, travel, retargeting, cancellation, closed favorites, mocked quit requests, display bounds.")
}
