import Foundation
import Darwin

let processes: [AppMemory.Process] = [
    .init(id: 1, parentID: 0, executablePath: "/sbin/launchd"),
    .init(id: 10, parentID: 1, executablePath: "/Apps/Music.app/Contents/MacOS/Music"),
    // Reparented helper still belongs to the bundle.
    .init(id: 11, parentID: 1, executablePath: "/Apps/Music.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
    .init(id: 12, parentID: 10, executablePath: "/usr/bin/helper"),
    // Grandchild precedes its parent to exercise transitive grouping.
    .init(id: 14, parentID: 13, executablePath: nil),
    .init(id: 13, parentID: 11, executablePath: nil),
    .init(id: 20, parentID: 1, executablePath: "/Apps/Music.app.backup/Contents/MacOS/Music"),
    .init(id: 21, parentID: 1, executablePath: "/Apps/Other.app/Contents/MacOS/Other"),
]
precondition(AppMemory.processIDs(root: 10, bundlePath: "/Apps/Music.app", processes: processes)
             == [10, 11, 12, 13, 14], "Helpers must be included once without matching neighboring bundles")
precondition(AppMemory.processIDs(root: 10, bundlePath: nil, processes: processes) == [10, 12])
precondition(AppMemory.processIDs(root: 99, bundlePath: nil, processes: []) == [99])
precondition(AppMemory.sample(root: -1, bundlePath: nil) == nil, "An unreadable process must not appear as zero RAM")

// Allocate and touch memory to verify an actual footprint rather than a stub.
let allocation = UnsafeMutableRawPointer.allocate(byteCount: 8 * 1024 * 1024, alignment: 4096)
allocation.initializeMemory(as: UInt8.self, repeating: 42, count: 8 * 1024 * 1024)
defer { allocation.deallocate() }
let usage = AppMemory.sample(root: getpid(), bundlePath: nil)!
precondition(usage.bytes > 0 && usage.processCount >= 1)
precondition(!usage.formatted.isEmpty)
let helper = Process()
helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
helper.arguments = ["30"]
try helper.run()
defer { helper.terminate(); helper.waitUntilExit() }
let helperUsage = AppMemory.sample(root: helper.processIdentifier, bundlePath: nil)!
precondition(helperUsage.bytes > 0, "Must be able to read another same-user process")
let grouped = AppMemory.sample(root: getpid(), bundlePath: nil)!
precondition(grouped.processCount >= 2, "Live child process must be included")
print("Memory checks passed: bundle helpers, descendants, deduplication, path boundaries, missing processes, live footprint (\(usage.formatted)).")
