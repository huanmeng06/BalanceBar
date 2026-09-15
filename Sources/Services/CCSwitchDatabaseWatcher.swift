import Foundation

/// Owns CC Switch filesystem observation and write coalescing. The repository
/// remains the source of provider values; this module only reports that a
/// configuration read should be scheduled.
final class CCSwitchDatabaseWatcher {
    private let databaseURL: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var isStarted = false

    private(set) var startCount = 0

    init(
        databaseURL: URL,
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.database-watcher"),
        onChange: @escaping () -> Void
    ) {
        self.databaseURL = databaseURL
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startCount += 1
        let databasePath = databaseURL.path
        let directory = databaseURL.deletingLastPathComponent().path
        watchers = [databasePath, "\(databasePath)-wal", directory]
            .compactMap(makeWatcher(for:))
    }

    func stop() {
        syncWorkItem?.cancel()
        syncWorkItem = nil
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        isStarted = false
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
        syncWorkItem?.cancel()
        SwitchLog.write(
            "CC Switch database change observed; coalescing refresh",
            level: .debug,
            category: "database",
            throttleKey: "database-change",
            minimumInterval: 2
        )
        let workItem = DispatchWorkItem { [weak self] in self?.onChange() }
        syncWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    deinit { stop() }
}
