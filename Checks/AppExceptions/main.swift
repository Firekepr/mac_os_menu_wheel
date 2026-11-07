import AppKit
import Foundation

MainActor.assumeIsolated {
    let suite = "AppWheel.ExceptionChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppExceptions(defaults: defaults)
    precondition(store.apps.isEmpty)
    precondition(!store.contains(bundleIdentifier: nil))
    store.add(bundleIdentifier: "test.game", name: "Jogo", path: "/Applications/Jogo.app")
    store.add(bundleIdentifier: "test.game", name: "Jogo duplicado", path: "/Applications/OutraCopia.app")
    precondition(store.apps.count == 1)
    precondition(!store.contains(bundleIdentifier: "test.editor"))
    let reloaded = AppExceptions(defaults: defaults)
    precondition(reloaded.contains(bundleIdentifier: "test.game"))
    precondition(reloaded.apps.first?.name == "Jogo")

    var frontmost: String? = "test.game"
    let controller = GestureController(defaults: defaults, frontmostBundleIdentifier: { frontmost })
    @MainActor func expectPassThrough(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .right)!
        let returned = controller.handle(type, event: event)?.takeUnretainedValue()
        precondition(returned === event, "Excluded app lost its original \(type) event")
    }
    expectPassThrough(.rightMouseDown)
    // Keep routing a press consistently even if focus or preferences change mid-drag.
    frontmost = "test.editor"
    controller.exceptions.remove(controller.exceptions.apps[0])
    expectPassThrough(.rightMouseDragged)
    expectPassThrough(.rightMouseUp)
    precondition(AppExceptions(defaults: defaults).apps.isEmpty)
    precondition(!controller.isEnabled)
    controller.shutDown()
    print("Exception checks passed: persistence, duplicates, removal, original click/drag/release, focus change.")
}
