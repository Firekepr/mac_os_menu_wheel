import AppKit
import Foundation

MainActor.assumeIsolated {
    let suite = "AppWheel.FavoriteChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let favorites = AppFavorites(defaults: defaults)
    precondition(favorites.apps.isEmpty)
    precondition(FavoriteLayout.arrange(runningIDs: ["a", "b"], favorites: [:]) == ["a", "b"])
    let pinned = [0: "browser", 5: "editor"]
    let slots = FavoriteLayout.arrange(runningIDs: ["browser", "finder", "terminal", "editor", "music"], favorites: pinned)
    precondition(slots == ["browser", "finder", "terminal", "music", nil, "editor", nil, nil])
    let closed = FavoriteLayout.arrange(runningIDs: [], favorites: pinned)
    precondition(closed.count == 8 && closed[0] == "browser" && closed[5] == "editor" && closed[1] == nil)
    let overflowing = FavoriteLayout.arrange(runningIDs: (0..<20).map { "app\($0)" }, favorites: pinned)
    precondition(overflowing.count == 8 && overflowing[0] == "browser" && overflowing[5] == "editor")
    precondition(Set(overflowing.compactMap { $0 }).count == 8)
    precondition(FavoriteLayout.arrange(runningIDs: ["a", "a", "b"], favorites: [:]) == ["a", "b"])
    precondition(FavoriteLayout.arrange(runningIDs: [], favorites: [99: "invalid"]).isEmpty)
    for list in [["a"], ["a", "browser", "b"], ["editor", "browser"]] {
        let layout = FavoriteLayout.arrange(runningIDs: list, favorites: pinned)
        precondition(layout[0] == "browser" && layout[5] == "editor")
    }
    favorites.set(position: 5, bundleIdentifier: "test.editor", name: "Editor", path: "/nonexistent/Editor.app")
    let reopened = AppFavorites(defaults: defaults)
    precondition(reopened.app(at: 5)?.id == "test.editor")
    favorites.set(position: 2, bundleIdentifier: "test.editor", name: "Editor", path: "/nonexistent/Editor.app")
    precondition(favorites.apps.count == 1 && favorites.app(at: 5) == nil && favorites.app(at: 2)?.id == "test.editor")
    favorites.set(position: 2, bundleIdentifier: "test.browser", name: "Navegador", path: "/nonexistent/Browser.app")
    favorites.set(position: 99, bundleIdentifier: "bad", name: "Invalid", path: "/bad")
    precondition(favorites.apps.count == 1 && favorites.app(at: 2)?.id == "test.browser")

    let model = RunningApps(favorites: favorites, observesFavorites: false)
    precondition(model.slots.count == 8 && model.slots[2].app?.id == "test.browser")
    precondition(model.slots[2].app?.application == nil && model.slots[2].app?.favorite != nil)
    precondition(!model.isRunning(model.slots[2].app!), "A closed favorite got a running indicator")
    if let live = model.apps.first(where: { $0.application?.isTerminated == false }) {
        precondition(model.isRunning(live), "A running app lost its indicator")
    }
    let frozenSlots = model.slots.map { $0.app?.id }
    // Simulate the notification, without opening or closing a real application.
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    precondition(model.slots.map { $0.app?.id } == frozenSlots, "Status updates rearranged an active wheel")
    // Editing favorites must not move targets under an in-progress global gesture.
    favorites.set(position: 7, bundleIdentifier: "test.browser", name: "Navegador", path: "/nonexistent/Browser.app")
    precondition(model.slots[2].app?.id == "test.browser")
    model.refresh()
    precondition(model.slots[7].app?.id == "test.browser")
    var failure: String?
    model.activate(model.slots[7].app!) { failure = $0 }
    precondition(failure != nil, "A removed favorite should report an error without launching anything")
    favorites.remove(at: 7)
    precondition(AppFavorites(defaults: defaults).apps.isEmpty)
    // Empty sectors keep their angle and resolve to no target, rather than compacting.
    let lowerRight = WheelGeometry.index(at: CGPoint(x: 285, y: 285), count: closed.count, allowsBeyondEdge: true)!
    precondition(lowerRight == 3 && closed[lowerRight] == nil)
    let legacy = Data("""
        [{"id":"legacy.app","name":"Antigo","path":"/old.app","position":1}]
        """.utf8)
    let migrated = try! JSONDecoder().decode([FavoriteApp].self, from: legacy)
    precondition(migrated[0].visibility == .always, "Upgrade changed existing favorites")
    let conditionalClosed = FavoriteLayout.arrange(runningIDs: ["finder"], favorites: pinned, onlyWhenRunning: ["browser"])
    precondition(conditionalClosed.count == 8 && conditionalClosed[0] == "finder" && conditionalClosed[5] == "editor")
    precondition(!conditionalClosed.contains("browser"))
    let conditionalOpen = FavoriteLayout.arrange(runningIDs: ["finder", "browser"], favorites: pinned, onlyWhenRunning: ["browser"])
    precondition(conditionalOpen[0] == "browser" && conditionalOpen[5] == "editor")
    precondition(conditionalOpen.filter { $0 == "browser" }.count == 1)
    let allConditionalClosed = FavoriteLayout.arrange(runningIDs: ["finder"], favorites: [5: "editor"], onlyWhenRunning: ["editor"])
    precondition(allConditionalClosed.count == 8 && allConditionalClosed[0] == "finder" && allConditionalClosed[5] == nil)
    favorites.set(position: 1, bundleIdentifier: "test.conditional", name: "Condicional", path: "/fake.app")
    favorites.setVisibility(.whenRunning, at: 1)
    precondition(AppFavorites(defaults: defaults).app(at: 1)?.visibility == .whenRunning)
    favorites.set(position: 6, bundleIdentifier: "test.conditional", name: "Condicional", path: "/fake.app")
    precondition(favorites.app(at: 1) == nil && favorites.app(at: 6)?.visibility == .whenRunning)
    let conditionalModel = RunningApps(favorites: favorites, observesFavorites: false)
    precondition(conditionalModel.slots.count == 8)
    precondition(!conditionalModel.apps.contains { $0.id == "test.conditional" })
    // A target that closed during the gesture must not be launched in this mode.
    failure = nil
    conditionalModel.activate(WheelApp(application: nil, favorite: favorites.app(at: 6)!)) { failure = $0 }
    precondition(failure != nil)
    favorites.setVisibility(.always, at: 6)
    conditionalModel.refresh()
    precondition(conditionalModel.slots[6].app?.id == "test.conditional")
    let moveSuite = suite + ".drag"
    let moveDefaults = UserDefaults(suiteName: moveSuite)!
    defer { moveDefaults.removePersistentDomain(forName: moveSuite) }
    let moves = AppFavorites(defaults: moveDefaults)
    moves.set(position: 0, bundleIdentifier: "drag.first", name: "Primeiro", path: "/First.app", visibility: .always)
    moves.set(position: 3, bundleIdentifier: "drag.second", name: "Segundo", path: "/Second.app", visibility: .whenRunning)
    moves.set(position: 7, bundleIdentifier: "drag.third", name: "Terceiro", path: "/Third.app")
    let frozen = RunningApps(favorites: moves, observesFavorites: false)
    let beforeMove = frozen.slots.map { $0.app?.id }
    precondition(moves.move(id: "drag.first", to: 2))
    precondition(moves.app(at: 0) == nil && moves.app(at: 2)?.id == "drag.first")
    precondition(frozen.slots.map { $0.app?.id } == beforeMove, "Dragging changed targets during an open gesture")
    precondition(moves.move(id: "drag.first", to: 3))
    precondition(moves.apps.count == 3 && Set(moves.apps.map(\.id)).count == 3)
    precondition(moves.app(at: 3)?.id == "drag.first" && moves.app(at: 3)?.visibility == .always)
    precondition(moves.app(at: 3)?.name == "Primeiro" && moves.app(at: 3)?.path == "/First.app")
    precondition(moves.app(at: 2)?.id == "drag.second" && moves.app(at: 2)?.visibility == .whenRunning)
    precondition(moves.app(at: 2)?.name == "Segundo" && moves.app(at: 2)?.path == "/Second.app")
    precondition(moves.app(at: 7)?.id == "drag.third")
    let restoredMove = AppFavorites(defaults: moveDefaults)
    precondition(restoredMove.app(at: 3)?.id == "drag.first" && restoredMove.app(at: 2)?.id == "drag.second")
    precondition(restoredMove.app(at: 2)?.visibility == .whenRunning)
    let beforeInvalid = moves.apps.map { "\($0.id):\($0.position)" }
    precondition(!moves.move(id: "drag.first", to: 3))
    precondition(!moves.move(id: "missing", to: 1))
    precondition(!moves.move(id: "drag.first", to: -1))
    precondition(!moves.move(id: "drag.first", to: 8))
    precondition(moves.apps.map { "\($0.id):\($0.position)" } == beforeInvalid)
    for position in 0..<8 {
        let angle = Double(position) * .pi / 4 - .pi / 2
        let point = CGPoint(x: 160 + cos(angle) * 115, y: 160 + sin(angle) * 115)
        precondition(FavoriteEditorGeometry.position(at: point) == position)
    }
    precondition(FavoriteEditorGeometry.position(at: CGPoint(x: 160, y: 160)) == nil)
    precondition(FavoriteEditorGeometry.position(at: CGPoint(x: 160, y: 103)) == nil)
    precondition(FavoriteEditorGeometry.position(at: CGPoint(x: 320, y: 160)) == nil)
    precondition(FavoriteEditorGeometry.position(at: CGPoint(x: -10, y: 160)) == nil)
    print("Drag checks passed: move, swap, metadata, visibility, persistence, no duplicates, frozen gesture, invalid targets, eight drop sectors.")
    print("Favorite checks passed: directions, closed apps, overflow, duplicates, persistence, moving, removal, frozen gesture, missing app, conditional visibility, migration.")
}
