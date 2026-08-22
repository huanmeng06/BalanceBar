import Foundation

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
}

/// Identifies the credential path used by a request without retaining the
/// credential itself in request-deduplication state.
enum OfficialQuotaCredentialSource: String, Hashable {
    case localReader = "local-reader"
    case storedAccessToken = "stored-access-token"
}

protocol OfficialQuotaCredentialReading {
    func codexAccessToken() -> String?
    func codexAccountEmail() -> String?
    func claudeAccessToken() -> String?
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
            var completions: [Completion]
            var task: URLSessionDataTask?
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func register(key: String, completion: @escaping Completion) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] != nil {
                entries[key, default: Entry(completions: [], task: nil)].completions.append(completion)
                return false
            }
            entries[key] = Entry(completions: [completion], task: nil)
            return true
        }

        func attach(task: URLSessionDataTask, to key: String) {
            lock.lock()
            guard var entry = entries[key] else {
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
            result: Result<OfficialQuotaResult, OfficialQuotaClientError>
        ) {
            lock.lock()
            let completions = entries.removeValue(forKey: key)?.completions ?? []
            lock.unlock()
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
    private let inFlight = InFlightRegistry()

    init(
        session: URLSession = .shared,
        credentialReader: OfficialQuotaCredentialReading = CredentialReader(),
        parser: OfficialQuotaParsing = DefaultOfficialQuotaParser()
    ) {
        self.session = session
        self.credentialReader = credentialReader
        self.parser = parser
    }

    /// Reads the same Codex auth source used by official quota requests. The
    /// returned value is the email claim, never the access token itself.
    func codexAccountEmail() -> String? {
        credentialReader.codexAccountEmail()
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
        credentialSource: OfficialQuotaCredentialSource = .localReader
    ) -> String {
        "official:\(client.rawValue):\(providerID):\(credentialSource.rawValue)"
    }

    func isRequestInFlight(
        client: AssistantClient,
        providerID: String,
        credentialSource: OfficialQuotaCredentialSource = .localReader
    ) -> Bool {
        inFlight.contains(
            key: Self.requestKey(
                client: client,
                providerID: providerID,
                credentialSource: credentialSource
            )
        )
    }

    /// Starts one request for a client/provider/credential-source key.
    /// Duplicate consumers with the same source share the transport and each
    /// receives its result, matching BalanceAPIClient.
    @discardableResult
    func fetchQuota(
        client: AssistantClient,
        providerID: String,
        storedAccessToken: String? = nil,
        completion: @escaping (Result<OfficialQuotaResult, OfficialQuotaClientError>) -> Void
    ) -> Bool {
        let credentialSource = Self.credentialSource(
            client: client,
            storedAccessToken: storedAccessToken
        )
        guard let request = makeRequest(client: client, storedAccessToken: storedAccessToken) else {
            completion(.failure(.missingCredentials))
            return true
        }

        let key = Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource
        )
        let registry = inFlight
        guard registry.register(key: key, completion: completion) else {
            return false
        }

        let parser = self.parser
        let task = session.dataTask(with: request) { data, response, error in
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
            registry.finish(key: key, result: result)
        }
        registry.attach(task: task, to: key)
        task.resume()
        return true
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
        credentialSource: OfficialQuotaCredentialSource = .localReader
    ) {
        let key = Self.requestKey(
            client: client,
            providerID: providerID,
            credentialSource: credentialSource
        )
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
}
