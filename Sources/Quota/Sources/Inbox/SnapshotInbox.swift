import Foundation

/// Tunables for the snapshot inbox; defaults follow the Schema v1 inbox rules.
public struct SnapshotInboxConfiguration: Equatable {
    /// Delay before re-reading a file that failed to parse (a Mod may still be writing it).
    public var halfWriteRetryDelay: TimeInterval

    /// Files in the inbox directory not modified for this long are removed.
    public var retention: TimeInterval

    public var io: QuotaIOConfiguration

    public init(
        halfWriteRetryDelay: TimeInterval = 0.1,
        retention: TimeInterval = 24 * 3_600,
        io: QuotaIOConfiguration = .default
    ) {
        self.halfWriteRetryDelay = halfWriteRetryDelay
        self.retention = retention
        self.io = io
    }

    public static let `default` = Self()
}

/// Watches the snapshot inbox (and adapter-discovered paths) and emits `QuotaObservation`s.
///
/// All file access and callbacks run on a private serial background queue. Every file is
/// read through `SafeFileValidator`; windows that fail validation are dropped individually.
public final class SnapshotInbox: QuotaSource {
    /// Default inbox location: `~/Library/Application Support/BalanceBar/inbox/`.
    public static func defaultInboxDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BalanceBar", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    public let sourceID = "snapshot-inbox"

    private let inboxDirectory: URL
    private let adapters: [QuotaSourceAdapter]
    private let identity: AccountIdentityProviding
    private let configuration: SnapshotInboxConfiguration
    private let now: () -> Date
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "BalanceBar.SnapshotInbox", qos: .utility)
    private let watcherQueue = DispatchQueue(label: "BalanceBar.SnapshotInbox.Watcher", qos: .utility)

    private var handler: ((QuotaObservation) -> Void)?
    private var watchers: [DirectoryWatcher] = []
    private var generation = 0

    /// - Parameters:
    ///   - inboxDirectory: Directory holding Schema v1 files; created on start when missing.
    ///   - adapters: Extra adapters; a default Schema v1 adapter for the inbox is always added first.
    public init(
        inboxDirectory: URL = SnapshotInbox.defaultInboxDirectory(),
        adapters: [QuotaSourceAdapter] = [],
        identity: AccountIdentityProviding,
        configuration: SnapshotInboxConfiguration = .default,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.inboxDirectory = inboxDirectory.standardizedFileURL
        self.adapters = [SchemaV1InboxAdapter(directory: inboxDirectory)] + adapters
        self.identity = identity
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    deinit { stop() }

    public func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        stop()
        queue.sync {
            self.handler = handler
            try? fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        }
        let roots = Set(adapters.flatMap(watchRoots(for:)).map(\.path)).sorted()
            .filter { fileManager.fileExists(atPath: $0) }
        let created: [DirectoryWatcher] = roots.compactMap { path in
            let watcher = DirectoryWatcher(
                directory: URL(fileURLWithPath: path), configuration: configuration.io, queue: watcherQueue
            ) { [weak self] paths in self?.queue.async { self?.process(paths: paths) } }
            return watcher.start() ? watcher : nil
        }
        queue.sync { watchers = created }
        queue.async { [weak self] in self?.scanAll() }
    }

    public func stop() {
        let toStop: [DirectoryWatcher] = queue.sync {
            generation += 1
            handler = nil
            defer { watchers = [] }
            return watchers
        }
        toStop.forEach { $0.stop() }
    }

    /// Rescans every discovered path. Runs on the inbox queue.
    func scanAll() {
        var paths: Set<String> = []
        for adapter in adapters {
            for url in adapter.discoverPaths() { paths.formUnion(files(under: url)) }
        }
        process(paths: paths)
    }

    /// Processes changed paths. Runs on the inbox queue.
    func process(paths: Set<String>) {
        removeExpiredFiles()
        for path in paths.sorted() {
            guard let adapter = adapter(for: path) else { continue }
            read(path: path, adapter: adapter, allowRetry: true, generation: generation)
        }
    }

    // MARK: Reading

    private func read(path: String, adapter: QuotaSourceAdapter, allowRetry: Bool, generation expected: Int) {
        guard expected == generation, handler != nil else { return }
        let url = URL(fileURLWithPath: path)
        guard !url.lastPathComponent.hasPrefix("."), isRegularFile(url) else { return }

        let validator = SafeFileValidator(
            allowedDirectories: adapters.flatMap(watchRoots(for:)),
            maximumFileSize: QuotaConstants.snapshotMaximumSizeBytes
        )
        let parsed: ParsedQuotaSnapshot
        do {
            let raw = try validator.readValidatedFile(at: url)
            parsed = try QuotaSnapshotParser.parse(try adapter.convert(raw))
        } catch let error as SafeFileValidationError {
            adapter.health = .degraded(reason: "rejected file: \(error)")
            return
        } catch {
            // Malformed or empty content is most likely a half-written file: re-read once.
            if allowRetry {
                queue.asyncAfter(deadline: .now() + configuration.halfWriteRetryDelay) { [weak self] in
                    self?.read(path: path, adapter: adapter, allowRetry: false, generation: expected)
                }
            } else {
                adapter.health = .degraded(reason: "unreadable snapshot: \(error)")
            }
            return
        }
        emit(parsed, adapter: adapter)
    }

    private func emit(_ parsed: ParsedQuotaSnapshot, adapter: QuotaSourceAdapter) {
        guard let account = identity.accountIdentity else {
            adapter.health = .degraded(reason: "no active account")
            return
        }
        let epoch = identity.accountEpoch
        let source = parsed.source.flatMap { $0 == "unknown" ? nil : $0 } ?? adapter.sourceID
        let received = now()
        for window in parsed.windows {
            guard let observation = QuotaObservation(
                window: window.kind,
                usedPercentage: window.usedPercentage,
                resetsAt: window.resetsAt,
                observedAt: parsed.updatedAt,
                receivedAt: received,
                source: source,
                trust: adapter.trust,
                accountID: account.stableID,
                epoch: epoch
            ) else { continue }
            handler?(observation)
        }
        adapter.health = parsed.discarded.isEmpty ? .healthy : .degraded(reason: parsed.discarded.joined(separator: "; "))
    }

    // MARK: Paths

    private func watchRoots(for adapter: QuotaSourceAdapter) -> [URL] {
        adapter.discoverPaths().map { url in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue ? url.deletingLastPathComponent() : url
        }
    }

    private func files(under url: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url.path] }
        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.map { url.appendingPathComponent($0).path }
    }

    private func adapter(for path: String) -> QuotaSourceAdapter? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return adapters.last { adapter in
            adapter.discoverPaths().contains { discovered in
                let base = discovered.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                return target == base || (target.count > base.count && Array(target.prefix(base.count)) == base)
            }
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    // MARK: Cleanup

    /// Removes inbox files whose session ended (no modification) longer than the retention period ago.
    /// Only the inbox directory itself is cleaned, never paths owned by other producers.
    private func removeExpiredFiles() {
        let cutoff = now().addingTimeInterval(-configuration.retention)
        let urls = (try? fileManager.contentsOfDirectory(
            at: inboxDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
