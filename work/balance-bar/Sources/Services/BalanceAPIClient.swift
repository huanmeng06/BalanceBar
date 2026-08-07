import Foundation

/// Errors surfaced by `BalanceAPIClient` for third-party balance requests.
/// Values never include the request URL, Authorization header, or any other
/// credential material so diagnostics stay safe to log.
enum BalanceAPIClientError: Error {
    case nonHTTPS
    case transport(Error)
    case httpStatus(Int)
    case invalidJSON(dataSize: Int, underlying: Error)
    case unsupportedFormat(dataSize: Int)
}

/// A successfully decoded third-party balance response.
struct BalanceAPIResult {
    let output: BalanceResponseParser.Output
    let dataSize: Int
}

/// Executes third-party Provider balance requests and reuses
/// `BalanceResponseParser` for response decoding.
///
/// The transport (`URLSession`) is injectable so tests can run entirely
/// offline through a `URLProtocol` stub. Concurrent requests for the same
/// `client` + `providerID` key share one transport request, and every consumer
/// receives its result. The key is always released on completion, transport
/// error, HTTP error, or parse failure.
final class BalanceAPIClient {
    private typealias Completion = (Result<BalanceAPIResult, BalanceAPIClientError>) -> Void

    /// Owns in-flight state independently from the API client so a request can
    /// finish and release its key even after the client itself is gone.
    private final class InFlightRegistry {
        private let lock = NSLock()
        private var completionsByKey: [String: [Completion]] = [:]

        /// Returns true when this call owns the transport request. Duplicate
        /// consumers are retained and will receive the same eventual result.
        func register(key: String, completion: @escaping Completion) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if completionsByKey[key] != nil {
                completionsByKey[key, default: []].append(completion)
                return false
            }
            completionsByKey[key] = [completion]
            return true
        }

        func contains(key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completionsByKey[key] != nil
        }

        /// Remove the key before invoking consumers so a callback can safely
        /// start a new request for the same provider.
        func finish(key: String, result: Result<BalanceAPIResult, BalanceAPIClientError>) {
            lock.lock()
            let completions = completionsByKey.removeValue(forKey: key) ?? []
            lock.unlock()
            completions.forEach { $0(result) }
        }
    }

    private let session: URLSession
    private let inFlight = InFlightRegistry()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Stable key identifying one third-party balance request.
    static func requestKey(client: AssistantClient, providerID: String) -> String {
        "balance:\(client.rawValue):\(providerID)"
    }

    /// Whether a third-party balance request for this key is currently
    /// in flight. Exposed for tests that verify cleanup after completion,
    /// transport error, HTTP error, and parse failures.
    func isRequestInFlight(client: AssistantClient, providerID: String) -> Bool {
        inFlight.contains(key: Self.requestKey(client: client, providerID: providerID))
    }

    /// Starts a third-party balance request.
    ///
    /// - Returns: `false` when a request for the same `client`/`providerID`
    ///   is already in flight and this consumer was attached to it; `true`
    ///   when this call started the transport request.
    @discardableResult
    func fetchBalance(
        query: BalanceQuery,
        client: AssistantClient,
        providerID: String,
        completion: @escaping (Result<BalanceAPIResult, BalanceAPIClientError>) -> Void
    ) -> Bool {
        guard let url = URL(string: query.url),
              url.scheme?.lowercased() == "https" else {
            completion(.failure(.nonHTTPS))
            return true
        }

        let key = Self.requestKey(client: client, providerID: providerID)
        let registry = inFlight
        guard registry.register(key: key, completion: completion) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(query.timeoutSeconds)
        request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in query.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        session.dataTask(with: request) { data, response, error in
            let result: Result<BalanceAPIResult, BalanceAPIClientError>
            if let error {
                result = .failure(.transport(error))
            } else if let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data {
                do {
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    if let output = try? BalanceResponseParser.parse(
                        object: object,
                        query: query
                    ) {
                        result = .success(BalanceAPIResult(
                            output: output,
                            dataSize: data.count
                        ))
                    } else {
                        result = .failure(.unsupportedFormat(dataSize: data.count))
                    }
                } catch let error {
                    result = .failure(.invalidJSON(dataSize: data.count, underlying: error))
                }
            } else {
                result = .failure(.httpStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? -1
                ))
            }
            registry.finish(key: key, result: result)
        }.resume()
        return true
    }
}
