import AppKit
import Foundation
import ServiceManagement

MainActor.assumeIsolated {
    // Exercise login-item transitions without registering this test executable
    // or changing the user's actual Login Items.
    var loginStatus = SMAppService.Status.notRegistered
    var registrations = 0
    var removals = 0
    var registrationFails = false
    var removalFails = false
    struct LoginFailure: Error {}
    let login = LaunchAtLogin(readStatus: { loginStatus }, register: {
        registrations += 1
        if registrationFails { throw LoginFailure() }
        loginStatus = .enabled
    }, unregister: {
        removals += 1
        if removalFails { throw LoginFailure() }
        loginStatus = .notRegistered
    })
    precondition(!login.isRequested && registrations == 0 && removals == 0)
    login.setEnabled(true)
    precondition(login.isRequested && registrations == 1 && login.error == nil)
    login.setEnabled(true)
    precondition(registrations == 1)
    // External changes must be reflected without registering again.
    loginStatus = .requiresApproval
    login.refresh()
    precondition(login.isRequested && login.status == .requiresApproval)
    login.setEnabled(true)
    precondition(registrations == 1)
    removalFails = true
    login.setEnabled(false)
    precondition(login.isRequested && login.error != nil)
    removalFails = false
    login.setEnabled(false)
    precondition(!login.isRequested && login.error == nil && removals == 2)
    registrationFails = true
    login.setEnabled(true)
    precondition(!login.isRequested && login.error != nil)
    registrationFails = false
    login.setEnabled(true)
    precondition(login.isRequested && login.error == nil)
    loginStatus = .notRegistered
    login.refresh()
    precondition(!login.isRequested && registrations == 3)
    loginStatus = .notFound
    login.refresh()
    precondition(!login.isRequested)
    print("Login-item checks passed: no automatic registration, enable, disable, approval, external changes, failure recovery.")

    let suite = "AppWheel.PreferenceChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = WheelPreferences(defaults: defaults)
    precondition(!preferences.showsHoldPreview)
    preferences.showsHoldPreview = true
    precondition(WheelPreferences(defaults: defaults).showsHoldPreview)
    precondition(preferences.language == .system)
    precondition(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    preferences.language = .english
    precondition(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
    precondition(WheelPreferences(defaults: defaults).language == .english)
    preferences.language = .portuguese
    precondition(defaults.stringArray(forKey: "AppleLanguages") == ["pt"])
    preferences.language = .system
    precondition(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
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
    precondition(!WheelPreferences(defaults: defaults).showsHoldPreview)
    precondition(WheelPreferences(defaults: defaults).triggerButton == .right)

    for duration in [0.15, 0.3, 1.0] {
        let timing = HoldPreviewTiming(startedAt: 100, duration: duration)
        precondition(timing.progress(at: 99) == 0)
        precondition(abs(timing.progress(at: 100 + duration / 2) - 0.5) < 0.00001)
        precondition(timing.progress(at: 102) == 1)
    }

    var posted: [CGEvent] = []
    var frontmost = "test.editor"
    let controller = GestureController(defaults: defaults, frontmostBundleIdentifier: { frontmost },
                                       postEvent: { posted.append($0) })
    controller.exceptions.add(bundleIdentifier: "test.game", name: "Jogo", path: "/Applications/Jogo.app")
    @MainActor func event(_ button: MouseTriggerButton, _ type: CGEventType, x: CGFloat = 300) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: 300),
                mouseButton: CGMouseButton(rawValue: UInt32(button.rawValue))!)!
    }
    // The default keeps the countdown entirely inactive, while short clicks
    // still replay normally. Enabling it only affects subsequent gestures.
    _ = controller.handle(.rightMouseDown, event: event(.right, .rightMouseDown))
    precondition(controller.holdPreviewTiming == nil)
    _ = controller.handle(.rightMouseUp, event: event(.right, .rightMouseUp))
    precondition(posted.map(\.type) == [.rightMouseDown, .rightMouseUp])
    controller.preferences.showsHoldPreview = true
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
        let deadline = controller.holdPreviewTiming!
        let savedDelay = controller.preferences.holdDelay
        controller.preferences.holdDelay = 0.95
        precondition(controller.holdPreviewTiming == deadline, "An in-flight countdown changed with preferences")
        controller.preferences.holdDelay = savedDelay
        precondition(controller.handle(button.up, event: event(button, button.up)) == nil)
        precondition(controller.holdPreviewTiming == nil)
        precondition(posted.map(\.type) == [button.down, button.up])
        precondition(posted.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(button.rawValue) })

        // Early drags restore the original down and first drag, then pass through.
        posted.removeAll()
        _ = controller.handle(button.down, event: event(button, button.down))
        _ = controller.handle(button.drag, event: event(button, button.drag, x: 320))
        precondition(posted.map(\.type) == [button.down, button.drag])
        precondition(controller.holdPreviewTiming == nil, "A drag kept its countdown")
        let up = event(button, button.up)
        precondition(controller.handle(button.up, event: up)?.takeUnretainedValue() === up)

        // Exclusions bypass capture for all button choices, even after a settings change.
        frontmost = "test.game"
        let down = event(button, button.down)
        precondition(controller.handle(button.down, event: down)?.takeUnretainedValue() === down)
        precondition(controller.holdPreviewTiming == nil, "Excluded app started a countdown")
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
        precondition(controller.holdPreviewTiming == nil, "Esc kept its countdown")
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
        let panel = WheelGeometry.panelFrame(around: bounds.origin, visibleFrame: bounds, diameter: diameter)
        precondition(panel.midX == bounds.minX && panel.midY == bounds.minY)
    }
    let small = CGRect(x: 0, y: 0, width: 320, height: 300)
    let smallPanel = WheelGeometry.panelFrame(around: .zero, visibleFrame: small, diameter: 520)
    precondition(smallPanel.midX == 0 && smallPanel.midY == 0)
    precondition(smallPanel.width <= small.width && smallPanel.height <= small.height)
    print("Preferences checks passed: defaults, persistence, limits, five buttons, short clicks, drags, exclusions, Esc, resizing.")
}
