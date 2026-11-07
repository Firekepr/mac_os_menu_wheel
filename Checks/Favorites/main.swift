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
    print("Favorite checks passed: directions, closed apps, overflow, duplicates, persistence, moving, removal, frozen gesture, missing app.")
}
