import CryptoKit
import Darwin
import Foundation

/// Tunables for the snapshot inbox; defaults follow the Schema v1 inbox rules.
public struct SnapshotInboxConfiguration: Equatable {
    /// Delay before re-reading a file that failed to parse (a Mod may still be writing it).
    public var halfWriteRetryDelay: TimeInterval

    /// Files in the inbox directory not modified for this long are removed.
    public var retention: TimeInterval

    /// Minimum spacing between two diagnostic log lines for the same rejection reason; the
    /// rejections in between are counted and reported with the next line.
    public var rejectionLogInterval: TimeInterval

    public var io: QuotaIOConfiguration

    public init(
        halfWriteRetryDelay: TimeInterval = 0.1,
        retention: TimeInterval = 24 * 3_600,
        rejectionLogInterval: TimeInterval = 300,
        io: QuotaIOConfiguration = .default
    ) {
        self.halfWriteRetryDelay = halfWriteRetryDelay
        self.retention = retention
        self.rejectionLogInterval = rejectionLogInterval
        self.io = io
    }

    public static let `default` = Self()
}

/// Why the inbox refused to emit a Mod snapshot. Never carries the email, the hash
/// or any snapshot content; the settings entry maps these to actionable copy.
public enum SnapshotRejectionReason: Equatable {
    /// The snapshot names an account that is not the active one (`account.email_hash`
    /// does not match), so it can never be attributed to the displayed account.
    case accountEmailHashMismatch
    /// A Mod snapshot without `account.email_hash` cannot be attributed to anyone.
    case missingAccountEmailHash
    /// The snapshot names an organization (`account.organization_hash`) other than the active one.
    case organizationHashMismatch
    /// A window's reset time does not match the latest official reading, so the whole
    /// snapshot cannot be tied to this account's quota cycle.
    case cycleUnverified
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

    /// Source label the BalanceBar Mod writes into its snapshots. Only these snapshots carry
    /// Claude quota evidence; unrelated inbox files are left to whichever consumer declares them.
    public static let modSourceID = "balancebar-mod"

    /// Optional per-window verification of a parsed snapshot against the consumer's
    /// authoritative state. Return `false` when the window cannot be tied to that state
    /// (the whole snapshot is then rejected), `true` when it is verified, and `nil` when
    /// there is no baseline to check against. The check is snapshot atomic: a snapshot in
    /// which one window fails is never partially attributed. `updatedAt` is the snapshot's
    /// production time and `isComplete` tells whether it carries both standard windows,
    /// each with a reset time. `organizationProven` is false when the active account has an
    /// organization that the snapshot does not prove (an older Mod writes no organization hash).
    public var cycleVerification: ((
        QuotaWindowKind, Date?, _ updatedAt: Date, _ isComplete: Bool, _ organizationProven: Bool
    ) -> Bool?)?

    /// Read-only rejection reporting for the settings entry: invoked on the inbox queue
    /// whenever a Mod snapshot is rejected before emission. Pure notification; the
    /// rejection decisions themselves are unchanged.
    public var rejectionObserver: ((SnapshotRejectionReason) -> Void)?

    /// Reports the snapshot format of every attributed Mod snapshot (inbox queue): `true` when it
    /// carries an email hash but no organization hash (Mod 1.0.0), `false` for the current format.
    /// Pure notification; it never changes whether the snapshot is accepted.
    public var outdatedModObserver: ((Bool) -> Void)?

    /// Diagnostic log sink for Mod snapshot rejections (inbox queue). Lines carry only the
    /// reason enum and the window: never an email, hash, organization or quota value.
    public var diagnosticLog: ((String) -> Void)?

    public let sourceID = "snapshot-inbox"

    private let inboxDirectory: URL
    /// Internal for diagnostics and tests; the health of an adapter explains rejected snapshots.
    let adapters: [QuotaSourceAdapter]
    private let identity: AccountIdentityProviding
    private let configuration: SnapshotInboxConfiguration
    private let now: () -> Date
    private let fileManager: FileManager
    private static let queueKey = DispatchSpecificKey<UUID>()
    private let queueTag = UUID()
    let queue: DispatchQueue
    private let watcherQueue = DispatchQueue(label: "BalanceBar.SnapshotInbox.Watcher", qos: .utility)

    private var handler: ((QuotaObservation) -> Void)?
    private var watchers: [DirectoryWatcher] = []
    private var generation = 0
    /// Fingerprint of the last snapshot the pipeline adopted, per account epoch and source.
    /// Only adopted evidence becomes the replay baseline: a snapshot the merge engine
    /// rejected never updates it, so the previously adopted values keep being recognized as
    /// duplicates and rejected data cannot make a later same-value snapshot look new.
    /// In-memory only.
    private var adoptedSnapshots: [String: AdoptedSnapshot] = [:]
    /// Emitted snapshots awaiting adoption feedback from the pipeline (`noteProcessed`).
    private var pendingAdoptions: [PendingKey: PendingSnapshot] = [:]
    /// Diagnostics counters (inbox-queue confined); tests read them through `queue.sync`.
    private(set) var suppressedReplayCount = 0
    private(set) var unverifiedSnapshotRejections = 0
    /// Throttle state per rejection reason (inbox-queue confined).
    private var rejectionLogState: [String: (lastLogged: Date, suppressed: Int)] = [:]

    private struct EmittedWindow: Equatable {
        let kind: QuotaWindowKind
        let usedPercentage: Double
        let resetsAt: Date?
    }

    private struct AdoptedSnapshot {
        let fingerprint: [EmittedWindow]
        /// Production time of the newest snapshot with this fingerprint that was seen.
        var updatedAt: Date
    }

    private struct PendingKey: Hashable {
        let accountID: String
        let source: String
        let receivedAt: Date
    }

    private struct PendingSnapshot {
        let emissionKey: String
        let fingerprint: [EmittedWindow]
        let updatedAt: Date
        var remaining: Int
        var acceptedAny = false
        let createdAt: Date
    }

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
        queue = DispatchQueue(label: "BalanceBar.SnapshotInbox", qos: .utility)
        queue.setSpecific(key: Self.queueKey, value: queueTag)
        self.inboxDirectory = inboxDirectory.standardizedFileURL
        self.adapters = [SchemaV1InboxAdapter(directory: inboxDirectory)] + adapters
        self.identity = identity
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    deinit { stop() }

    /// Starts watching. All file-system work runs on the inbox queue, never on the caller's thread.
    public func start(receiving handler: @escaping (QuotaObservation) -> Void) {
        let toStop = tearDown()
        toStop.forEach { $0.stop() }
        let token: Int = onQueue {
            self.handler = handler
            return self.generation
        }
        queue.async { [weak self] in
            guard let self, self.generation == token else { return }
            try? self.fileManager.createDirectory(at: self.inboxDirectory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            let roots = Set(self.adapters.flatMap(self.watchRoots(for:)).map(\.path)).sorted()
            self.watchers = roots.compactMap { path in
                let watcher = DirectoryWatcher(
                    directory: URL(fileURLWithPath: path), configuration: self.configuration.io,
                    queue: self.watcherQueue
                ) { [weak self] paths in self?.queue.async { self?.process(paths: paths) } }
                return watcher.start() ? watcher : nil
            }
            self.scanAll()
        }
    }

    /// Safe to call from any thread, including from inside the observation handler.
    public func stop() {
        tearDown().forEach { $0.stop() }
    }

    /// Adoption feedback for one observation previously handed over by `emit`: the consumer
    /// reports every observation once, with whether the merge engine adopted it. A snapshot
    /// becomes the replay baseline only when all of its observations were processed and at
    /// least one was adopted — a rejected or filtered snapshot never updates the baseline,
    /// so previously adopted values keep being recognized as duplicates.
    public func noteProcessed(source: String, accountID: String, receivedAt: Date, accepted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = PendingKey(accountID: accountID, source: source, receivedAt: receivedAt)
            guard var pending = self.pendingAdoptions[key] else { return }
            pending.remaining -= 1
            pending.acceptedAny = pending.acceptedAny || accepted
            if pending.remaining <= 0 {
                if pending.acceptedAny {
                    self.adoptedSnapshots[pending.emissionKey] = AdoptedSnapshot(
                        fingerprint: pending.fingerprint, updatedAt: pending.updatedAt)
                }
                self.pendingAdoptions[key] = nil
            } else {
                self.pendingAdoptions[key] = pending
            }
        }
    }

    /// Drops adoption feedback that can no longer arrive (the consumer stops processing)
    /// and bounds the pending table.
    private func pruneStalePendingAdoptions() {
        let cutoff = now().addingTimeInterval(-60)
        pendingAdoptions = pendingAdoptions.filter { $0.value.createdAt > cutoff }
        if pendingAdoptions.count > 32 {
            let stale = pendingAdoptions
                .sorted { $0.value.createdAt < $1.value.createdAt }
                .prefix(pendingAdoptions.count - 32)
            for key in stale.map(\.key) { pendingAdoptions[key] = nil }
        }
    }

    private func tearDown() -> [DirectoryWatcher] {
        onQueue {
            generation += 1
            handler = nil
            defer { watchers = [] }
            return watchers
        }
    }

    /// Runs `body` on the inbox queue, or inline when already on it (avoids self-deadlock).
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueTag { return body() }
        return queue.sync(execute: body)
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
        for path in expand(paths: paths) {
            guard let adapter = adapter(for: path) else { continue }
            read(path: path, adapter: adapter, allowRetry: true, generation: generation)
        }
    }

    /// Replaces directory paths (such as the post-wake catch-up event) with the files inside them,
    /// including nested paths discovered by adapters.
    func expand(paths: Set<String>) -> [String] {
        var result: Set<String> = []
        for path in paths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                result.formUnion(files(under: URL(fileURLWithPath: path)))
                // A watched ancestor of a not-yet-existing path: rescan nested discovered paths too.
                let prefix = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
                for adapter in adapters {
                    for discovered in adapter.discoverPaths() {
                        let parts = discovered.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                        if parts.count > prefix.count, Array(parts.prefix(prefix.count)) == prefix {
                            result.formUnion(files(under: discovered))
                        }
                    }
                }
            } else {
                result.insert(path)
            }
        }
        return result.sorted()
    }

    // MARK: Reading

    private func read(path: String, adapter: QuotaSourceAdapter, allowRetry: Bool, generation expected: Int) {
        guard expected == generation, handler != nil else { return }
        let url = URL(fileURLWithPath: path)
        guard !url.lastPathComponent.hasPrefix("."), isRegularFile(url) else { return }

        let validator = SafeFileValidator(
            allowedDirectories: adapters.flatMap(allowedDirectories(for:)),
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

    /// Writes one throttled diagnostic line for a rejected Mod snapshot. The same reason is
    /// logged at most once per `rejectionLogInterval`; the rejections skipped in between are
    /// reported as `repeats` on the next line.
    private func logRejection(reason: String, window: String = "all", event: String = "rejected") {
        guard let diagnosticLog else { return }
        let current = now()
        var suppressed = 0
        if let state = rejectionLogState[reason] {
            if current.timeIntervalSince(state.lastLogged) < configuration.rejectionLogInterval,
               current >= state.lastLogged {
                rejectionLogState[reason] = (state.lastLogged, state.suppressed + 1)
                return
            }
            suppressed = state.suppressed
        }
        rejectionLogState[reason] = (current, 0)
        let repeats = suppressed > 0 ? "; repeats=\(suppressed)" : ""
        diagnosticLog("claude mod snapshot \(event); reason=\(reason); window=\(window)\(repeats)")
    }

    private func emit(_ parsed: ParsedQuotaSnapshot, adapter: QuotaSourceAdapter) {
        guard let account = identity.accountIdentity else {
            adapter.health = .degraded(reason: "no active account")
            if parsed.source == Self.modSourceID { logRejection(reason: "no_active_account") }
            return
        }
        // Only the BalanceBar Mod's rejections may change the Mod status entry. Other
        // inbox producers keep their validation and rejection behavior, but must not be
        // reported as a Mod failure.
        let isModSnapshot = parsed.source == Self.modSourceID
        // Account attribution is fail closed: this inbox stamps every observation with the
        // active account's identity, so a snapshot that cannot prove it belongs to that
        // account must never reach the merge engine. Reasons never quote the email or hash.
        if let provided = parsed.accountEmailHash?.lowercased(), !provided.isEmpty {
            guard let expected = account.email.map(Self.emailHash), !expected.isEmpty,
                  provided == expected else {
                adapter.health = .degraded(reason: "rejected snapshot: account email hash does not match the active account")
                if isModSnapshot {
                    logRejection(reason: "account_email_hash_mismatch")
                    rejectionObserver?(.accountEmailHashMismatch)
                }
                return
            }
        } else if parsed.source == Self.modSourceID {
            // The Mod hashes the account it runs under; a snapshot without the hash cannot
            // be attributed to anyone and falls back to the official reading.
            adapter.health = .degraded(reason: "rejected snapshot: missing account email hash")
            logRejection(reason: "missing_account_email_hash")
            rejectionObserver?(.missingAccountEmailHash)
            return
        }
        // Organization attribution: a mismatching organization hash is foreign data. A snapshot
        // without one (older Mod) cannot prove the organization; the consumer decides whether
        // an official baseline makes that acceptable.
        var organizationProven = true
        if let organization = account.organizationUUID {
            if let provided = parsed.accountOrganizationHash?.lowercased(), !provided.isEmpty {
                guard provided == Self.hash(organization) else {
                    adapter.health = .degraded(reason: "rejected snapshot: organization hash does not match the active account")
                    if isModSnapshot {
                        logRejection(reason: "organization_hash_mismatch")
                        rejectionObserver?(.organizationHashMismatch)
                    }
                    return
                }
            } else if isModSnapshot {
                organizationProven = false
            }
        }
        // A mismatching organization must not clear the stale-Mod warning.
        // Legacy snapshots can still report their format before cycle verification.
        if isModSnapshot {
            let outdated = parsed.accountOrganizationHash?.isEmpty != false
            if outdated { logRejection(reason: "mod_outdated_format", event: "outdated") }
            outdatedModObserver?(outdated)
        }
        let epoch = identity.accountEpoch
        let source = parsed.source.flatMap { $0 == "unknown" ? nil : $0 } ?? adapter.sourceID
        let received = now()
        // Snapshot-atomic cycle verification: one window that cannot be tied to the
        // consumer's authoritative cycle rejects the whole snapshot, so a snapshot that
        // cannot be fully attributed is never partially accepted.
        if let verify = cycleVerification {
            let isComplete = [QuotaWindowKind.fiveHour, .sevenDay].allSatisfy { kind in
                parsed.windows.contains { $0.kind == kind && $0.resetsAt != nil }
            }
            for window in parsed.windows
            where verify(window.kind, window.resetsAt, parsed.updatedAt, isComplete, organizationProven) == false {
                unverifiedSnapshotRejections += 1
                adapter.health = .degraded(reason: "rejected snapshot: cycle_unverified_against_official")
                if isModSnapshot {
                    logRejection(reason: "cycle_unverified_against_official", window: window.kind.rawValue)
                    rejectionObserver?(.cycleUnverified)
                }
                return
            }
        }
        // A whole-snapshot replay (every window identical to the last ADOPTED snapshot for
        // this account, epoch and source) carries no new quota evidence and is not emitted
        // again. The baseline is promoted only through adoption feedback, so a snapshot the
        // pipeline rejected never becomes the measure for later duplicates.
        let fingerprint = parsed.windows.map { EmittedWindow(
            kind: $0.kind, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
        let emissionKey = "\(account.stableID)/\(epoch.rawValue)/\(source)"
        // A Mod snapshot with the same values but a later production time is not a replay: the
        // Mod is still alive, and the merge engine renews the reading's time (same value,
        // newer) instead of letting a steady integer percentage age out.
        if let adopted = adoptedSnapshots[emissionKey], adopted.fingerprint == fingerprint,
           !isModSnapshot || parsed.updatedAt <= adopted.updatedAt {
            suppressedReplayCount += 1
            adapter.health = .healthy
            return
        }
        pruneStalePendingAdoptions()
        pendingAdoptions[PendingKey(accountID: account.stableID, source: source, receivedAt: received)] =
            PendingSnapshot(
                emissionKey: emissionKey, fingerprint: fingerprint, updatedAt: parsed.updatedAt,
                remaining: parsed.windows.count, createdAt: received)
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

    /// The hash format Schema v1 producers write: `sha256:` plus the hex digest of the
    /// trimmed, lowercased email — the same rule the BalanceBar Mod applies.
    static func emailHash(_ email: String) -> String { hash(email) }

    /// Same rule for the organization UUID: `sha256:` plus the hex digest of the trimmed, lowercased value.
    static func hash(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Paths

    /// Directories each discovered path must be readable from: a directory itself, a file's parent,
    /// or, for a path that does not exist yet, its parent (it may become a file).
    private func allowedDirectories(for adapter: QuotaSourceAdapter) -> [URL] {
        adapter.discoverPaths().map { url in
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            return url.deletingLastPathComponent()
        }
    }

    /// Existing directories to watch. A path that does not exist yet is watched through its
    /// nearest existing ancestor so its later creation is observed.
    private func watchRoots(for adapter: QuotaSourceAdapter) -> [URL] {
        allowedDirectories(for: adapter).map { url in
            var candidate = url
            while !fileManager.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
                candidate = candidate.deletingLastPathComponent()
            }
            return candidate
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
        // Never clean through a symlinked inbox or one owned by someone else.
        guard let inboxValues = try? inboxDirectory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              inboxValues.isSymbolicLink != true, inboxValues.isDirectory == true,
              (try? fileManager.attributesOfItem(atPath: inboxDirectory.path)[.ownerAccountID] as? NSNumber)?
                  .uint32Value == getuid() else { return }
        let cutoff = now().addingTimeInterval(-configuration.retention)
        let urls = (try? fileManager.contentsOfDirectory(
            at: inboxDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
