#if os(iOS)
import Foundation
import os

/// A durable record of what the background scheduler actually did.
///
/// The reason this file exists: before it, a background sync that never ran once
/// and a background sync that ran perfectly produced *identical* evidence —
/// nothing. `BGTaskScheduler` reports no failures, logs nothing, and the app is
/// not running to notice it was not woken. Every question about it ("is it
/// registered?", "did iOS ever call us?", "did the run finish or expire?") was
/// answerable only by guessing.
///
/// Entries are written from a background launch, which is a *different process
/// run* from the foreground one, so this has to survive process death: it goes
/// to `UserDefaults`, not to memory. It is also mirrored to `os_log` so a device
/// attached to Console shows the same story.
///
/// Deliberately small. It is not analytics and it does not leave the device; it
/// is the answer to "did the OS wake us", kept where the user can read it.
enum BackgroundSyncLog {
    /// How many entries are kept. A background run writes two or three, so this
    /// is roughly the last week of activity on a device that gets woken a few
    /// times a day — enough to see a pattern, small enough to stay in defaults.
    private static let limit = 40

    private static let key = "backgroundSyncLog"
    private static let logger = Logger(subsystem: "com.orris.inkstone", category: "BackgroundSync")

    /// What happened. The raw values are stored, so renaming a case rewrites
    /// history — add cases rather than renaming them.
    enum Event: String, Codable {
        /// A request was handed to the scheduler.
        case scheduled
        /// The scheduler refused the request.
        case scheduleFailed
        /// iOS launched us to run the task. This is the line whose *absence*
        /// answers the whole question.
        case launched
        /// The handler ran but declined to sync, with a reason.
        case skipped
        /// A sync ran to completion in the background.
        case finished
        /// A sync failed in the background.
        case failed
        /// The system took the time back before the sync was done.
        case expired
    }

    struct Entry: Codable, Identifiable {
        let date: Date
        let event: Event
        /// Task identifier, error text, or the reason a run was skipped.
        let detail: String

        var id: Date { date }
    }

    static func record(_ event: Event, _ detail: String = "") {
        logger.info("\(event.rawValue, privacy: .public) \(detail, privacy: .public)")

        var entries = self.entries
        entries.append(Entry(date: Date(), event: event, detail: detail))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Oldest first.
    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    /// The last time iOS actually launched the app to sync, as opposed to the
    /// last time the app *asked* to be launched. The distinction is the entire
    /// point: `nil` here with a full log of `scheduled` entries means the
    /// requests are being made and the system is not honouring them.
    static var lastLaunch: Date? {
        entries.last(where: { $0.event == .launched })?.date
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
#endif
