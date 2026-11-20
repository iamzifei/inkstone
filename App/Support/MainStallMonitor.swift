#if DEBUG
import Foundation

/// Measures how long the main thread is blocked, for before/after numbers on
/// animation jank. Debug builds only; started by `INKSTONE_STALL_OUT=<file>`.
///
/// A background thread asks the main queue to run an empty block every 4 ms
/// and times how long that takes. When the main thread is free the answer is
/// well under a millisecond; when it is busy (parsing, laying out text,
/// decoding images) the answer is the length of the busy stretch — which is
/// exactly the time an animation would have stood still.
///
/// Segments are marked by DemoDirector (`stall-mark <label>`, `stall-report`),
/// so a scripted run of note switches, typing or organizing produces one line
/// per segment in the output file:
///
///     label  frames-over-16.7ms  longest-ms  blocked-ms-beyond-a-frame  last-event-ms
///
/// `last-event-ms` is when, after the segment started, the last `event()` was
/// recorded (0 if none): for work that finishes off the main thread, such as
/// diagrams rendering, the time until it was all on screen.
final class MainStallMonitor: @unchecked Sendable {
    static let shared = MainStallMonitor()

    /// One 60 Hz frame. A main-thread stretch longer than this drops a frame.
    private let frame: Double = 1.0 / 60.0
    private let lock = NSLock()
    private var label = "start"
    private var over = 0          // probes that waited longer than one frame
    private var longest = 0.0     // longest single wait, seconds
    private var blocked = 0.0     // sum of (wait - frame) over the long waits
    private var segmentStart = DispatchTime.now().uptimeNanoseconds
    private var lastEvent: Double = 0  // seconds after segmentStart
    private var outURL: URL?
    private var thread: Thread?
    /// Held for the life of the process: without it a Mac app launched in the
    /// background is App-Napped, its main queue is woken late, and the monitor
    /// reports the nap as a stall (measured: ~9.6 s "blocked" over a segment in
    /// which `sample` saw the main thread idle 90% of the time).
    private var activity: NSObjectProtocol?

    func startIfRequested() {
        guard thread == nil, let path = ProcessInfo.processInfo.environment["INKSTONE_STALL_OUT"] else { return }
        outURL = URL(fileURLWithPath: path)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Main-thread stall benchmark")
        let thread = Thread { [unowned self] in self.loop() }
        thread.qualityOfService = .userInteractive
        thread.name = "MainStallMonitor"
        self.thread = thread
        thread.start()
    }

    private func loop() {
        let done = DispatchSemaphore(value: 0)
        while true {
            let start = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { done.signal() }
            done.wait()
            let wait = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if wait > frame {
                lock.lock()
                over += 1
                longest = max(longest, wait)
                blocked += wait - frame
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    /// Starts a new segment; what was measured so far is discarded.
    func mark(_ label: String) {
        lock.lock()
        self.label = label
        over = 0; longest = 0; blocked = 0
        segmentStart = DispatchTime.now().uptimeNanoseconds; lastEvent = 0
        lock.unlock()
    }

    /// Records that a piece of asynchronous work finished now.
    func event() {
        lock.lock()
        lastEvent = Double(DispatchTime.now().uptimeNanoseconds - segmentStart) / 1e9
        lock.unlock()
    }

    /// Appends the current segment's numbers to the output file.
    func report() {
        lock.lock()
        let line = String(format: "%@\t%d\t%.1f\t%.1f\t%.0f\n", label, over, longest * 1000, blocked * 1000, lastEvent * 1000)
        lock.unlock()
        guard let outURL else { return }
        if let handle = try? FileHandle(forWritingTo: outURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: outURL)
        }
    }
}
#endif
