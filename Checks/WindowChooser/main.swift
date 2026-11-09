import AppKit
import ApplicationServices

let element = AXUIElementCreateApplication(getpid())
let windows = (1...7).map {
    WheelWindow(pid: getpid(), title: "Project \($0)", element: element, closeButton: element, scriptActions: [])
}
let app = WheelApp(application: NSRunningApplication.current)
let state = WheelInteraction(dwellDelay: 0.5, loadWindows: { _ in windows })
state.select(app.id, canRevealClose: true, actionDelay: 0.04, app: app)
precondition(!state.isChoosingWindow)
try await Task.sleep(for: .milliseconds(180))
precondition(state.isChoosingWindow && state.windowPageCount == 3 && state.visibleWindows.count == 3)
let slots = (0..<8).map { WheelSlot(id: $0, app: $0 == 0 ? app : nil) }
let diameter = state.diameter
let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
func point(angle: Double, radius: CGFloat) -> CGPoint {
    let radians = angle * .pi / 180
    return CGPoint(x: center + cos(radians) * radius, y: center + sin(radians) * radius)
}
let tabAngle = WheelActionGeometry.actionAngle(index: 0, count: slots.count,
                                               part: state.firstWindowTab, parts: state.windowTabCount)
let tab = point(angle: tabAngle, radius: WheelActionGeometry.actionRadius(diameter: diameter, band: .windows))
let action = point(angle: -90, radius: WheelActionGeometry.actionRadius(diameter: diameter, band: .windowActions))
state.update(at: action, slots: slots, allowsBeyondEdge: true)
precondition(state.windowChoice == nil, "A hidden action must not be hit")
state.update(at: tab, slots: slots, allowsBeyondEdge: true)
precondition(state.windowChoice?.0.title == "Project 1" && state.windowChoice?.1 == .open)
state.update(at: point(angle: tabAngle, radius: diameter / 2 + 45), slots: slots, allowsBeyondEdge: true)
precondition(state.windowChoice == nil && state.hoveredWindow == 0, "Crossing the gap retains the submenu without committing")
state.update(at: action, slots: slots, allowsBeyondEdge: true)
precondition(state.windowChoice?.1 == .close)
let nextAngle = WheelActionGeometry.actionAngle(index: 0, count: slots.count,
                                                part: state.windowTabCount - 1, parts: state.windowTabCount)
let next = point(angle: nextAngle, radius: WheelActionGeometry.actionRadius(diameter: diameter, band: .windows))
precondition(state.changeWindowPage(at: next, slots: slots))
precondition(state.visibleWindows.map(\.title) == ["Project 4", "Project 5", "Project 6"] && state.windowChoice == nil)
state.reset()
precondition(!state.isChoosingWindow)
state.select(app.id, canRevealClose: true, actionDelay: 0.04, app: app)
state.reset()
try await Task.sleep(for: .milliseconds(100))
precondition(!state.isChoosingWindow && state.closeTargetID == nil)
let single = WheelInteraction(dwellDelay: 0.03, loadWindows: { _ in [windows[0]] })
single.select(app.id, canRevealClose: true, app: app)
try await Task.sleep(for: .milliseconds(100))
precondition(!single.isChoosingWindow && single.closeTargetID == app.id)
print("Window chooser checks passed: configured delay, radial tabs, submenu gap, pagination, explicit action hit, cancellation and single-window fallback.")
