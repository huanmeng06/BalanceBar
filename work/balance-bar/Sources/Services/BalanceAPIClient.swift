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
/// `client` + `providerID` key are deduplicated in-flight and the key is
/// always released on completion, transport error, HTTP error, or parse
/// failure.
final class BalanceAPIClient {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: Set<String> = []

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
        lock.lock()
        defer { lock.unlock() }
        return inFlight.contains(Self.requestKey(client: client, providerID: providerID))
    }

    /// Starts a third-party balance request.
    ///
    /// - Returns: `false` when a request for the same `client`/`providerID`
    ///   is already in flight (the caller should silently skip, matching the
    ///   previous AppDelegate behavior); `true` when the request was started.
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
        lock.lock()
        guard inFlight.insert(key).inserted else {
            lock.unlock()
            return false
        }
        lock.unlock()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(query.timeoutSeconds)
        request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in query.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.endRequest(key) }

            if let error {
                completion(.failure(.transport(error)))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                completion(.failure(.httpStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? -1
                )))
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let result = try? BalanceResponseParser.parse(
                    object: object,
                    query: query
                ) else {
                    completion(.failure(.unsupportedFormat(dataSize: data.count)))
                    return
                }
                completion(.success(BalanceAPIResult(
                    output: result,
                    dataSize: data.count
                )))
            } catch let error {
                completion(.failure(.invalidJSON(dataSize: data.count, underlying: error)))
            }
        }.resume()
        return true
    }

    private func endRequest(_ key: String) {
        lock.lock()
        inFlight.remove(key)
        lock.unlock()
    }
}
