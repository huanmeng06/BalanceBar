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
    case unknown
}

extension OfficialQuotaTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .urlError(let code):
            return URLError(code).localizedDescription
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
    func codexRequestCredentials() -> CodexRequestCredentials
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
        private struct Entry {
            let generation: UUID
            var completions: [Completion]
            var task: URLSessionDataTask?
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func register(key: String, completion: @escaping Completion) -> UUID? {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] != nil {
                entries[key]?.completions.append(completion)
                return nil
            }
            let generation = UUID()
            entries[key] = Entry(generation: generation, completions: [completion], task: nil)
            return generation
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

        func finish(
            key: String,
            generation: UUID,
            result: Result<OfficialQuotaResult, OfficialQuotaClientError>,
            beforeCompletion: () -> Void = {}
        ) {
            lock.lock()
            guard entries[key]?.generation == generation else { lock.unlock(); return }
            let completions = entries.removeValue(forKey: key)?.completions ?? []
            lock.unlock()
            beforeCompletion()
            completions.forEach { $0(result) }
        }

        func cancel(key: String) -> [Completion] {
            lock.lock()
            let entry = entries.removeValue(forKey: key)
            lock.unlock()
            entry?.task?.cancel()
            return entry?.completions ?? []
        }
    }

    private let session: URLSession
    private let credentialReader: OfficialQuotaCredentialReading
    private let parser: OfficialQuotaParsing
    private let now: () -> Date
    private let claudeCacheLock = NSLock()
    private var claudeResponses: [String: (result: Result<OfficialQuotaResult, OfficialQuotaClientError>, expiresAt: Date)] = [:]
    private var claudeRateLimitFailures: [String: Int] = [:]
    private let inFlight = InFlightRegistry()
    private let creditLock = NSLock()
    private var creditRequests: [String: (UUID, URLSessionDataTask)] = [:]

    init(
        session: URLSession = .shared,
        credentialReader: OfficialQuotaCredentialReading = CredentialReader(),
        parser: OfficialQuotaParsing = DefaultOfficialQuotaParser(),
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.credentialReader = credentialReader
        self.parser = parser
        self.now = now
    }

    /// Reads the same Codex auth source used by official quota requests. The
    /// returned profile contains only display-safe claims, never token material.
    func codexAccountProfile() -> CodexAccountProfile? {
        credentialReader.codexAccountProfile()
    }

    func codexRequestCredentials() -> CodexRequestCredentials {
        credentialReader.codexRequestCredentials()
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
            completion: completion)
    }

    func cancelQuota(context: OfficialQuotaRequestContext) {
        cancelQuota(client: context.client, providerID: context.providerID,
            credentialSource: context.credentialSource, requestCredentials: context.credentials,
            storedAccessToken: context.storedAccessToken)
    }

    /// Duplicate consumers share transport only within the same request scope.
    /// Frozen Codex credentials isolate overlapping account-switch requests.
    @discardableResult
    func fetchQuota(
        client: AssistantClient,
        providerID: String,
        storedAccessToken: String? = nil,
        requestCredentials: CodexRequestCredentials? = nil,
        completion: @escaping (Result<OfficialQuotaResult, OfficialQuotaClientError>) -> Void
    ) -> Bool {
        let credentialSource = Self.credentialSource(
            client: client,
            storedAccessToken: storedAccessToken
        )
        if client == .codex, let requestCredentials, requestCredentials.accessToken == nil {
            completion(.failure(.missingCredentials))
            return true
        }
        guard let request = makeRequest(client: client, storedAccessToken: requestCredentials?.accessToken ?? storedAccessToken) else {
            completion(.failure(.missingCredentials))
            return true
        }

        // Claude's usage endpoint is account-wide. Share a short-lived result
        // across startup, summaries and activity refreshes using an opaque token
        // scope. Every entry point, including manual refresh, honors the same
        // one-minute calibration interval and any longer server backoff.
        let claudeScope = client == .claude ? CodexRequestCredentials(
            accessToken: request.value(forHTTPHeaderField: "Authorization"), accountKey: nil
        ).requestScope : nil
        if let claudeScope {
            claudeCacheLock.lock()
            let cached = claudeResponses[claudeScope]
            claudeCacheLock.unlock()
            if let cached, cached.expiresAt > now() {
                completion(cached.result)
                return false
            }
        }
        let key = Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource,
            requestCredentials: requestCredentials,
            storedAccessToken: storedAccessToken
        )
        let registry = inFlight
        guard let generation = registry.register(key: key, completion: completion) else {
            SwitchLog.write("official-quota transport coalesced; scope_omitted=true", level: .debug, category: "refresh.transport")
            return false
        }
        SwitchLog.write("official-quota transport started; client=\(client.rawValue); scope_omitted=true", level: .debug, category: "refresh.transport")

        let parser = self.parser
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<OfficialQuotaResult, OfficialQuotaClientError>
            if let error {
                result = .failure(.transport(Self.transportError(from: error)))
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
            registry.finish(key: key, generation: generation, result: result) {
                guard let claudeScope, let self else { return }
                self.claudeCacheLock.lock()
                let ttl: TimeInterval
                switch result {
                case .success:
                    self.claudeRateLimitFailures.removeValue(forKey: claudeScope)
                    ttl = 60
                case .failure(.httpStatus(let status, _)) where status == 429:
                    let failures = min((self.claudeRateLimitFailures[claudeScope] ?? 0) + 1, 5)
                    self.claudeRateLimitFailures[claudeScope] = failures
                    let fallback = min(60 * pow(2, Double(failures - 1)), 900)
                    let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                    if let seconds = header.flatMap(Double.init), seconds.isFinite, seconds > 0 {
                        ttl = max(60, seconds)
                    } else {
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.timeZone = TimeZone(secondsFromGMT: 0)
                        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                        let interval = header.flatMap(formatter.date(from:))?.timeIntervalSince(self.now()) ?? 0
                        ttl = interval > 0 ? max(60, interval) : fallback
                    }
                default: ttl = 60
                }
                self.claudeResponses = self.claudeResponses.filter { $0.value.expiresAt > self.now() }
                self.claudeResponses[claudeScope] = (result, self.now().addingTimeInterval(ttl))
                self.claudeCacheLock.unlock()
            }
        }
        registry.attach(task: task, to: key, generation: generation)
        task.resume()
        return true
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

    private static func transportError(from error: Error) -> OfficialQuotaTransportError {
        guard let urlError = error as? URLError else { return .unknown }
        return .urlError(urlError.code)
    }

    /// Cancels a request and immediately releases all consumers. URLSession may
    /// still deliver a late cancellation callback, but the registry ignores it.
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
        creditLock.lock()
        let creditTask = creditRequests.removeValue(forKey: key)?.1
        creditLock.unlock()
        creditTask?.cancel()
        let completions = inFlight.cancel(key: key)
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
            accessToken = credentialReader.claudeAccessToken()
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
