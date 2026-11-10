import AppKit
import ApplicationServices
import Foundation

MainActor.assumeIsolated {
    let suite = "Radial.GestureLifecycleChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let controller = GestureController(defaults: defaults)
    precondition(!defaults.bool(forKey: "globalGestureEnabled"))
    precondition(!controller.isEnabled)

    // A denied or pending permission must still preserve the user's intent.
    // No permission dialog is requested by this check.
    controller.start(requestPermission: false)
    precondition(defaults.bool(forKey: "globalGestureEnabled"))
    controller.shutDown()
    precondition(!controller.isEnabled)
    precondition(defaults.bool(forKey: "globalGestureEnabled"), "Quit lost the saved preference")

    let reopened = GestureController(defaults: defaults)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    if !AXIsProcessTrusted() {
        precondition(reopened.needsPermission, "Saved activation was not restored on launch")
        precondition(!reopened.isEnabled)
    }
    precondition(defaults.bool(forKey: "globalGestureEnabled"))
    controller.shutDown()
    reopened.stop()
    precondition(!defaults.bool(forKey: "globalGestureEnabled"), "Explicit disable was not saved")
    precondition(!reopened.needsPermission)
    reopened.shutDown()
    precondition(!defaults.bool(forKey: "globalGestureEnabled"))
    print("Gesture lifecycle checks passed: enable, quit, relaunch, pending permission, explicit disable.")
}
