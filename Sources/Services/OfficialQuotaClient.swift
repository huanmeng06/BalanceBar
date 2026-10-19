import Foundation
import CryptoKit
import Network

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
    private var claudeSessionConfiguration: CCSwitchProxyConfiguration?
    private let credentialReader: OfficialQuotaCredentialReading
    private let parser: OfficialQuotaParsing
    private let now: () -> Date
    private var claudeAccountProbe: (credentials: CodexRequestCredentials, profile: CodexAccountProfile?, readAt: Date)?
    private var claudeProbeInFlight = false
    private let claudeProbeCondition = NSCondition()

    private let inFlight = InFlightRegistry()
    private let creditLock = NSLock()
    private var creditRequests: [String: (UUID, URLSessionDataTask)] = [:]

    init(
        session: URLSession? = nil,
        claudeSession: URLSession? = nil,
        claudeProxyConfiguration: CCSwitchProxyConfiguration? = nil,
        claudeProxyConfigurationProvider: (() -> CCSwitchProxyConfiguration)? = nil,
        credentialReader: OfficialQuotaCredentialReading = CredentialReader(),
        parser: OfficialQuotaParsing = DefaultOfficialQuotaParser(),
        now: @escaping () -> Date = Date.init
    ) {
        let baseSession = session ?? .shared
        self.session = baseSession
        self.claudeSessionStorage = claudeSession
            ?? (claudeProxyConfiguration == nil && claudeProxyConfigurationProvider == nil && session != nil ? baseSession : nil)
        self.claudeSessionConfiguration = claudeSession != nil || (session != nil && claudeProxyConfiguration == nil && claudeProxyConfigurationProvider == nil)
            ? CCSwitchProxyConfiguration() : nil
        if let claudeProxyConfigurationProvider {
            self.claudeProxyConfigurationProvider = claudeProxyConfigurationProvider
        } else if let claudeProxyConfiguration {
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
        configuration.connectionProxyDictionary = nil
        configuration.proxyConfigurations = proxyConfigurations(for: proxyConfiguration)
        return URLSession(configuration: configuration)
    }

    private static func proxyConfigurations(
        for configuration: CCSwitchProxyConfiguration
    ) -> [ProxyConfiguration] {
        guard let proxy = configuration.httpsProxy ?? configuration.allProxy,
              let host = proxy.host, !host.isEmpty,
              let endpoint = proxyEndpoint(for: proxy) else { return [] }
        let scheme = proxy.scheme?.lowercased() ?? ""
        let port = proxy.port ?? {
            if scheme == "socks" || scheme == "socks5" || scheme == "socks5h" { return 1080 }
            return scheme == "https" ? 443 : 80
        }()
        guard (1...65535).contains(port) else { return [] }
        var proxyConfiguration: ProxyConfiguration
        if scheme == "socks" || scheme == "socks5" || scheme == "socks5h" {
            proxyConfiguration = ProxyConfiguration(socksv5Proxy: endpoint)
        } else {
            let tlsOptions = scheme == "https" ? NWProtocolTLS.Options() : nil
            proxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: tlsOptions)
        }
        if let username = proxy.user {
            proxyConfiguration.applyCredential(username: username, password: proxy.password ?? "")
        }
        return [proxyConfiguration]
    }

    private static func proxyEndpoint(for proxy: URL) -> NWEndpoint? {
        let port = proxy.port ?? {
            switch proxy.scheme?.lowercased() {
            case "socks", "socks5", "socks5h": return 1080
            case "https": return 443
            default: return 80
            }
        }()
        guard let host = proxy.host, !host.isEmpty,
              (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    private func claudeSession() -> URLSession {
        let configuration = claudeProxyConfigurationProvider?() ?? CCSwitchProxyConfiguration()
        claudeSessionLock.lock()
        defer { claudeSessionLock.unlock() }
        if let claudeSessionStorage, claudeSessionConfiguration == configuration {
            return claudeSessionStorage
        }
        if configuration.isEmpty {
            claudeSessionStorage = session
        } else {
            claudeSessionStorage = Self.makeClaudeSession(
                baseSession: session,
                proxyConfiguration: configuration
            )
        }
        claudeSessionConfiguration = configuration
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

    /// Display-only email/plan from the last probe; never starts `security`.
    func cachedClaudeAccountProfile() -> CodexAccountProfile? {
        claudeProbeCondition.lock()
        defer { claudeProbeCondition.unlock() }
        return claudeAccountProbe?.profile
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
        let base = "official:\(client.rawValue):\(providerID):\(credentialSource.rawValue)"
        let scope = requestCredentials ?? storedAccessToken.map { CodexRequestCredentials(accessToken: $0, accountKey: nil) }
        return scope.map { base + ":" + $0.requestScope } ?? base
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
    /// Frozen Codex credentials isolate overlapping account-switch requests.
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
        guard let request = makeRequest(client: client,
            storedAccessToken: requestCredentials?.accessToken ?? storedAccessToken) else {
            completion(.failure(.missingCredentials))
            return true
        }

        // Claude never reaches this path: its single request boundary is the
        // FetchScheduler through `fetchClaudeUsage`.
        let key = Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource,
            requestCredentials: requestCredentials,
            storedAccessToken: storedAccessToken
        )
        let registry = inFlight
        let startedAt = now()
        let consumer = InFlightRegistry.Consumer(providerID: providerID, id: consumerID)
        guard let generation = registry.register(key: key, consumer: consumer, startedAt: startedAt, completion: completion) else {
            SwitchLog.write("official-quota transport coalesced; scope_omitted=true", level: .debug, category: "refresh.transport")
            return false
        }
        SwitchLog.write("official-quota transport started; client=\(client.rawValue); scope_omitted=true", level: .debug, category: "refresh.transport")

        let parser = self.parser
        let task = session.dataTask(with: request) { data, response, error in
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
            registry.take(key: key, generation: generation)?.forEach { $0(result) }
        }
        registry.attach(task: task, to: key, generation: generation)
        task.resume()
        return true
    }

    /// Performs exactly one Claude usage request and reports the raw outcome.
    ///
    /// This is the transport behind `FetchScheduler`: it neither caches, backs
    /// off, nor shares requests, because the scheduler alone decides whether a
    /// request may be sent. The token is read once and `didReadToken` receives
    /// it before the request starts so the caller can record its version.
    func fetchClaudeUsage(
        didReadToken: (String) -> Void = { _ in },
        completion: @escaping (UsageFetchResult, OfficialQuotaClientError?) -> Void
    ) {
        guard let token = claudeRequestCredentials(cacheFor: 0).accessToken, !token.isEmpty,
              let request = makeRequest(client: .claude, storedAccessToken: token) else {
            completion(.failure("missing_credentials"), .missingCredentials)
            return
        }
        didReadToken(token)
        SwitchLog.write("official-quota transport started; client=claude; scope_omitted=true", level: .debug, category: "refresh.transport")
        claudeSession().dataTask(with: request) { data, response, error in
            if let error {
                let failure = OfficialQuotaClientError.transport(Self.transportError(from: error, client: .claude))
                completion(.failure("transport"), failure)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200..<300:
                completion(.success(data ?? Data()), nil)
            case 429:
                SwitchLog.write("official quota request failed; client=claude; http_status=429", level: .warning, category: "refresh.transport")
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                completion(.rateLimited(retryAfter: retryAfter), .httpStatus(statusCode: 429, dataSize: data?.count ?? 0))
            case 401:
                SwitchLog.write("official quota request failed; client=claude; http_status=401", level: .warning, category: "refresh.transport")
                completion(.unauthorized, .httpStatus(statusCode: 401, dataSize: data?.count ?? 0))
            default:
                SwitchLog.write("official quota request failed; client=claude; http_status=\(status)", level: .warning, category: "refresh.transport")
                completion(.failure("http_\(status)"), .httpStatus(statusCode: status, dataSize: data?.count ?? 0))
            }
        }.resume()
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
