import Foundation
import XCTest
@testable import BalanceBar

final class BalanceAPIClientTests: XCTestCase {
    private struct StubResult {
        let statusCode: Int
        let data: Data?
        let error: Error?

        init(statusCode: Int = 200, data: Data? = nil, error: Error? = nil) {
            self.statusCode = statusCode
            self.data = data
            self.error = error
        }
    }

    /// Offline `URLProtocol` stub: every request is answered by the current
    /// `onRequest` handler without touching the network.
    private final class StubURLProtocol: URLProtocol {
        private static let stateLock = NSLock()
        private static var requestHandler: ((URLRequest) -> StubResult)?
        private static var recordedRequests: [URLRequest] = []

        static func reset() {
            stateLock.lock()
            requestHandler = nil
            recordedRequests = []
            stateLock.unlock()
        }

        static func setHandler(_ handler: @escaping (URLRequest) -> StubResult) {
            stateLock.lock()
            requestHandler = handler
            stateLock.unlock()
        }

        static var requestCount: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return recordedRequests.count
        }

        static var lastRequest: URLRequest? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return recordedRequests.last
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let result: StubResult
            let request = Self.record(request)
            Self.stateLock.lock()
            let handler = Self.requestHandler
            Self.stateLock.unlock()
            if let handler {
                result = handler(request)
            } else {
                result = StubResult(statusCode: 200, data: Data(#"{"balance":"0"}"#.utf8))
            }
            if let error = result.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func record(_ request: URLRequest) -> URLRequest {
            stateLock.lock()
            recordedRequests.append(request)
            stateLock.unlock()
            return request
        }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.finishTasksAndInvalidate()
        session = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeQuery(
        url: String = "https://provider.example.test/v1/usage",
        apiKey: String = "fixture-sanitized-key",
        timeoutSeconds: Int = 15,
        additionalHeaders: [String: String] = [:]
    ) -> BalanceQuery {
        BalanceQuery(
            url: url,
            websiteURL: URL(string: "https://provider.example.test"),
            apiKey: apiKey,
            intervalMinutes: 30,
            timeoutSeconds: timeoutSeconds,
            isRightCode: false,
            subscriptionPrefix: "/codex",
            nativeBalanceProvider: nil,
            isNewAPI: false,
            additionalHeaders: additionalHeaders
        )
    }

    private func balanceBody(_ amount: String = "12.50", unit: String = "CNY") -> Data {
        Data(#"{"balance":"\#(amount)","quota":{"unit":"\#(unit)"}}"#.utf8)
    }

    private func waitForResult(
        _ client: BalanceAPIClient,
        query: BalanceQuery,
        clientName: AssistantClient = .codex,
        providerID: String = "provider-1"
    ) throws -> Result<BalanceAPIResult, BalanceAPIClientError> {
        let expectation = expectation(description: "balance request completed")
        var captured: Result<BalanceAPIResult, BalanceAPIClientError>?
        let started = client.fetchBalance(
            query: query,
            client: clientName,
            providerID: providerID
        ) { result in
            captured = result
            expectation.fulfill()
        }
        XCTAssertTrue(started, "request should have started")
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(captured)
    }

    // MARK: - Request construction and headers

    func testRequestConstructionAppliesMethodURLTimeoutAuthorizationAcceptAndExtraHeaders() throws {
        let query = makeQuery(
            url: "https://provider.example.test/v1/usage",
            apiKey: "fixture-sanitized-key",
            timeoutSeconds: 7,
            additionalHeaders: [
                "Content-Type": "application/json",
                "New-Api-User": "fixture-user-1",
                "User-Agent": "cc-switch/1.0"
            ]
        )
        StubURLProtocol.setHandler { request in
            StubResult(statusCode: 200, data: self.balanceBody("8.25", unit: "USD"))
        }

        let result = try waitForResult(BalanceAPIClient(session: session), query: query)

        guard case .success(let response) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(response.output.amount, 8.25, accuracy: 0.000001)
        XCTAssertEqual(response.output.unit, "USD")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, query.url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 7)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-sanitized-key"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "New-Api-User"), "fixture-user-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-switch/1.0")
    }

    func testAdditionalHeadersApplyAfterDefaultsAndCanOverrideSameName() throws {
        let query = makeQuery(
            apiKey: "fixture-sanitized-key",
            additionalHeaders: ["Accept": "application/vnd.provider+json"]
        )
        StubURLProtocol.setHandler { request in
            StubResult(statusCode: 200, data: self.balanceBody())
        }

        _ = try waitForResult(BalanceAPIClient(session: session), query: query)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/vnd.provider+json",
            "additional headers keep their existing priority over the default Accept"
        )
    }

    func testHTTPSValidationRejectsNonHTTPSAndDoesNotLeakInFlightState() throws {
        let client = BalanceAPIClient(session: session)
        let expectation = expectation(description: "non-HTTPS rejected")
        var captured: Result<BalanceAPIResult, BalanceAPIClientError>?
        let started = client.fetchBalance(
            query: makeQuery(url: "http://provider.example.test/v1/usage"),
            client: .codex,
            providerID: "provider-1"
        ) { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(started)
        guard case .failure(.nonHTTPS)? = captured else {
            return XCTFail("expected nonHTTPS failure, got \(String(describing: captured))")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "non-HTTPS must not hit the transport")
        XCTAssertFalse(
            client.isRequestInFlight(client: .codex, providerID: "provider-1"),
            "non-HTTPS rejection must not leave in-flight state"
        )

        // A subsequent HTTPS request for the same key must still start.
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 200, data: self.balanceBody("3.5", unit: "CNY"))
        }
        let second = try waitForResult(client, query: makeQuery())
        guard case .success(let response) = second else {
            return XCTFail("expected success after non-HTTPS rejection, got \(second)")
        }
        XCTAssertEqual(response.output.amount, 3.5, accuracy: 0.000001)
    }

    // MARK: - Failure handling and cleanup

    func testTransportErrorSurfacesErrorAndReleasesInFlight() throws {
        let client = BalanceAPIClient(session: session)
        StubURLProtocol.setHandler { _ in
            StubResult(error: URLError(.timedOut))
        }

        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
        let result = try waitForResult(client, query: makeQuery())
        guard case .failure(.transport(let error)) = result else {
            return XCTFail("expected transport failure, got \(result)")
        }
        let nsError = error as NSError
        XCTAssertEqual(nsError.domain, NSURLErrorDomain)
        XCTAssertEqual(nsError.code, URLError.timedOut.rawValue)
        XCTAssertFalse(
            client.isRequestInFlight(client: .codex, providerID: "provider-1"),
            "transport failure must release in-flight state"
        )

        // Same key can start again immediately.
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 200, data: self.balanceBody("1.25", unit: "USD"))
        }
        let retry = try waitForResult(client, query: makeQuery())
        guard case .success(let response) = retry else {
            return XCTFail("expected success after transport failure, got \(retry)")
        }
        XCTAssertEqual(response.output.amount, 1.25, accuracy: 0.000001)
    }

    func testHTTPErrorSurfacesStatusAndReleasesInFlight() throws {
        let client = BalanceAPIClient(session: session)
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 503, data: Data(#"{"error":"unavailable"}"#.utf8))
        }

        let result = try waitForResult(client, query: makeQuery())
        guard case .failure(.httpStatus(503)) = result else {
            return XCTFail("expected httpStatus 503, got \(result)")
        }
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
    }

    func testInvalidJSONSurfacesErrorAndReleasesInFlight() throws {
        let client = BalanceAPIClient(session: session)
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 200, data: Data("{not-json".utf8))
        }

        let result = try waitForResult(client, query: makeQuery())
        guard case .failure(.invalidJSON(let dataSize, _)) = result else {
            return XCTFail("expected invalidJSON, got \(result)")
        }
        XCTAssertEqual(dataSize, "{not-json".utf8.count)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
    }

    func testUnsupportedFormatSurfacesErrorAndReleasesInFlight() throws {
        let client = BalanceAPIClient(session: session)
        StubURLProtocol.setHandler { _ in
            StubResult(
                statusCode: 200,
                data: Data(#"{"data":{"unexpected":true}}"#.utf8)
            )
        }

        let result = try waitForResult(client, query: makeQuery())
        guard case .failure(.unsupportedFormat(let dataSize)) = result else {
            return XCTFail("expected unsupportedFormat, got \(result)")
        }
        XCTAssertEqual(dataSize, #"{"data":{"unexpected":true}}"#.utf8.count)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
    }

    func testSuccessReleasesInFlightAndReusesBalanceResponseParser() throws {
        let client = BalanceAPIClient(session: session)
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 200, data: self.balanceBody("17", unit: "USD"))
        }

        let result = try waitForResult(client, query: makeQuery())
        guard case .success(let response) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(response.output.amount, 17, accuracy: 0.000001)
        XCTAssertEqual(response.output.unit, "USD")
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
    }

    // MARK: - Concurrent deduplication and consumer fan-out

    func testPrefetchFirstThenMainRefreshReceivesSharedResponseAndKeyCanBeReused() throws {
        let client = BalanceAPIClient(session: session)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let requestCounter = AtomicCounter()
        StubURLProtocol.setHandler { _ in
            if requestCounter.increment() == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
            return StubResult(statusCode: 200, data: self.balanceBody("9.75", unit: "CNY"))
        }

        let prefetchCompletion = expectation(description: "quick-switch prefetch completed")
        let mainRefreshCompletion = expectation(description: "main refresh completed")
        var prefetchResult: Result<BalanceAPIResult, BalanceAPIClientError>?
        var mainRefreshResult: Result<BalanceAPIResult, BalanceAPIClientError>?
        let prefetchStarted = client.fetchBalance(
            query: makeQuery(),
            client: .codex,
            providerID: "provider-1"
        ) { result in
            prefetchResult = result
            prefetchCompletion.fulfill()
        }
        XCTAssertTrue(prefetchStarted)
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(client.isRequestInFlight(client: .codex, providerID: "provider-1"))

        // The main refresh joins the prefetch transport and retains its own
        // callback, so both UI consumers observe the shared response.
        let mainRefreshStarted = client.fetchBalance(
            query: makeQuery(),
            client: .codex,
            providerID: "provider-1"
        ) { result in
            mainRefreshResult = result
            mainRefreshCompletion.fulfill()
        }
        XCTAssertFalse(mainRefreshStarted, "same-key main refresh must reuse the prefetch transport")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        // Release the first request; it completes and releases its key.
        releaseFirst.signal()
        wait(for: [prefetchCompletion, mainRefreshCompletion], timeout: 2)
        guard case .success(let prefetchResponse)? = prefetchResult else {
            return XCTFail("expected prefetch success, got \(String(describing: prefetchResult))")
        }
        guard case .success(let mainResponse)? = mainRefreshResult else {
            return XCTFail("expected main refresh success, got \(String(describing: mainRefreshResult))")
        }
        XCTAssertEqual(prefetchResponse.output.amount, 9.75, accuracy: 0.000001)
        XCTAssertEqual(mainResponse.output.amount, 9.75, accuracy: 0.000001)
        XCTAssertEqual(prefetchResponse.output.unit, "CNY")
        XCTAssertEqual(mainResponse.output.unit, "CNY")
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))

        // A different provider key starts its own transport request.
        let otherCompletion = expectation(description: "other provider completed")
        let otherStarted = client.fetchBalance(
            query: makeQuery(),
            client: .codex,
            providerID: "provider-2"
        ) { _ in
            otherCompletion.fulfill()
        }
        XCTAssertTrue(otherStarted, "different provider key must not be deduplicated")
        wait(for: [otherCompletion], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)

        // A different client with the same provider ID starts its own request.
        let claudeCompletion = expectation(description: "claude client completed")
        let claudeStarted = client.fetchBalance(
            query: makeQuery(),
            client: .claude,
            providerID: "provider-1"
        ) { _ in
            claudeCompletion.fulfill()
        }
        XCTAssertTrue(claudeStarted, "different client must not be deduplicated")
        wait(for: [claudeCompletion], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 3)

        // Same key starts again after release.
        let thirdCompletion = expectation(description: "third request completed")
        let thirdStarted = client.fetchBalance(
            query: makeQuery(),
            client: .codex,
            providerID: "provider-1"
        ) { _ in
            thirdCompletion.fulfill()
        }
        XCTAssertTrue(thirdStarted, "key must be reusable after completion")
        wait(for: [thirdCompletion], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 4)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "provider-1"))
    }

    func testClientCanBeReleasedBeforeResponseAndRequestStillFinishesAndCleansUp() throws {
        let requestStarted = expectation(description: "request reached transport")
        let requestFinished = expectation(description: "request completed after client release")
        let releaseResponse = DispatchSemaphore(value: 0)
        StubURLProtocol.setHandler { _ in
            requestStarted.fulfill()
            releaseResponse.wait()
            return StubResult(statusCode: 200, data: self.balanceBody("6.5", unit: "USD"))
        }

        var client: BalanceAPIClient? = BalanceAPIClient(session: session)
        weak var weakClient = client
        var captured: Result<BalanceAPIResult, BalanceAPIClientError>?
        let started = client!.fetchBalance(
            query: makeQuery(),
            client: .codex,
            providerID: "provider-lifecycle"
        ) { result in
            captured = result
            requestFinished.fulfill()
        }
        XCTAssertTrue(started)
        wait(for: [requestStarted], timeout: 2)

        // The URLSession completion must retain cleanup state, not the client
        // instance, so releasing the client cannot drop the result or key cleanup.
        client = nil
        XCTAssertNil(weakClient)
        releaseResponse.signal()

        wait(for: [requestFinished], timeout: 2)
        guard case .success(let response)? = captured else {
            return XCTFail("expected success after client release, got \(String(describing: captured))")
        }
        XCTAssertEqual(response.output.amount, 6.5, accuracy: 0.000001)
        XCTAssertEqual(response.output.unit, "USD")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    private final class AtomicCounter {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
