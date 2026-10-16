import Foundation

/// Owns CC Switch filesystem observation and write coalescing. The repository
/// remains the source of provider values; this module only reports that a
/// configuration read should be scheduled.
final class CCSwitchDatabaseWatcher {
    private let databaseURL: URL
    private let stateURL: URL?
    private let queueKey = DispatchSpecificKey<Void>()
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var isStarted = false

    private(set) var startCount = 0

    init(
        databaseURL: URL,
        stateURL: URL? = nil,
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.database-watcher"),
        onChange: @escaping () -> Void
    ) {
        self.databaseURL = databaseURL
        self.stateURL = stateURL
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() }
        else { queue.sync(execute: work) }
    }

    func start() {
        onQueue {
            guard !isStarted else { return }
            isStarted = true
            startCount += 1
            rearmWatchers()
        }
    }

    /// Directory observation survives atomic replacements and notices creation
    /// of a previously absent WAL/state file. Rearm after coalescing each batch.
    private func rearmWatchers() {
        watchers.forEach { $0.cancel() }
        let path = databaseURL.path
        var paths = [path, "\(path)-wal", databaseURL.deletingLastPathComponent().path]
        if let stateURL {
            paths += [stateURL.path, stateURL.deletingLastPathComponent().path]
            if !FileManager.default.fileExists(atPath: stateURL.deletingLastPathComponent().path) {
                paths.append(stateURL.deletingLastPathComponent().deletingLastPathComponent().path)
            }
        }
        watchers = Set(paths).sorted().compactMap(makeWatcher(for:))
    }

    func stop() {
        onQueue {
            isStarted = false
            syncWorkItem?.cancel()
            syncWorkItem = nil
            watchers.forEach { $0.cancel() }
            watchers.removeAll()
        }
    }

    private func makeWatcher(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleImmediateSync() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleImmediateSync() {
        guard isStarted else { return }
        syncWorkItem?.cancel()
        SwitchLog.write(
            "CC Switch database change observed; coalescing refresh",
            level: .debug,
            category: "database",
            throttleKey: "database-change",
            minimumInterval: 2
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.rearmWatchers()
            self.onChange()
        }
        syncWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    deinit { stop() }
}
