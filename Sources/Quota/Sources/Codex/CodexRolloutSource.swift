import Foundation

/// One window's rate-limit reading from a Codex `token_count` event.
struct CodexRateLimitReading: Equatable {
    let windowMinutes: Int
    let usedPercent: Double
    let resetsAt: Date?
}

/// A parsed `token_count` event carrying official `rate_limits`.
struct CodexRateLimitEvent: Equatable {
    let timestamp: Date
    let readings: [CodexRateLimitReading]
}

/// Parses rollout JSONL lines written by Codex CLI.
enum CodexRolloutParser {
    private static let marker = Data("rate_limits".utf8)

    /// Returns the event for a `token_count` line with usable rate limits, otherwise `nil`.
    static func parse(line: Data) -> CodexRateLimitEvent? {
        guard line.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let timestamp = date(from: object["timestamp"]) else { return nil }

        // Windows are identified by `window_minutes`, never by primary/secondary position.
        var readings: [CodexRateLimitReading] = []
        for key in limits.keys.sorted() {
            guard let entry = limits[key] as? [String: Any],
                  let minutes = number(entry["window_minutes"]).map(Int.init),
                  minutes > 0,
                  let used = number(entry["used_percent"]) else { continue }
            var resetsAt: Date?
            if let epoch = number(entry["resets_at"]) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let seconds = number(entry["resets_in_seconds"]) {
                resetsAt = timestamp.addingTimeInterval(seconds)
            }
            readings.append(CodexRateLimitReading(windowMinutes: minutes, usedPercent: used, resetsAt: resetsAt))
        }
        return readings.isEmpty ? nil : CodexRateLimitEvent(timestamp: timestamp, readings: readings)
    }

    static func windowKind(forMinutes minutes: Int) -> QuotaWindowKind {
        switch minutes {
        case 5 * 60: return .fiveHour
        case 7 * 24 * 60: return .sevenDay
        default: return .other("window_\(minutes)m")
        }
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON booleans bridge to NSNumber, but `is Bool` is also true for numeric 0 and 1.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Tunables for the Codex rollout source.
struct CodexRolloutConfiguration: Equatable {
    /// Most recently modified rollout files scanned on start and on a rescan.
    var maximumFilesPerScan = 20

    /// Rollout files untouched for longer than this cannot hold a live 7-day reading.
    var maximumFileAge: TimeInterval = 8 * 24 * 60 * 60

    /// How long a log reading suppresses `wham/usage` requests.
    var freshness: TimeInterval = QuotaConstants.realtimeSourceFreshness
}

/// Reads official Codex rate limits from local rollout logs without any network request.
///
/// It incrementally reads `rollout-*.jsonl` files under `$CODEX_HOME/sessions` (default
/// `~/.codex/sessions`), keeps the newest event per window, and emits grade-A observations
/// for the account supplied by `accountProvider`. All IO runs on a private utility queue.
/// `hasFreshData(at:)` tells the caller whether `wham/usage` may be suppressed; wiring it
/// into the refresh path is left to the integration issue.
public final class CodexRolloutSource: QuotaSource {
    public static let identifier = "codex-rollout"

    public var sourceID: String { Self.identifier }

    private let sessionsDirectory: URL
    private let accountProvider: AccountIdentityProviding
    private let configuration: CodexRolloutConfiguration
    private let reader: IncrementalJSONLReader
    private let now: () -> Date
    private let queue = DispatchQueue(label: "BalanceBar.CodexRolloutSource", qos: .utility)
    private let ioConfiguration: QuotaIOConfiguration

    private var handler: ((QuotaObservation) -> Void)?
    private var watcher: DirectoryWatcher?
    private var emittedAt: [QuotaWindowKind: Date] = [:]
    private let latestLock = NSLock()
    private var latestEventDate: Date?
    private var latestEventAccountID: String?
    /// The signed-in ChatGPT account id; `nil` skips the per-file check (tests only, production always passes it).
    private let currentAccountID: (() -> String?)?
    /// `creator_account_id` per rollout file, cached once the first line was read completely.
    private var creatorByPath: [String: String] = [:]
    private var filesWithoutCreator: Set<String> = []
    /// The account (login, epoch) the emitted-event bookkeeping belongs to.
    private var attributedAccount: (stableID: String, epoch: AccountEpoch)?

    /// Resolves the sessions directory from `CODEX_HOME`, falling back to `~/.codex`.
    public static func sessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = custom.isEmpty
            ? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    /// - Parameter currentAccountID: the signed-in ChatGPT account id. A rollout file is attributed to the current
    ///   login only when its `session_meta` names this account as the session's creator.
    public convenience init(accountProvider: AccountIdentityProviding, currentAccountID: @escaping () -> String?) {
        self.init(
            sessionsDirectory: Self.sessionsDirectory(),
            accountProvider: accountProvider,
            ioConfiguration: .default,
            now: Date.init,
            currentAccountID: currentAccountID
        )
    }

    init(
        sessionsDirectory: URL,
        accountProvider: AccountIdentityProviding,
        configuration: CodexRolloutConfiguration = CodexRolloutConfiguration(),
        ioConfiguration: QuotaIOConfiguration = .default,
        now: @escaping () -> Date = Date.init,
        currentAccountID: (() -> String?)? = nil
    ) {
        self.currentAccountID = currentAccountID
        self.sessionsDirectory = sessionsDirectory.standardizedFileURL
        self.accountProvider = accountProvider
        self.configuration = configuration
        self.ioConfiguration = ioConfiguration
        self.now = now
        self.reader = IncrementalJSONLReader(
            configuration: ioConfiguration,
            validator: SafeFileValidator(
                allowedDirectories: [sessionsDirectory],
                maximumFileSize: nil
            )
        )
    }

    /// `true` when the newest logged event is recent enough to skip a `wham/usage` request.
    public func hasFreshData(at date: Date? = nil) -> Bool {
        let reference = date ?? now()
        latestLock.lock()
        defer { latestLock.unlock() }
        guard let latest = latestEventDate,
              latestEventAccountID == accountProvider.accountIdentity?.stableID else { return false }
        let age = reference.timeIntervalSince(latest)
        return age >= 0 && age <= configuration.freshness
    }

    public func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        queue.async { [self] in
            self.handler = handler
            scan(paths: nil)
            guard watcher == nil else { return }
            let fileManager = FileManager.default
            // Watch the sessions directory; before Codex creates it, watch its parent.
            let target = fileManager.fileExists(atPath: sessionsDirectory.path)
                ? sessionsDirectory : sessionsDirectory.deletingLastPathComponent()
            // The watcher's start/stop use `queue.sync`, so it needs its own queue.
            let created = DirectoryWatcher(
                directory: target, configuration: ioConfiguration
            ) { [weak self] paths in
                self?.queue.async { self?.scan(paths: paths) }
            }
            if created.start() { watcher = created }
        }
    }

    public func stop() {
        queue.sync {
            watcher?.stop()
            watcher = nil
            handler = nil
        }
    }

    /// Reads changed files (or the most recent files when `paths` is `nil` or names a directory).
    /// Must run on `queue`; tests call it through `rescan(paths:)`.
    /// The login a scan works for: read once at its start and compared again before anything is published.
    private struct LoginSnapshot: Equatable {
        let identity: AccountIdentity
        let epoch: AccountEpoch
        /// The signed-in ChatGPT account id (`""` when unknown); `nil` when the per-file check is off (tests only).
        let chatGPTAccountID: String?
    }

    private func loginSnapshot() -> LoginSnapshot? {
        // Without a current Codex account there is nobody to attribute the reading to.
        guard let identity = accountProvider.accountIdentity else { return nil }
        return LoginSnapshot(
            identity: identity, epoch: accountProvider.accountEpoch,
            chatGPTAccountID: currentAccountID.map { $0() ?? "" })
    }

    private func scan(paths: Set<String>?) {
        guard handler != nil, let login = loginSnapshot() else { return }
        let files = filesToRead(for: paths)
        var newest: [QuotaWindowKind: (event: CodexRateLimitEvent, reading: CodexRateLimitReading)] = [:]
        // A rollout log does not say which login a reading belongs to, but its `session_meta` names the account that
        // created the session. A file counts for the current login only when that account matches; a session started
        // by another login keeps writing to its own file, so it can never be attributed to the one signed in now.
        let currentID = login.chatGPTAccountID
        for file in files {
            if let currentID {
                guard !currentID.isEmpty, creatorAccountID(of: file) == currentID else { continue }
            }
            for event in events(in: file) {
                for reading in event.readings {
                    let kind = CodexRolloutParser.windowKind(forMinutes: reading.windowMinutes)
                    if let current = newest[kind], current.event.timestamp >= event.timestamp { continue }
                    newest[kind] = (event, reading)
                }
            }
        }
        // The login may have changed while the files were read (the identity is cached for a couple of seconds):
        // then these readings were filtered for the old login and must not be handed to the new one.
        guard loginSnapshot() == login else { return }
        publish(newest, for: login)
    }

    private func publish(
        _ newest: [QuotaWindowKind: (event: CodexRateLimitEvent, reading: CodexRateLimitReading)],
        for login: LoginSnapshot
    ) {
        let account = login.identity
        let epoch = login.epoch
        let receivedAt = now()
        // A new login must not be held back by the previous login's event times.
        if attributedAccount?.stableID != account.stableID || attributedAccount?.epoch != epoch {
            attributedAccount = (account.stableID, epoch)
            emittedAt.removeAll()
        }
        for (kind, item) in newest.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let previous = emittedAt[kind], previous >= item.event.timestamp { continue }
            guard let observation = QuotaObservation(
                window: kind,
                usedPercentage: item.reading.usedPercent,
                resetsAt: item.reading.resetsAt,
                observedAt: item.event.timestamp,
                receivedAt: receivedAt,
                source: Self.identifier,
                trust: .a,
                accountID: account.stableID,
                epoch: epoch
            ) else { continue }
            emittedAt[kind] = item.event.timestamp
            markFresh(item.event.timestamp, accountID: account.stableID)
            handler?(observation)
        }
    }

    /// Records freshness only for a valid observation attributed to the current account.
    private func markFresh(_ date: Date, accountID: String) {
        latestLock.lock()
        defer { latestLock.unlock() }
        if latestEventAccountID != accountID || latestEventDate.map({ date > $0 }) ?? true {
            latestEventDate = date
            latestEventAccountID = accountID
        }
    }

    /// The first line of a rollout is `session_meta`; its `creator_account_id` is the ChatGPT account that started the
    /// session. `nil` when it is missing (older Codex versions) or the line is not completely written yet.
    private func creatorAccountID(of file: URL) -> String? {
        let url = file.standardizedFileURL
        guard url.path.hasPrefix(sessionsDirectory.path + "/"),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        if let known = creatorByPath[url.path] { return known }
        if filesWithoutCreator.contains(url.path) { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The first line carries the whole base instructions, so it is long; read a bounded amount of it.
        let limit = 512 * 1024
        guard let head = try? handle.read(upToCount: limit) else { return nil }
        guard let newline = head.firstIndex(of: 0x0A) else {
            // No end of line yet: wait for it unless the line is already longer than anything sensible.
            if head.count >= limit { filesWithoutCreator.insert(url.path) }
            return nil
        }
        let line = head[head.startIndex..<newline]
        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any],
           let creator = (payload["creator_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !creator.isEmpty {
            creatorByPath[url.path] = creator
            return creator
        }
        filesWithoutCreator.insert(url.path)
        return nil
    }

    private func events(in file: URL) -> [CodexRateLimitEvent] {
        var result: [CodexRateLimitEvent] = []
        while true {
            // Only the newest event per window matters, so a large log is read from its tail.
            guard let batch = try? reader.read(file, firstReadTailBytes: QuotaConstants.initialTailReadBytes) else { break }
            result.append(contentsOf: batch.lines.compactMap(CodexRolloutParser.parse(line:)))
            if !batch.hasMore { break }
        }
        return result
    }

    private func filesToRead(for paths: Set<String>?) -> [URL] {
        guard let paths else { return recentRolloutFiles() }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        // A directory path (e.g. the wake-up catch-up event) means "rescan recent files".
        if urls.contains(where: Self.isDirectory) {
            return recentRolloutFiles()
        }
        return urls.filter(Self.isRollout).sorted { $0.path < $1.path }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isRollout(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
    }

    private func recentRolloutFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff = now().addingTimeInterval(-configuration.maximumFileAge)
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where Self.isRollout(url) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff else { continue }
            candidates.append((url, modified))
        }
        return candidates.sorted { $0.modified > $1.modified }
            .prefix(configuration.maximumFilesPerScan)
            .map(\.url)
    }

    /// Test hook: processes changed paths synchronously as the directory watcher would.
    func rescan(paths: Set<String>?, handler: @escaping (QuotaObservation) -> Void) {
        queue.sync {
            self.handler = handler
            scan(paths: paths)
        }
    }
}
