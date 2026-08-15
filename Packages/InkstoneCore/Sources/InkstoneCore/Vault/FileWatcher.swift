import Foundation
import os

/// Watches a vault folder for external changes (iCloud sync landing new files,
/// a `git pull`, or the user editing in another app) and reports coalesced
/// change notifications.
///
/// Uses one `DispatchSource` per directory because kqueue-backed sources are not
/// recursive. Events are debounced: a sync run can touch hundreds of files and we
/// only want a single re-scan at the end.
public final class VaultWatcher: @unchecked Sendable {
    private struct Watch {
        let source: any DispatchSourceFileSystemObject
        let descriptor: Int32
    }

    private let root: URL
    private let queue = DispatchQueue(label: "com.orris.inkstone.watcher", qos: .utility)
    private var watches: [URL: Watch] = [:]
    private var debounceItem: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.orris.inkstone", category: "VaultWatcher")

    /// - Parameter onChange: called on a background queue after changes settle.
    public init(root: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    deinit { stopAll() }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.watchRecursively(self.root)
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopAll() }
    }

    // MARK: - Internals

    private func watchRecursively(_ directory: URL) {
        watch(directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory, !VaultScanner.ignoredDirectories.contains(entry.lastPathComponent) else { continue }
            watchRecursively(entry)
        }
    }

    private func watch(_ directory: URL) {
        guard watches[directory] == nil else { return }
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            logger.debug("Could not open \(directory.lastPathComponent, privacy: .public) for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleNotification() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watches[directory] = Watch(source: source, descriptor: descriptor)
    }

    /// Collapses a burst of filesystem events into one callback.
    private func scheduleNotification() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // New sub-folders may have appeared; pick them up before notifying.
            self.watchRecursively(self.root)
            self.onChange()
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func stopAll() {
        debounceItem?.cancel()
        for (_, watch) in watches { watch.source.cancel() }
        watches.removeAll()
    }
}
