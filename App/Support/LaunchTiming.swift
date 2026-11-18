import Foundation
import os

/// Launch milestones, measured from process start, for tuning start-up time.
///
///     INKSTONE_LAUNCH_TIMING=1 Inkstone            # prints each milestone once
///     INKSTONE_LAUNCH_TIMING=exit Inkstone         # …and quits when the index is ready
///
/// Also emitted as signposts ("Launch" category) so Instruments shows them on
/// a device, where nobody can read stderr. Off by default: one cached flag.
enum LaunchTiming {
    private static let mode = ProcessInfo.processInfo.environment["INKSTONE_LAUNCH_TIMING"]
    private static let log = OSLog(subsystem: "com.orris.inkstone", category: "Launch")
    nonisolated(unsafe) private static var seen: Set<String> = []
    private static let lock = NSLock()

    /// Seconds since the kernel started this process.
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    /// Records `name` the first time it happens.
    static func mark(_ name: String) {
        lock.lock()
        let isFirst = seen.insert(name).inserted
        lock.unlock()
        guard isFirst else { return }
        os_signpost(.event, log: log, name: "Launch", "%{public}s", name)
        guard let mode else { return }
        let ms = sinceProcessStart() * 1000
        FileHandle.standardError.write(Data(String(format: "[launch] %7.0f ms  %@\n", ms, name).utf8))
        if mode == "exit", name == "index ready" { exit(0) }
    }
}
