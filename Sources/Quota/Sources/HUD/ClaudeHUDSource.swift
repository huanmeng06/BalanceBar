import Foundation

/// What BalanceBar found when it looked at the Claude HUD installation.
public enum ClaudeHUDExportStatus: Equatable {
    /// `~/.claude/plugins/claude-hud/config.json` does not exist.
    case notInstalled

    /// HUD is installed but `display.externalUsageWritePath` is not configured.
    case exportDisabled

    /// The configuration exists but cannot be used.
    case configUnusable(reason: String)

    /// HUD exports usage snapshots to `path`.
    case exporting(path: URL)
}

/// State shown on the diagnostics page.
public struct ClaudeHUDDiagnostics: Equatable {
    public let status: ClaudeHUDExportStatus
    public let health: QuotaAdapterHealth

    /// Shown when HUD is installed without export. BalanceBar never edits the HUD configuration.
    public var configurationExample: String? {
        switch status {
        case .exportDisabled, .configUnusable: return ClaudeHUDSource.configurationExample
        case .notInstalled, .exporting: return nil
        }
    }
}

/// Headless signal for the Mod onboarding UI (BB-15): how long Claude transcripts were being
/// written while the HUD snapshot was not being updated (for example during `claude -p`).
public protocol ClaudeHUDHeadlessSignaling: AnyObject {
    /// Accumulated headless duration since start or the last reset.
    var headlessDuration: TimeInterval { get }

    /// Starts a new accumulation period.
    func resetHeadlessDuration()
}

/// Tunables for the Claude HUD source.
struct ClaudeHUDConfiguration: Equatable {
    /// A snapshot update this recent counts as "HUD is alive" for a transcript write.
    var snapshotLiveness: TimeInterval = 30

    /// Longest gap between transcript writes still counted as continuous activity.
    var maximumActivityGap: TimeInterval = 60

    var maximumConfigSize = 64 * 1_024
    var halfWriteRetryDelay: TimeInterval = 0.1
}

/// Reads the real-time usage snapshot exported by Claude HUD as a grade-B source.
///
/// The export path is discovered from the HUD `config.json` and re-discovered whenever that file
/// changes, so the source follows add/modify/remove without a restart. Nothing in the HUD or
/// Claude configuration is ever written. All IO runs on a private utility queue.
public final class ClaudeHUDSource: QuotaSource, ClaudeHUDHeadlessSignaling {
    public static let identifier = "claude-hud"

    public static let configurationExample = """
    {
      "display": {
        "externalUsageWritePath": "~/Library/Application Support/BalanceBar/inbox/claude-hud.json"
      }
    }
    """

    public var sourceID: String { Self.identifier }

    private let hudDirectory: URL
    private let transcriptsDirectory: URL
    private let accountProvider: AccountIdentityProviding
    private let configuration: ClaudeHUDConfiguration
    private let ioConfiguration: QuotaIOConfiguration
    private let now: () -> Date
    private let queue = DispatchQueue(label: "BalanceBar.ClaudeHUDSource", qos: .utility)
    private let watcherQueue = DispatchQueue(label: "BalanceBar.ClaudeHUDSource.Watcher", qos: .utility)

    private var handler: ((QuotaObservation) -> Void)?
    private var configWatcher: DirectoryWatcher?
    private var exportWatcher: DirectoryWatcher?
    private var transcriptWatcher: DirectoryWatcher?
    private var generation = 0
    private var status: ClaudeHUDExportStatus = .notInstalled
    private var health: QuotaAdapterHealth = .unavailable(reason: "not started")
    private var lastSnapshotUpdate: Date?
    private var lastTranscriptActivity: Date?

    private let stateLock = NSLock()
    private var publishedDiagnostics = ClaudeHUDDiagnostics(
        status: .notInstalled, health: .unavailable(reason: "not started")
    )
    private var headless: TimeInterval = 0

    public convenience init(accountProvider: AccountIdentityProviding) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            hudDirectory: home.appendingPathComponent(".claude/plugins/claude-hud", isDirectory: true),
            transcriptsDirectory: home.appendingPathComponent(".claude/projects", isDirectory: true),
            accountProvider: accountProvider
        )
    }

    init(
        hudDirectory: URL,
        transcriptsDirectory: URL,
        accountProvider: AccountIdentityProviding,
        configuration: ClaudeHUDConfiguration = ClaudeHUDConfiguration(),
        ioConfiguration: QuotaIOConfiguration = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.hudDirectory = hudDirectory.standardizedFileURL
        self.transcriptsDirectory = transcriptsDirectory.standardizedFileURL
        self.accountProvider = accountProvider
        self.configuration = configuration
        self.ioConfiguration = ioConfiguration
        self.now = now
    }

    deinit { stopWatchers() }

    // MARK: Public state

    /// Latest discovery status and health; safe from any thread.
    public var diagnostics: ClaudeHUDDiagnostics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return publishedDiagnostics
    }

    public var headlessDuration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return headless
    }

    public func resetHeadlessDuration() {
        stateLock.lock()
        headless = 0
        stateLock.unlock()
    }

    // MARK: QuotaSource

    public func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        queue.async { [self] in
            stopWatchersLocked()
            generation += 1
            self.handler = handler
            let token = generation
            configWatcher = makeWatcher(root: hudDirectory) { [weak self] paths in
                self?.queue.async { self?.handleConfigEvents(paths, generation: token) }
            }
            transcriptWatcher = makeWatcher(root: transcriptsDirectory) { [weak self] paths in
                self?.queue.async { self?.handleTranscriptEvents(paths, generation: token) }
            }
            reload()
        }
    }

    public func stop() {
        queue.sync { stopWatchersLocked() }
    }

    private func stopWatchers() {
        let watchers = [configWatcher, exportWatcher, transcriptWatcher]
        configWatcher = nil
        exportWatcher = nil
        transcriptWatcher = nil
        watchers.forEach { $0?.stop() }
    }

    private func stopWatchersLocked() {
        generation += 1
        handler = nil
        stopWatchers()
    }

    // MARK: Discovery

    /// Re-reads the HUD configuration and adds, moves or removes the snapshot watch accordingly.
    /// Must run on `queue`.
    func reload() {
        let previous = status
        status = Self.discover(
            hudDirectory: hudDirectory, maximumSize: configuration.maximumConfigSize
        )
        if case let .exporting(path) = status {
            if status != previous || exportWatcher == nil {
                exportWatcher?.stop()
                exportWatcher = nil
                lastSnapshotUpdate = nil
                let token = generation
                let exportPath = Self.resolved(path).path
                exportWatcher = makeWatcher(root: path.deletingLastPathComponent()) { [weak self] paths in
                    self?.queue.async { self?.handleExportEvents(paths, exportPath: exportPath, generation: token) }
                }
                readSnapshot(at: path, allowRetry: true, generation: token)
            }
        } else {
            exportWatcher?.stop()
            exportWatcher = nil
            lastSnapshotUpdate = nil
            health = status == .notInstalled
                ? .unavailable(reason: "Claude HUD is not installed")
                : .unavailable(reason: "Claude HUD usage export is not enabled")
        }
        publish()
    }

    static func discover(hudDirectory: URL, maximumSize: Int) -> ClaudeHUDExportStatus {
        let configURL = hudDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .notInstalled }
        let data: Data
        do {
            data = try SafeFileValidator(allowedDirectories: [hudDirectory], maximumFileSize: maximumSize)
                .readValidatedFile(at: configURL)
        } catch {
            return .configUnusable(reason: "config.json rejected: \(error)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .configUnusable(reason: "config.json is not a JSON object")
        }
        guard let raw = (root["display"] as? [String: Any])?["externalUsageWritePath"] else {
            return .exportDisabled
        }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (raw is NSNull) ? .exportDisabled : .configUnusable(reason: "externalUsageWritePath is not a path")
        }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .configUnusable(reason: "externalUsageWritePath must be absolute")
        }
        return .exporting(path: URL(fileURLWithPath: expanded).standardizedFileURL)
    }

    // MARK: Events

    private func handleConfigEvents(_ paths: Set<String>, generation token: Int) {
        guard token == generation, handler != nil,
              paths.contains(where: { Self.related($0, to: hudDirectory) }) else { return }
        reload()
    }

    private func handleExportEvents(_ paths: Set<String>, exportPath: String, generation token: Int) {
        guard token == generation, handler != nil, case let .exporting(path) = status else { return }
        let target = URL(fileURLWithPath: exportPath).pathComponents
        guard paths.contains(where: { event in
            let parts = Self.resolved(URL(fileURLWithPath: event)).pathComponents
            return parts == target || (parts.count < target.count && Array(target.prefix(parts.count)) == parts)
        }) else { return }
        readSnapshot(at: path, allowRetry: true, generation: token)
    }

    private func handleTranscriptEvents(_ paths: Set<String>, generation token: Int) {
        guard token == generation, handler != nil,
              paths.contains(where: { $0.hasSuffix(".jsonl") && Self.related($0, to: transcriptsDirectory) }) else { return }
        recordTranscriptActivity(at: now())
    }

    // MARK: Snapshot

    private func readSnapshot(at path: URL, allowRetry: Bool, generation token: Int) {
        guard token == generation, handler != nil else { return }
        let validator = SafeFileValidator(
            allowedDirectories: [path.deletingLastPathComponent()],
            maximumFileSize: QuotaConstants.snapshotMaximumSizeBytes
        )
        let parsed: ParsedQuotaSnapshot
        do {
            guard FileManager.default.fileExists(atPath: path.path) else {
                health = .unavailable(reason: "snapshot file does not exist yet")
                publish()
                return
            }
            parsed = try QuotaSnapshotParser.parse(try validator.readValidatedFile(at: path))
        } catch let error as SafeFileValidationError {
            health = .degraded(reason: "rejected file: \(error)")
            publish()
            return
        } catch {
            // Most likely half-written: re-read once.
            if allowRetry {
                queue.asyncAfter(deadline: .now() + configuration.halfWriteRetryDelay) { [weak self] in
                    self?.readSnapshot(at: path, allowRetry: false, generation: token)
                }
            } else {
                health = .degraded(reason: "unreadable snapshot: \(error)")
                publish()
            }
            return
        }
        let received = now()
        lastSnapshotUpdate = received
        emit(parsed, receivedAt: received)
    }

    private func emit(_ parsed: ParsedQuotaSnapshot, receivedAt: Date) {
        guard let account = accountProvider.accountIdentity else {
            health = .degraded(reason: "no active account")
            publish()
            return
        }
        let epoch = accountProvider.accountEpoch
        for window in parsed.windows {
            // `updated_at` reflects HUD's cache, not when Claude reported usage, so observedAt stays unknown.
            guard let observation = QuotaObservation(
                window: window.kind,
                usedPercentage: window.usedPercentage,
                resetsAt: window.resetsAt,
                observedAt: nil,
                receivedAt: receivedAt,
                source: Self.identifier,
                trust: .b,
                accountID: account.stableID,
                epoch: epoch
            ) else { continue }
            handler?(observation)
        }
        health = parsed.discarded.isEmpty ? .healthy : .degraded(reason: parsed.discarded.joined(separator: "; "))
        publish()
    }

    // MARK: Headless accounting

    /// Counts transcript activity that happens while the HUD snapshot is not being refreshed.
    /// Must run on `queue`.
    func recordTranscriptActivity(at date: Date) {
        defer { lastTranscriptActivity = date }
        guard case .exporting = status, let previous = lastTranscriptActivity, date > previous else { return }
        let hudAlive = lastSnapshotUpdate.map { date.timeIntervalSince($0) <= configuration.snapshotLiveness } ?? false
        guard !hudAlive else { return }
        let increment = min(date.timeIntervalSince(previous), configuration.maximumActivityGap)
        stateLock.lock()
        headless += increment
        stateLock.unlock()
    }

    // MARK: Helpers

    private func publish() {
        stateLock.lock()
        publishedDiagnostics = ClaudeHUDDiagnostics(status: status, health: health)
        stateLock.unlock()
    }

    /// Watches `root`, or its nearest existing ancestor while it does not exist yet.
    private func makeWatcher(root: URL, handler: @escaping DirectoryWatcher.Handler) -> DirectoryWatcher? {
        var target = root
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        let watcher = DirectoryWatcher(
            directory: target, configuration: ioConfiguration, queue: watcherQueue, handler: handler
        )
        return watcher.start() ? watcher : nil
    }

    /// Resolves symlinks of the nearest existing ancestor so FSEvents paths compare equal.
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return tail.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// `true` when `path` is inside `directory` or is one of its ancestors.
    static func related(_ path: String, to directory: URL) -> Bool {
        let event = resolved(URL(fileURLWithPath: path)).pathComponents
        let base = resolved(directory).pathComponents
        let count = min(event.count, base.count)
        return Array(event.prefix(count)) == Array(base.prefix(count))
    }

    // MARK: Test hooks

    /// Processes a config change (rediscovery) or a snapshot change as the watchers would, synchronously.
    func rescan(configChanged: Bool = false, handler: @escaping (QuotaObservation) -> Void) {
        queue.sync {
            self.handler = handler
            if configChanged {
                reload()
            } else if case let .exporting(path) = status {
                readSnapshot(at: path, allowRetry: false, generation: generation)
            }
        }
    }

    func recordTranscriptActivitySync(at date: Date) {
        queue.sync { recordTranscriptActivity(at: date) }
    }
}
