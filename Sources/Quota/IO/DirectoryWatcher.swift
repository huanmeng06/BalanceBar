import AppKit
import CoreServices
import Foundation

/// Watches one directory with FSEvents and reports coalesced batches of changed paths.
///
/// Watching the directory (not individual files) keeps notifications flowing
/// after atomic `rename` replacement. Events within `watchCoalescingInterval`
/// are merged into one callback. After the system wakes, a single catch-up
/// notification containing the directory path is delivered so callers rescan
/// anything missed during sleep. All work and callbacks run on a background queue.
public final class DirectoryWatcher {
    public typealias Handler = (Set<String>) -> Void

    public let directory: URL
    private let coalescingInterval: TimeInterval
    private let queue: DispatchQueue
    private let handler: Handler
    private let notificationCenter: NotificationCenter

    private var stream: FSEventStreamRef?
    private var wakeObserver: NSObjectProtocol?
    private var pendingPaths: Set<String> = []
    private var flushScheduled = false
    private var generation = 0

    /// - Parameters:
    ///   - directory: Directory to watch recursively.
    ///   - configuration: Supplies the coalescing interval.
    ///   - queue: Serial background queue for FSEvents and the handler.
    ///   - notificationCenter: Source of `NSWorkspace.didWakeNotification`; injectable for tests.
    ///   - handler: Receives the set of changed paths after coalescing.
    public init(
        directory: URL,
        configuration: QuotaIOConfiguration = .default,
        queue: DispatchQueue = DispatchQueue(label: "BalanceBar.DirectoryWatcher", qos: .utility),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        handler: @escaping Handler
    ) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.coalescingInterval = configuration.watchCoalescingInterval
        self.queue = queue
        self.notificationCenter = notificationCenter
        self.handler = handler
    }

    deinit {
        stopLocked()
    }

    /// Starts watching. Returns `false` when the FSEvents stream cannot be created.
    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                watcher.enqueue(Set(array.prefix(count)))
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                nil, callback, &context, [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            let directoryPath = directory.path
            wakeObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.enqueue([directoryPath]) }
            }
            return true
        }
    }

    /// Stops watching and drops pending notifications. Safe to call repeatedly.
    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        generation += 1
        pendingPaths.removeAll()
        flushScheduled = false
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// Must be called on `queue`.
    private func enqueue(_ paths: Set<String>) {
        guard stream != nil, !paths.isEmpty else { return }
        pendingPaths.formUnion(paths)
        guard !flushScheduled else { return }
        flushScheduled = true
        let scheduledGeneration = generation
        queue.asyncAfter(deadline: .now() + coalescingInterval) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.flushScheduled = false
            let batch = self.pendingPaths
            self.pendingPaths.removeAll()
            if !batch.isEmpty { self.handler(batch) }
        }
    }
}
