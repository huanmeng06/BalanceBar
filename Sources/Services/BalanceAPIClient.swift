import Foundation
import CryptoKit

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
        private struct Entry {
            let token: UUID
            var completions: [Completion]
            var task: URLSessionDataTask?
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func register(key: String, completion: @escaping Completion) -> UUID? {
            lock.lock(); defer { lock.unlock() }
            if entries[key] != nil {
                entries[key]?.completions.append(completion)
                return nil
            }
            let token = UUID()
            entries[key] = Entry(token: token, completions: [completion])
            return token
        }

        func attach(_ task: URLSessionDataTask, key: String, token: UUID) {
            lock.lock(); defer { lock.unlock() }
            guard entries[key]?.token == token else { task.cancel(); return }
            entries[key]?.task = task
        }

        func contains(prefix: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return entries.keys.contains { $0.dropLast(65) == prefix }
        }

        func finish(key: String, token: UUID, result: Result<BalanceAPIResult, BalanceAPIClientError>) {
            lock.lock()
            guard entries[key]?.token == token else { lock.unlock(); return }
            let completions = entries.removeValue(forKey: key)?.completions ?? []
            lock.unlock()
            completions.forEach { $0(result) }
        }

        func cancel(key: String) {
            lock.lock()
            let entry = entries.removeValue(forKey: key)
            lock.unlock()
            finishCancel(entry)
        }

        func cancel(prefix: String) {
            lock.lock()
            let matches = entries.filter { $0.key == prefix || $0.key.hasPrefix(prefix + ":") }
            for key in matches.keys { entries.removeValue(forKey: key) }
            lock.unlock()
            matches.values.forEach { finishCancel($0) }
        }

        private func finishCancel(_ entry: Entry?) {
            entry?.task?.cancel()
            entry?.completions.forEach { $0(.failure(.transport(URLError(.cancelled)))) }
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

    /// Configured query identity prevents consumers of changed credentials from
    /// joining an old transport. No secret is retained in registry keys.
    private static func scopedRequestKey(query: BalanceQuery, client: AssistantClient, providerID: String) -> String {
        let headers = query.additionalHeaders.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let fields: [Any] = [query.url, query.apiKey, query.timeoutSeconds, query.isRightCode,
                            query.subscriptionPrefix, String(describing: query.nativeBalanceProvider), query.isNewAPI, headers]
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        let scope = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return requestKey(client: client, providerID: providerID) + ":" + scope
    }

    func cancelBalance(query: BalanceQuery, client: AssistantClient, providerID: String) {
        inFlight.cancel(key: Self.scopedRequestKey(query: query, client: client, providerID: providerID))
    }

    func cancelBalance(client: AssistantClient, providerID: String) {
        inFlight.cancel(prefix: Self.requestKey(client: client, providerID: providerID))
    }

    /// Whether a third-party balance request for this key is currently
    /// in flight. Exposed for tests that verify cleanup after completion,
    /// transport error, HTTP error, and parse failures.
    func isRequestInFlight(client: AssistantClient, providerID: String) -> Bool {
        inFlight.contains(prefix: Self.requestKey(client: client, providerID: providerID))
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

        let key = Self.scopedRequestKey(query: query, client: client, providerID: providerID)
        let registry = inFlight
        guard let token = registry.register(key: key, completion: completion) else {
            SwitchLog.write("balance transport coalesced; scope_omitted=true", level: .debug, category: "refresh.transport")
            return false
        }
        SwitchLog.write("balance transport started; scope_omitted=true", level: .debug, category: "refresh.transport")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(query.timeoutSeconds)
        request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in query.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: request) { data, response, error in
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
            registry.finish(key: key, token: token, result: result)
        }
        registry.attach(task, key: key, token: token)
        task.resume()
        return true
    }
}
