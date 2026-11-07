import Foundation
import Darwin

/// A sum of per-process physical footprints, not a measure of unique RAM pages.
struct AppMemoryUsage: Equatable, Sendable {
    let bytes: UInt64
    let processCount: Int
    let isPartial: Bool

    var formatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    var help: String {
        "Estimativa de memória de \(processCount) processo(s), incluindo auxiliares identificados. "
        + "Memória compartilhada pode ser contada mais de uma vez."
        + (isPartial ? " Alguns processos não puderam ser consultados." : "")
    }
}

enum AppMemory {
    struct Process: Sendable {
        let id: pid_t
        let parentID: pid_t
        let executablePath: String?
    }

    /// Include helpers inside the bundle even when launchd has reparented them,
    /// plus descendants. A set ensures that a helper is counted only once.
    static func processIDs(root: pid_t, bundlePath: String?, processes: [Process]) -> Set<pid_t> {
        var result: Set<pid_t> = [root]
        if let bundlePath {
            let prefix = URL(fileURLWithPath: bundlePath).standardizedFileURL.path + "/"
            for process in processes where process.executablePath?.hasPrefix(prefix) == true {
                result.insert(process.id)
            }
        }
        var changed = true
        while changed {
            changed = false
            for process in processes where !result.contains(process.id) && result.contains(process.parentID) {
                result.insert(process.id)
                changed = true
            }
        }
        return result
    }

    static func sample(root: pid_t, bundlePath: String?) -> AppMemoryUsage? {
        guard !Task.isCancelled, let rootBytes = footprint(of: root) else { return nil }
        let capacity = max(Int(proc_listallpids(nil, 0)) + 128, 256)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else {
            return AppMemoryUsage(bytes: rootBytes, processCount: 1, isPartial: true)
        }
        var processes: [Process] = []
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            guard !Task.isCancelled else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { continue }
            // PROC_PIDPATHINFO_MAXSIZE is a C macro not imported into Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            processes.append(Process(id: pid, parentID: pid_t(info.pbi_ppid),
                                     executablePath: length > 0 ? String(cString: path) : nil))
        }
        let ids = processIDs(root: root, bundlePath: bundlePath, processes: processes)
        var bytes = rootBytes
        var measured = 1
        for pid in ids where pid != root {
            guard !Task.isCancelled else { return nil }
            if let footprint = footprint(of: pid) {
                bytes += footprint
                measured += 1
            }
        }
        // The application may have quit while its helpers were being sampled.
        guard footprint(of: root) != nil else { return nil }
        return AppMemoryUsage(bytes: bytes, processCount: measured,
                              isPartial: measured < ids.count || Int(count) >= capacity)
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }
}
