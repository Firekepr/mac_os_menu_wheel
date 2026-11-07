import AppKit
import Foundation

MainActor.assumeIsolated {
    let suite = "AppWheel.PreferenceChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = WheelPreferences(defaults: defaults)
    precondition(preferences.triggerButton == .right)
    precondition(preferences.wheelDiameter == 380 && preferences.holdDelay == 0.3)
    preferences.wheelDiameter = 520
    preferences.holdDelay = 0.75
    preferences.triggerButton = .side5
    let restored = WheelPreferences(defaults: defaults)
    precondition(restored.wheelDiameter == 520 && restored.holdDelay == 0.75 && restored.triggerButton == .side5)
    preferences.wheelDiameter = -100
    preferences.holdDelay = 100
    precondition(preferences.wheelDiameter == 260 && preferences.holdDelay == 1)
    preferences.wheelDiameter = .nan
    preferences.holdDelay = .infinity
    precondition(preferences.wheelDiameter == 380 && preferences.holdDelay == 0.3)
    defaults.set(999, forKey: "wheelTriggerButton")
    precondition(WheelPreferences(defaults: defaults).triggerButton == .right)
    preferences.reset()
    precondition(WheelPreferences(defaults: defaults).triggerButton == .right)

    var posted: [CGEvent] = []
    var frontmost = "test.editor"
    let controller = GestureController(defaults: defaults, frontmostBundleIdentifier: { frontmost },
                                       postEvent: { posted.append($0) })
    controller.exceptions.add(bundleIdentifier: "test.game", name: "Jogo", path: "/Applications/Jogo.app")
    @MainActor func event(_ button: MouseTriggerButton, _ type: CGEventType, x: CGFloat = 300) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: 300),
                mouseButton: CGMouseButton(rawValue: UInt32(button.rawValue))!)!
    }
    for button in MouseTriggerButton.allCases {
        controller.preferences.triggerButton = button
        // Unselected buttons must retain their original events.
        let other: MouseTriggerButton = button == .right ? .left : .right
        for phase in [other.down, other.drag, other.up] {
            let e = event(other, phase)
            precondition(controller.handle(phase, event: e)?.takeUnretainedValue() === e)
        }
        // A short press replays exactly the selected button's down/up pair.
        posted.removeAll()
        precondition(controller.handle(button.down, event: event(button, button.down)) == nil)
        precondition(controller.handle(button.up, event: event(button, button.up)) == nil)
        precondition(posted.map(\.type) == [button.down, button.up])
        precondition(posted.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(button.rawValue) })

        // Early drags restore the original down and first drag, then pass through.
        posted.removeAll()
        _ = controller.handle(button.down, event: event(button, button.down))
        _ = controller.handle(button.drag, event: event(button, button.drag, x: 320))
        precondition(posted.map(\.type) == [button.down, button.drag])
        let up = event(button, button.up)
        precondition(controller.handle(button.up, event: up)?.takeUnretainedValue() === up)

        // Exclusions bypass capture for all button choices, even after a settings change.
        frontmost = "test.game"
        let down = event(button, button.down)
        precondition(controller.handle(button.down, event: down)?.takeUnretainedValue() === down)
        controller.preferences.triggerButton = other
        for phase in [button.drag, button.up] {
            let e = event(button, phase)
            precondition(controller.handle(phase, event: e)?.takeUnretainedValue() === e)
        }
        frontmost = "test.editor"
        controller.preferences.triggerButton = button

        // Esc cancels a pending press while preserving the old button through release.
        posted.removeAll()
        _ = controller.handle(button.down, event: event(button, button.down))
        controller.preferences.triggerButton = other
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        precondition(controller.handle(.keyDown, event: escape) == nil)
        precondition(controller.handle(button.up, event: event(button, button.up)) == nil)
        precondition(posted.isEmpty)
    }
    controller.shutDown()

    // Selection and cancellation scale with the actual rendered diameter.
    for diameter in [260.0, 380.0, 520.0] {
        let center = diameter / 2
        precondition(WheelGeometry.index(at: CGPoint(x: center, y: center), count: 8,
                                        allowsBeyondEdge: true, diameter: diameter) == nil)
        precondition(WheelGeometry.index(at: CGPoint(x: center, y: diameter * 0.1), count: 8,
                                        allowsBeyondEdge: true, diameter: diameter) == 0)
        precondition(WheelGeometry.index(at: CGPoint(x: diameter * 0.9, y: center), count: 8,
                                        allowsBeyondEdge: true, diameter: diameter) == 2)
        let bounds = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        precondition(bounds.contains(WheelGeometry.panelFrame(around: bounds.origin, visibleFrame: bounds, diameter: diameter)))
    }
    let small = CGRect(x: 0, y: 0, width: 320, height: 300)
    precondition(small.contains(WheelGeometry.panelFrame(around: .zero, visibleFrame: small, diameter: 520)))
    print("Preferences checks passed: defaults, persistence, limits, five buttons, short clicks, drags, exclusions, Esc, resizing.")
}
