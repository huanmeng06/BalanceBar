import Foundation
import CryptoKit

/// Errors surfaced by official OpenAI and Claude quota requests.
/// Values never include a request URL or credential material.
enum OfficialQuotaClientError: Error {
    case missingCredentials
    case transport(OfficialQuotaTransportError)
    case httpStatus(statusCode: Int, dataSize: Int)
    case invalidJSON(dataSize: Int)
    case unsupportedFormat(dataSize: Int)
}

enum OfficialQuotaTransportError: Error {
    case urlError(URLError.Code)
    case possibleProxy(URLError.Code)
    case unknown
}

extension OfficialQuotaTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .urlError(let code):
            return URLError(code).localizedDescription
        case .possibleProxy(let code):
            return "Possible proxy required: \(URLError(code).localizedDescription)"
        case .unknown:
            return "The network request failed"
        }
    }
}

struct OfficialQuotaResult {
    let output: OfficialQuotaResponseParser.Output
    let dataSize: Int
    let fetchedAt = Date()
}

/// Identifies the credential path used by a request without retaining the
/// credential itself in request-deduplication state.
enum OfficialQuotaCredentialSource: String, Hashable {
    case localReader = "local-reader"
    case storedAccessToken = "stored-access-token"
}

protocol OfficialQuotaCredentialReading {
    func codexAccessToken() -> String?
    func codexAccountProfile() -> CodexAccountProfile?
    func claudeAccessToken() -> String?
    /// Token and plan from one credential-store read.
    func claudeCredentials() -> ClaudeStoredCredentials
    /// Display-only account email; never token material.
    func claudeAccountEmail() -> String?
    func codexRequestCredentials() -> CodexRequestCredentials
}

struct ClaudeStoredCredentials: Equatable {
    let accessToken: String?
    let planType: String?
}

extension OfficialQuotaCredentialReading {
    func claudeCredentials() -> ClaudeStoredCredentials {
        ClaudeStoredCredentials(accessToken: claudeAccessToken(), planType: nil)
    }
    func claudeAccountEmail() -> String? { nil }
}

struct CodexRequestCredentials: Equatable {
    let accessToken: String?
    let accountKey: String?

    /// An opaque in-memory scope; raw credentials never enter registry keys.
    var requestScope: String {
        SHA256.hash(data: Data(((accountKey ?? "") + "\u{0}" + (accessToken ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Frozen once by the request owner and reused verbatim for cancellation.
/// Never passed to presentation code or diagnostics.
struct OfficialQuotaRequestContext {
    let client: AssistantClient
    let providerID: String
    let storedAccessToken: String?
    let credentials: CodexRequestCredentials?
    /// Identifies this caller among consumers sharing one transport. Two
    /// callers for the same Provider and account still cancel independently.
    let consumerID = UUID()

    var credentialSource: OfficialQuotaCredentialSource {
        OfficialQuotaClient.credentialSource(client: client, storedAccessToken: storedAccessToken)
    }
}

extension OfficialQuotaCredentialReading {
    func codexRequestCredentials() -> CodexRequestCredentials {
        CodexRequestCredentials(
            accessToken: codexAccessToken(),
            accountKey: codexAccountProfile()?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

extension CredentialReader: OfficialQuotaCredentialReading {}

protocol OfficialQuotaParsing {
    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output
}

struct DefaultOfficialQuotaParser: OfficialQuotaParsing {
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func parse(
        data: Data,
        client: AssistantClient
    ) throws -> OfficialQuotaResponseParser.Output {
        try OfficialQuotaResponseParser.parse(data: data, client: client, now: now())
    }
}

/// Executes official quota requests and reuses the existing credential reader
/// and response parser. The transport and both dependencies are injectable so
/// tests can remain offline and avoid the user's Keychain or home directory.
final class OfficialQuotaClient {
    private typealias Completion = (Result<OfficialQuotaResult, OfficialQuotaClientError>) -> Void

    /// Keeps request cleanup independent from the client instance. A task can
    /// finish after its client has been released without retaining UI state.
    private final class InFlightRegistry {
        struct Consumer {
            let providerID: String
            let id: UUID
        }

        private struct Entry {
            let generation: UUID
            let startedAt: Date
            var completions: [(consumer: Consumer, completion: Completion)]
            var task: URLSessionDataTask?
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func register(key: String, consumer: Consumer, startedAt: Date, completion: @escaping Completion) -> UUID? {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] != nil {
                entries[key]?.completions.append((consumer, completion))
                return nil
            }
            let generation = UUID()
            entries[key] = Entry(generation: generation, startedAt: startedAt,
                completions: [(consumer, completion)], task: nil)
            return generation
        }

        func startedAt(key: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]?.startedAt
        }

        func attach(task: URLSessionDataTask, to key: String, generation: UUID) {
            lock.lock()
            guard var entry = entries[key], entry.generation == generation else {
                lock.unlock()
                task.cancel()
                return
            }
            entry.task = task
            entries[key] = entry
            lock.unlock()
        }

        func contains(key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return entries[key] != nil
        }

        /// Removes a finished request. Returns nil when it was cancelled or
        /// replaced, so a late response cannot reach consumers or caches.
        func take(key: String, generation: UUID) -> [Completion]? {
            lock.lock()
            defer { lock.unlock() }
            guard entries[key]?.generation == generation else { return nil }
            return entries.removeValue(forKey: key)?.completions.map(\.completion)
        }

        /// Releases only matching consumers. Transport is cancelled once no
        /// other consumer still waits on the shared request.
        func cancel(key: String, where matches: (Consumer) -> Bool) -> [Completion] {
            lock.lock()
            guard var entry = entries[key] else { lock.unlock(); return [] }
            let released = entry.completions.filter { matches($0.consumer) }.map(\.completion)
            entry.completions.removeAll { matches($0.consumer) }
            let task: URLSessionDataTask?
            if entry.completions.isEmpty {
                entries.removeValue(forKey: key)
                task = entry.task
            } else {
                entries[key] = entry
                task = nil
            }
            lock.unlock()
            task?.cancel()
            return released
        }
    }

    private let session: URLSession
    private let claudeProxyConfigurationProvider: (() -> CCSwitchProxyConfiguration)?
    private let claudeSessionLock = NSLock()
    private var claudeSessionStorage: URLSession?
    private let credentialReader: OfficialQuotaCredentialReading
    private let parser: OfficialQuotaParsing
    private let now: () -> Date
    private let claudeCacheLock = NSLock()
    private var claudeResponses: [String: (result: Result<OfficialQuotaResult, OfficialQuotaClientError>, recordedAt: Date, retryUntil: Date?)] = [:]
    private var claudeCalibrationInterval: () -> TimeInterval = { 60 }
    private var claudeAccountProbe: (credentials: CodexRequestCredentials, profile: CodexAccountProfile?, readAt: Date)?
    private var claudeProbeInFlight = false
    private let claudeProbeCondition = NSCondition()

    func configureClaudeCalibrationInterval(_ interval: @escaping () -> TimeInterval) {
        claudeCacheLock.lock()
        claudeCalibrationInterval = interval
        claudeCacheLock.unlock()
    }
    private var claudeRateLimitFailures: [String: Int] = [:]
    private let inFlight = InFlightRegistry()
    private let creditLock = NSLock()
    private var creditRequests: [String: (UUID, URLSessionDataTask)] = [:]

    init(
        session: URLSession? = nil,
        claudeSession: URLSession? = nil,
        claudeProxyConfiguration: CCSwitchProxyConfiguration? = nil,
        credentialReader: OfficialQuotaCredentialReading = CredentialReader(),
        parser: OfficialQuotaParsing = DefaultOfficialQuotaParser(),
        now: @escaping () -> Date = Date.init
    ) {
        let baseSession = session ?? .shared
        self.session = baseSession
        self.claudeSessionStorage = claudeSession
            ?? (claudeProxyConfiguration == nil && session != nil ? baseSession : nil)
        if let claudeProxyConfiguration {
            self.claudeProxyConfigurationProvider = { claudeProxyConfiguration }
        } else if session == nil && claudeSession == nil {
            self.claudeProxyConfigurationProvider = { CCSwitchRepository().claudeProxyConfiguration() }
        } else {
            self.claudeProxyConfigurationProvider = nil
        }
        self.credentialReader = credentialReader
        self.parser = parser
        self.now = now
    }

    /// Builds a session whose HTTPS traffic uses the proxy selected by Claude
    /// Code. A caller may pass a base session so tests retain their URLProtocol
    /// transport without reaching the network.
    static func makeClaudeSession(
        baseSession: URLSession? = nil,
        proxyConfiguration: CCSwitchProxyConfiguration
    ) -> URLSession {
        let configuration = baseSession?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = connectionProxyDictionary(for: proxyConfiguration)
        return URLSession(configuration: configuration)
    }

    private static func connectionProxyDictionary(
        for configuration: CCSwitchProxyConfiguration
    ) -> [AnyHashable: Any]? {
        guard let proxy = configuration.httpsProxy ?? configuration.allProxy,
              let host = proxy.host, !host.isEmpty else { return nil }
        let scheme = proxy.scheme?.lowercased() ?? ""
        let port = proxy.port ?? {
            if scheme == "socks" || scheme == "socks5" || scheme == "socks5h" { return 1080 }
            return scheme == "https" ? 443 : 80
        }()
        guard (1...65535).contains(port) else { return nil }
        if scheme == "socks" || scheme == "socks5" || scheme == "socks5h" {
            return [
                "SOCKSEnable": true,
                "SOCKSProxy": host,
                "SOCKSPort": port
            ]
        }
        return [
            "HTTPSEnable": true,
            "HTTPSProxy": host,
            "HTTPSPort": port
        ]
    }

    private func claudeSession() -> URLSession {
        claudeSessionLock.lock()
        defer { claudeSessionLock.unlock() }
        if let claudeSessionStorage { return claudeSessionStorage }
        let configuration = claudeProxyConfigurationProvider?() ?? CCSwitchProxyConfiguration()
        if configuration.isEmpty {
            claudeSessionStorage = session
        } else {
            claudeSessionStorage = Self.makeClaudeSession(
                baseSession: session,
                proxyConfiguration: configuration
            )
        }
        return claudeSessionStorage!
    }

    /// Reads the same Codex auth source used by official quota requests. The
    /// returned profile contains only display-safe claims, never token material.
    func codexAccountProfile() -> CodexAccountProfile? {
        credentialReader.codexAccountProfile()
    }

    func codexRequestCredentials() -> CodexRequestCredentials {
        credentialReader.codexRequestCredentials()
    }

    /// Claude's usage endpoint is account-wide; the token is the account scope.
    func claudeRequestCredentials(cacheFor maxAge: TimeInterval = 0.1) -> CodexRequestCredentials {
        claudeProbeCondition.lock()
        if maxAge > 0, let probe = claudeAccountProbe, now().timeIntervalSince(probe.readAt) < maxAge {
            claudeProbeCondition.unlock()
            return probe.credentials
        }
        if claudeProbeInFlight {
            let deadline = Date().addingTimeInterval(2.5)
            while claudeProbeInFlight, claudeProbeCondition.wait(until: deadline) {}
            guard !claudeProbeInFlight else {
                claudeProbeCondition.unlock()
                return CodexRequestCredentials(accessToken: nil, accountKey: nil)
            }
            let credentials = claudeAccountProbe?.credentials ?? CodexRequestCredentials(accessToken: nil, accountKey: nil)
            claudeProbeCondition.unlock()
            return credentials
        }
        claudeProbeInFlight = true
        let previous = claudeAccountProbe
        claudeProbeCondition.unlock()
        let stored = credentialReader.claudeCredentials()
        let credentials = CodexRequestCredentials(accessToken: stored.accessToken, accountKey: nil)
        // The email lives in a separate local file; reread it only when the
        // signed-in account changes or it was not available yet.
        let profile: CodexAccountProfile?
        if credentials.accessToken == nil {
            profile = nil
        } else if let previous, previous.credentials == credentials, let email = previous.profile?.email {
            profile = CodexAccountProfile(email: email, planType: stored.planType)
        } else {
            profile = CodexAccountProfile(email: credentialReader.claudeAccountEmail(), planType: stored.planType)
        }
        claudeProbeCondition.lock()
        claudeAccountProbe = (credentials, profile, now())
        claudeProbeInFlight = false
        claudeProbeCondition.broadcast()
        claudeProbeCondition.unlock()
        return credentials
    }

    /// Irreversible fingerprint of the signed-in Claude token, or nil when no
    /// token is available. Never contains credential material.
    static func claudeAccountFingerprint(_ credentials: CodexRequestCredentials?) -> String? {
        guard let token = credentials?.accessToken, !token.isEmpty else { return nil }
        return claudeScope(token: token)
    }

    /// Reading the Claude token launches the Keychain tool, so cadence checks
    /// that run on every provider poll share one reading for a short window.
    /// Requests themselves always freeze a fresh token.
    func currentClaudeAccountFingerprint(maxAge: TimeInterval = 2) -> String? {
        claudeProbeCondition.lock()
        if let probe = claudeAccountProbe, abs(now().timeIntervalSince(probe.readAt)) < maxAge {
            claudeProbeCondition.unlock()
            return Self.claudeAccountFingerprint(probe.credentials)
        }
        claudeProbeCondition.unlock()
        return Self.claudeAccountFingerprint(claudeRequestCredentials(cacheFor: maxAge))
    }

    /// When the last request for the probed account failed (429 wait or any
    /// other error), a manual refresh would only replay that cached failure
    /// until this date; nil when a real request is possible. Never starts `security`.
    func claudeManualRefreshBlockedUntil() -> Date? {
        guard let token = cachedClaudeAccessToken(), !token.isEmpty else { return nil }
        let scope = Self.claudeScope(token: token)
        claudeCacheLock.lock()
        defer { claudeCacheLock.unlock() }
        guard let entry = claudeResponses[scope], case .failure = entry.result else { return nil }
        let next = claudeNextRequestDate(entry, interval: max(60, claudeCalibrationInterval()))
        return next > now() ? next : nil
    }

    /// Stable account identity for notification progress and account-change
    /// detection: a hash of the account email when known, so a refreshed
    /// access token for the same account is not treated as another account.
    /// Falls back to the token fingerprint. Never contains credential material.
    func claudeAccountScope(for credentials: CodexRequestCredentials?) -> String? {
        guard let fingerprint = Self.claudeAccountFingerprint(credentials) else { return nil }
        claudeProbeCondition.lock()
        let email = claudeAccountProbe.flatMap { $0.credentials == credentials ? $0.profile?.email : nil }
        claudeProbeCondition.unlock()
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty else {
            return fingerprint
        }
        return "account:" + SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Rereads the credential store (bounded by `maxAge`) and returns the
    /// current account identity.
    func currentClaudeAccountScope(maxAge: TimeInterval = 2) -> String? {
        claudeAccountScope(for: claudeRequestCredentials(cacheFor: maxAge))
    }

    private func cachedClaudeAccessToken() -> String? {
        claudeProbeCondition.lock()
        defer { claudeProbeCondition.unlock() }
        return claudeAccountProbe?.credentials.accessToken
    }

    /// Display-only email/plan from the last probe; never starts `security`.
    func cachedClaudeAccountProfile() -> CodexAccountProfile? {
        claudeProbeCondition.lock()
        defer { claudeProbeCondition.unlock() }
        return claudeAccountProbe?.profile
    }

    /// Returns only the last background probe. This is safe for UI callbacks:
    /// it never starts `/usr/bin/security` or touches the credential store.
    func cachedClaudeAccountFingerprint() -> String? {
        claudeProbeCondition.lock()
        defer { claudeProbeCondition.unlock() }
        return claudeAccountProbe.flatMap { Self.claudeAccountFingerprint($0.credentials) }
    }

    private static func claudeScope(token: String) -> String {
        CodexRequestCredentials(accessToken: token, accountKey: nil).requestScope
    }

    private func claudeNextRequestDate(
        _ entry: (result: Result<OfficialQuotaResult, OfficialQuotaClientError>, recordedAt: Date, retryUntil: Date?),
        interval: TimeInterval
    ) -> Date {
        max(entry.recordedAt.addingTimeInterval(interval), entry.retryUntil ?? .distantPast)
    }

    /// Seconds since the real request that currently governs Claude's cadence,
    /// adjusted for server backoff. A coordinator anchors its own timer here
    /// so a cache hit never counts as a fresh network calibration.
    func claudeCalibrationAge(context: OfficialQuotaRequestContext) -> TimeInterval? {
        guard context.client == .claude, let token = context.credentials?.accessToken, !token.isEmpty else { return nil }
        let scope = Self.claudeScope(token: token)
        claudeCacheLock.lock()
        defer { claudeCacheLock.unlock() }
        let current = now()
        let interval = max(60, claudeCalibrationInterval())
        if let cached = claudeResponses[scope] {
            let next = claudeNextRequestDate(cached, interval: interval)
            if next > current { return current.timeIntervalSince(next.addingTimeInterval(-interval)) }
        }
        return inFlight.startedAt(key: Self.claudeRequestKey(scope: scope)).map { current.timeIntervalSince($0) }
    }

    static func credentialSource(
        client: AssistantClient,
        storedAccessToken: String?
    ) -> OfficialQuotaCredentialSource {
        client == .codex && storedAccessToken != nil
            ? .storedAccessToken
            : .localReader
    }

    static func requestKey(
        client: AssistantClient,
        providerID: String,
        credentialSource: OfficialQuotaCredentialSource = .localReader,
        requestCredentials: CodexRequestCredentials? = nil,
        storedAccessToken: String? = nil
    ) -> String {
        // Claude requests are shared per account, never per Provider ID.
        if client == .claude, let token = requestCredentials?.accessToken ?? storedAccessToken, !token.isEmpty {
            return claudeRequestKey(scope: claudeScope(token: token))
        }
        let base = "official:\(client.rawValue):\(providerID):\(credentialSource.rawValue)"
        let scope = requestCredentials ?? storedAccessToken.map { CodexRequestCredentials(accessToken: $0, accountKey: nil) }
        return scope.map { base + ":" + $0.requestScope } ?? base
    }

    private static func claudeRequestKey(scope: String) -> String {
        "official:claude:account:" + scope
    }

    func isRequestInFlight(
        client: AssistantClient,
        providerID: String,
        credentialSource: OfficialQuotaCredentialSource = .localReader,
        requestCredentials: CodexRequestCredentials? = nil,
        storedAccessToken: String? = nil
    ) -> Bool {
        inFlight.contains(
            key: Self.requestKey(
                client: client,
                providerID: providerID,
                credentialSource: credentialSource,
                requestCredentials: requestCredentials,
                storedAccessToken: storedAccessToken
            )
        )
    }

    @discardableResult
    func fetchQuota(context: OfficialQuotaRequestContext,
                    completion: @escaping (Result<OfficialQuotaResult, OfficialQuotaClientError>) -> Void) -> Bool {
        fetchQuota(client: context.client, providerID: context.providerID,
            storedAccessToken: context.storedAccessToken, requestCredentials: context.credentials,
            consumerID: context.consumerID, completion: completion)
    }

    /// Releases only this context's caller; other callers on the same
    /// Provider and account keep waiting for the shared response.
    func cancelQuota(context: OfficialQuotaRequestContext) {
        cancelQuota(key: Self.requestKey(client: context.client, providerID: context.providerID,
            credentialSource: context.credentialSource, requestCredentials: context.credentials,
            storedAccessToken: context.storedAccessToken)) { $0.id == context.consumerID }
    }

    /// Duplicate consumers share transport only within the same request scope.
    /// Frozen Codex credentials isolate overlapping account-switch requests;
    /// Claude shares one request per frozen account token across Providers.
    @discardableResult
    func fetchQuota(
        client: AssistantClient,
        providerID: String,
        storedAccessToken: String? = nil,
        requestCredentials: CodexRequestCredentials? = nil,
        consumerID: UUID = UUID(),
        completion: @escaping (Result<OfficialQuotaResult, OfficialQuotaClientError>) -> Void
    ) -> Bool {
        let credentialSource = Self.credentialSource(
            client: client,
            storedAccessToken: storedAccessToken
        )
        if client != .grok, let requestCredentials, requestCredentials.accessToken == nil {
            completion(.failure(.missingCredentials))
            return true
        }
        // Claude freezes its token once; request, scope and cache all use it.
        let claudeToken = client == .claude
            ? (requestCredentials?.accessToken ?? storedAccessToken ?? credentialReader.claudeAccessToken()) : nil
        if client == .claude, claudeToken?.isEmpty != false {
            completion(.failure(.missingCredentials))
            return true
        }
        guard let request = makeRequest(client: client,
            storedAccessToken: claudeToken ?? requestCredentials?.accessToken ?? storedAccessToken) else {
            completion(.failure(.missingCredentials))
            return true
        }

        // Claude's usage endpoint is account-wide. Requests are shared per
        // token scope across Providers and entry points, and every entry point,
        // including manual refresh, honors the calibration interval and any
        // longer server backoff. The interval is anchored to the request start,
        // matching the coordinator's cadence clock.
        let claudeScope = claudeToken.map(Self.claudeScope(token:))
        let key = claudeScope.map(Self.claudeRequestKey(scope:)) ?? Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource,
            requestCredentials: requestCredentials,
            storedAccessToken: storedAccessToken
        )
        let registry = inFlight
        let startedAt = now()
        let consumer = InFlightRegistry.Consumer(providerID: providerID, id: consumerID)
        let registered: UUID?
        if let claudeScope {
            // Cache lookup and registration are atomic with completion's
            // cache write and removal, so no window allows a duplicate request.
            claudeCacheLock.lock()
            if let cached = claudeResponses[claudeScope],
               claudeNextRequestDate(cached, interval: max(60, claudeCalibrationInterval())) > startedAt {
                claudeCacheLock.unlock()
                completion(cached.result)
                return false
            }
            registered = registry.register(key: key, consumer: consumer, startedAt: startedAt, completion: completion)
            claudeCacheLock.unlock()
        } else {
            registered = registry.register(key: key, consumer: consumer, startedAt: startedAt, completion: completion)
        }
        guard let generation = registered else {
            SwitchLog.write("official-quota transport coalesced; scope_omitted=true", level: .debug, category: "refresh.transport")
            return false
        }
        SwitchLog.write("official-quota transport started; client=\(client.rawValue); scope_omitted=true", level: .debug, category: "refresh.transport")

        let parser = self.parser
        let task = (client == .claude ? claudeSession() : session).dataTask(with: request) { [weak self] data, response, error in
            let result: Result<OfficialQuotaResult, OfficialQuotaClientError>
            if let error {
                result = .failure(.transport(Self.transportError(from: error, client: client)))
            } else if let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data {
                result = Self.parse(data: data, client: client, parser: parser)
            } else {
                result = .failure(.httpStatus(
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    dataSize: data?.count ?? 0
                ))
            }
            if case .failure(.httpStatus(let status, _)) = result {
                SwitchLog.write("official quota request failed; client=\(client.rawValue); http_status=\(status)",
                    level: .warning, category: "refresh.transport")
            }
            guard let claudeScope, let self else {
                registry.take(key: key, generation: generation)?.forEach { $0(result) }
                return
            }
            self.claudeCacheLock.lock()
            let completions = registry.take(key: key, generation: generation)
            if completions != nil {
                self.recordClaudeResponse(result, response: response, scope: claudeScope, requestedAt: startedAt)
            }
            self.claudeCacheLock.unlock()
            completions?.forEach { $0(result) }
        }
        registry.attach(task: task, to: key, generation: generation)
        task.resume()
        return true
    }

    /// Caller holds `claudeCacheLock`.
    private func recordClaudeResponse(
        _ result: Result<OfficialQuotaResult, OfficialQuotaClientError>,
        response: URLResponse?,
        scope: String,
        requestedAt: Date
    ) {
        var retryUntil: Date?
        switch result {
        case .success:
            claudeRateLimitFailures.removeValue(forKey: scope)
        case .failure(.httpStatus(let status, _)) where status == 429:
            let failures = min((claudeRateLimitFailures[scope] ?? 0) + 1, 5)
            claudeRateLimitFailures[scope] = failures
            let fallback = min(60 * pow(2, Double(failures - 1)), 900)
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            let ttl: TimeInterval
            if let seconds = header.flatMap(Double.init), seconds.isFinite, seconds > 0 {
                ttl = max(60, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let interval = header.flatMap(formatter.date(from:))?.timeIntervalSince(now()) ?? 0
                ttl = interval > 0 ? max(60, interval) : fallback
            }
            retryUntil = now().addingTimeInterval(ttl)
        default:
            break
        }
        let interval = max(60, claudeCalibrationInterval())
        let current = now()
        claudeResponses = claudeResponses.filter { claudeNextRequestDate($0.value, interval: interval) > current }
        claudeResponses[scope] = (result, requestedAt, retryUntil)
    }

    /// Read-only list of banked Codex reset credits. Used only when the
    /// usage payload has a positive available count but no usable `credits[]`.
    /// Never POSTs consume and never changes the usage request.
    func fetchRateLimitResetCredits(
        storedAccessToken: String? = nil,
        context: OfficialQuotaRequestContext? = nil,
        now: Date = Date(),
        completion: @escaping (Result<CodexBankedReset?, OfficialQuotaClientError>) -> Void
    ) {
        guard let request = makeRateLimitResetCreditsRequest(
            storedAccessToken: storedAccessToken
        ) else {
            completion(.failure(.missingCredentials))
            return
        }

        let key = context.map { Self.requestKey(client: $0.client, providerID: $0.providerID,
            credentialSource: $0.credentialSource, requestCredentials: $0.credentials,
            storedAccessToken: $0.storedAccessToken) } ?? UUID().uuidString
        let generation = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let self {
                self.creditLock.lock()
                if self.creditRequests[key]?.0 == generation { self.creditRequests.removeValue(forKey: key) }
                self.creditLock.unlock()
            }
            if let error {
                completion(.failure(.transport(Self.transportError(from: error))))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                completion(.failure(.httpStatus(
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    dataSize: data?.count ?? 0
                )))
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard object is [String: Any] else {
                    completion(.failure(.invalidJSON(dataSize: data.count)))
                    return
                }
            } catch {
                completion(.failure(.invalidJSON(dataSize: data.count)))
                return
            }
            completion(.success(
                OfficialQuotaResponseParser.parseBankedResetCredits(data: data, now: now)
            ))
        }
        creditLock.lock()
        let previous = creditRequests.updateValue((generation, task), forKey: key)?.1
        creditLock.unlock()
        previous?.cancel()
        task.resume()
    }

    /// Public Codex reset forecast. No credentials. Failure is placeholders
    /// and never fails the official quota snapshot.
    func fetchCodexResetForecast(
        completion: @escaping (CodexResetForecast) -> Void
    ) {
        var request = URLRequest(url: CodexResetForecastParser.forecastURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.unavailable)
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                completion(.unavailable)
                return
            }
            completion(CodexResetForecastParser.parse(data: data))
        }
        task.resume()
    }

    private static func parse(
        data: Data,
        client: AssistantClient,
        parser: OfficialQuotaParsing
    ) -> Result<OfficialQuotaResult, OfficialQuotaClientError> {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else {
                return .failure(.invalidJSON(
                    dataSize: data.count
                ))
            }
        } catch {
            return .failure(.invalidJSON(dataSize: data.count))
        }

        do {
            let output = try parser.parse(data: data, client: client)
            return .success(OfficialQuotaResult(output: output, dataSize: data.count))
        } catch let error as ResponseParserError {
            switch error {
            case .invalidJSON:
                return .failure(.invalidJSON(dataSize: data.count))
            case .unsupportedFormat:
                return .failure(.unsupportedFormat(dataSize: data.count))
            }
        } catch {
            return .failure(.unsupportedFormat(dataSize: data.count))
        }
    }

    private static func transportError(
        from error: Error,
        client: AssistantClient? = nil
    ) -> OfficialQuotaTransportError {
        guard let urlError = error as? URLError else { return .unknown }
        if client == .claude, urlError.code != .cancelled, mayNeedProxy(urlError.code) {
            return .possibleProxy(urlError.code)
        }
        return .urlError(urlError.code)
    }

    private static func mayNeedProxy(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Cancels every consumer this Provider registered on the request. Shared
    /// transport stops only when no other consumer waits; a late callback is
    /// ignored by the registry.
    func cancelQuota(
        client: AssistantClient,
        providerID: String,
        credentialSource: OfficialQuotaCredentialSource = .localReader,
        requestCredentials: CodexRequestCredentials? = nil,
        storedAccessToken: String? = nil
    ) {
        let key = Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource,
            requestCredentials: requestCredentials,
            storedAccessToken: storedAccessToken
        )
        cancelQuota(key: key) { $0.providerID == providerID }
    }

    private func cancelQuota(key: String, where matches: (InFlightRegistry.Consumer) -> Bool) {
        creditLock.lock()
        let creditTask = creditRequests.removeValue(forKey: key)?.1
        creditLock.unlock()
        creditTask?.cancel()
        let completions = inFlight.cancel(key: key, where: matches)
        let result: Result<OfficialQuotaResult, OfficialQuotaClientError> =
            .failure(.transport(.urlError(.cancelled)))
        completions.forEach { $0(result) }
    }

    private func makeRequest(
        client: AssistantClient,
        storedAccessToken: String?
    ) -> URLRequest? {
        let accessToken: String?
        let url: URL
        switch client {
        case .codex:
            accessToken = storedAccessToken ?? credentialReader.codexAccessToken()
            url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        case .claude:
            accessToken = storedAccessToken ?? credentialReader.claudeAccessToken()
            url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        case .grok:
            return nil
        }
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if client == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    private func makeRateLimitResetCreditsRequest(
        storedAccessToken: String?
    ) -> URLRequest? {
        let accessToken = storedAccessToken ?? credentialReader.codexAccessToken()
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
