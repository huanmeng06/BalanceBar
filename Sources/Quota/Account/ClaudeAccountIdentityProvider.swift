import CryptoKit
import Foundation

/// Reads the Claude Code account configuration file.
public protocol AccountConfigurationReading {
    /// Returns the file bytes, or throws when the file is unavailable.
    func readData(from url: URL) throws -> Data
}

/// Reads account configuration bytes from disk.
public struct DefaultAccountConfigurationReader: AccountConfigurationReading {
    public init() {}

    public func readData(from url: URL) throws -> Data { try Data(contentsOf: url) }
}

/// Errors produced while deriving an account identity from `~/.claude.json`.
public enum AccountIdentityError: Error, Equatable {
    /// The configuration file could not be read.
    case unreadable

    /// The configuration file is not a JSON object.
    case corrupted

    /// The file is valid but contains neither account UUIDs nor an email.
    case missingAccount
}

/// One account switch recorded for usage attribution.
public struct AccountTimelineEntry: Equatable {
    /// The account that became active, or `nil` when the account disappeared.
    public let identity: AccountIdentity?

    /// The epoch that started with this switch.
    public let epoch: AccountEpoch

    /// The moment the switch was observed.
    public let switchedAt: Date
}

/// Change broadcast to subscribers after the active account or credential changes.
public struct AccountIdentityChange: Equatable {
    /// Current account identity.
    public let identity: AccountIdentity?

    /// Current credential version.
    public let credentialVersion: CredentialVersion?

    /// Current account epoch.
    public let epoch: AccountEpoch

    /// Whether the epoch advanced with this change.
    public let accountChanged: Bool
}

/// Derives stable Claude account identifiers from `oauthAccount` in `~/.claude.json`.
public enum ClaudeAccountConfigurationParser {
    /// Parses an identity, preferring account and organization UUIDs over the normalized email.
    public static func identity(from data: Data) throws -> AccountIdentity {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountIdentityError.corrupted
        }
        guard let account = object["oauthAccount"] as? [String: Any] else {
            throw AccountIdentityError.missingAccount
        }
        let email = normalized(account["emailAddress"]).map { $0.lowercased() }
        if let accountUUID = normalized(account["accountUuid"])?.lowercased() {
            let organizationUUID = normalized(account["organizationUuid"])?.lowercased() ?? "-"
            return AccountIdentity(
                stableID: "claude:\(accountUUID):\(organizationUUID)",
                email: email,
                idSource: .accountUUID
            )
        }
        guard let email else { throw AccountIdentityError.missingAccount }
        return AccountIdentity(stableID: "claude-email:\(email)", email: email, idSource: .emailFallback)
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

/// Tracks the active Claude account, credential version, epoch and account timeline.
///
/// Getters only read in-memory state. File reads and token hashing run on `workQueue`.
/// The provider never reads the keychain: callers pass the token they already obtained.
public final class ClaudeAccountIdentityProvider: AccountIdentityProviding {
    /// Called on `workQueue` after a change; returned tokens keep the subscription alive.
    public typealias Observer = (AccountIdentityChange) -> Void

    private let configurationURL: URL
    private let reader: AccountConfigurationReading
    private let workQueue: DispatchQueue
    private let now: () -> Date
    private let coalescingInterval: TimeInterval
    private let lock = NSLock()

    private var identity: AccountIdentity?
    private var credential: CredentialVersion?
    private var epoch = AccountEpoch.initial
    private var timelineEntries: [AccountTimelineEntry] = []
    private var lastError: AccountIdentityError?
    private var observers: [UUID: Observer] = [:]
    private var hasLoadedAccount = false
    private var pendingReload: DispatchWorkItem?
    private var fileSource: DispatchSourceFileSystemObject?

    public init(
        configurationURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        reader: AccountConfigurationReading = DefaultAccountConfigurationReader(),
        workQueue: DispatchQueue = DispatchQueue(label: "BalanceBar.AccountIdentity", qos: .utility),
        coalescingInterval: TimeInterval = QuotaConstants.accountChangeCoalescingInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.configurationURL = configurationURL
        self.reader = reader
        self.workQueue = workQueue
        self.coalescingInterval = coalescingInterval
        self.now = now
    }

    deinit {
        fileSource?.cancel()
    }

    public var accountIdentity: AccountIdentity? { locked { identity } }

    public var credentialVersion: CredentialVersion? { locked { credential } }

    public var accountEpoch: AccountEpoch { locked { epoch } }

    /// The most recent configuration error, or `nil` after a successful read.
    public var lastReadError: AccountIdentityError? { locked { lastError } }

    /// Account switches in chronological order, for usage attribution.
    public var timeline: [AccountTimelineEntry] { locked { timelineEntries } }

    /// Returns the timeline entry that was active at `date`, if any.
    public func timelineEntry(at date: Date) -> AccountTimelineEntry? {
        locked { timelineEntries.last { $0.switchedAt <= date } }
    }

    /// Subscribes to changes. Keep the returned object to stay subscribed.
    public func addObserver(_ observer: @escaping Observer) -> AnyObject {
        let id = UUID()
        locked { observers[id] = observer }
        return ObservationToken { [weak self] in
            self?.locked { self?.observers[id] = nil }
        }
    }

    /// Schedules a coalesced reload of the account configuration file.
    public func scheduleReload() {
        workQueue.async { [weak self] in
            guard let self else { return }
            pendingReload?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reloadNow() }
            pendingReload = item
            workQueue.asyncAfter(deadline: .now() + coalescingInterval, execute: item)
        }
    }

    /// Records the token from the existing credential read; only its SHA-256 digest is kept.
    public func ingestCredential(accessToken: String?) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let version = accessToken.flatMap(Self.credentialVersion(for:))
            let changed: Bool = locked {
                guard self.credential != version else { return false }
                self.credential = version
                return true
            }
            if changed { broadcast(accountChanged: false) }
        }
    }

    /// Watches the configuration file's directory and reloads after coalesced changes.
    public func startMonitoring() {
        workQueue.async { [weak self] in
            guard let self, fileSource == nil else { return }
            let descriptor = open(configurationURL.deletingLastPathComponent().path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend],
                queue: workQueue
            )
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            fileSource = source
            source.resume()
            reloadNow()
        }
    }

    /// Stops file monitoring and cancels any pending reload.
    public func stopMonitoring() {
        workQueue.async { [weak self] in
            self?.pendingReload?.cancel()
            self?.pendingReload = nil
            self?.fileSource?.cancel()
            self?.fileSource = nil
        }
    }

    /// Irreversible, non-secret credential version derived from a token.
    static func credentialVersion(for token: String) -> CredentialVersion? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return CredentialVersion(digest.map { String(format: "%02x", $0) }.joined())
    }

    private func reloadNow() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReload = nil
        let result: Result<AccountIdentity, AccountIdentityError>
        do {
            let data = try reader.readData(from: configurationURL)
            result = .success(try ClaudeAccountConfigurationParser.identity(from: data))
        } catch let error as AccountIdentityError {
            result = .failure(error)
        } catch {
            result = .failure(.unreadable)
        }

        let accountChanged: Bool = locked {
            switch result {
            case .success(let newIdentity):
                lastError = nil
                let changed = !hasLoadedAccount || identity?.stableID != newIdentity.stableID
                identity = newIdentity
                guard changed else { return false }
                if hasLoadedAccount { epoch = epoch.next }
                hasLoadedAccount = true
                timelineEntries.append(AccountTimelineEntry(identity: newIdentity, epoch: epoch, switchedAt: now()))
                return true
            case .failure(let error):
                // Keep the last known account on read errors so a partial write cannot bump the epoch.
                lastError = error
                return false
            }
        }
        if accountChanged { broadcast(accountChanged: true) }
    }

    private func broadcast(accountChanged: Bool) {
        let (change, handlers): (AccountIdentityChange, [Observer]) = locked {
            (
                AccountIdentityChange(
                    identity: identity,
                    credentialVersion: credential,
                    epoch: epoch,
                    accountChanged: accountChanged
                ),
                Array(observers.values)
            )
        }
        handlers.forEach { $0(change) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ObservationToken {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) { self.cancel = cancel }

    deinit { cancel() }
}
