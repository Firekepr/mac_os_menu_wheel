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
    print("Favorite checks passed: directions, closed apps, overflow, duplicates, persistence, moving, removal, frozen gesture, missing app, conditional visibility, migration.")
}
