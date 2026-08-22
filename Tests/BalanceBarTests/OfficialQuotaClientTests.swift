import Foundation
import XCTest
@testable import BalanceBar

final class OfficialQuotaClientTests: XCTestCase {
    private struct StubResult {
        let statusCode: Int
        let data: Data?
        let error: Error?
        let holdsResponse: Bool

        init(
            statusCode: Int = 200,
            data: Data? = nil,
            error: Error? = nil,
            holdsResponse: Bool = false
        ) {
            self.statusCode = statusCode
            self.data = data
            self.error = error
            self.holdsResponse = holdsResponse
        }
    }

    /// Offline URLProtocol stub. No request can leave this test target.
    private final class StubURLProtocol: URLProtocol {
        private struct HeldResponse {
            let loader: StubURLProtocol
            let request: URLRequest
            let result: StubResult
        }

        private static let stateLock = NSLock()
        private static var requestHandler: ((URLRequest) -> StubResult)?
        private static var recordedRequests: [URLRequest] = []
        private static var heldResponses: [HeldResponse] = []

        static func reset() {
            stateLock.lock()
            requestHandler = nil
            recordedRequests = []
            heldResponses = []
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

        static func releaseHeldResponses() {
            stateLock.lock()
            let held = heldResponses
            heldResponses = []
            stateLock.unlock()
            held.forEach { $0.loader.deliver($0.result, for: $0.request) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let request = Self.record(request)
            Self.stateLock.lock()
            let handler = Self.requestHandler
            Self.stateLock.unlock()
            let result = handler?(request) ?? StubResult(data: Data("{}".utf8))
            if result.holdsResponse {
                Self.stateLock.lock()
                Self.heldResponses.append(
                    HeldResponse(loader: self, request: request, result: result)
                )
                Self.stateLock.unlock()
                return
            }
            deliver(result, for: request)
        }

        private func deliver(_ result: StubResult, for request: URLRequest) {
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

    private struct FixtureCredentialReader: OfficialQuotaCredentialReading {
        let codexToken: String?
        let codexAccountIDValue: String?
        let claudeToken: String?

        init(
            codexToken: String?,
            codexAccountID: String? = nil,
            claudeToken: String?
        ) {
            self.codexToken = codexToken
            self.codexAccountIDValue = codexAccountID
            self.claudeToken = claudeToken
        }

        func codexAccessToken() -> String? { codexToken }
        func codexAccountID() -> String? { codexAccountIDValue }
        func claudeAccessToken() -> String? { claudeToken }
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

    func testCodexRequestUsesOfficialEndpointAndHeaders() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.codexBody)
        }
        let client = makeClient(codexToken: "fixture-codex-value")

        let result = try waitForResult(client, clientName: .codex, providerID: "codex-provider")

        guard case .success(let response) = result else {
            return XCTFail("expected Codex success, got \(result)")
        }
        XCTAssertEqual(response.output.remaining, 45, accuracy: 0.000001)
        XCTAssertEqual(response.output.daysText, tr("7 天", "7 Days", "7 天", "7日間"))
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-codex-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testClaudeRequestUsesOfficialEndpointHeadersAndParser() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.claudeBody)
        }
        let client = makeClient(claudeToken: "fixture-claude-value")

        let result = try waitForResult(client, clientName: .claude, providerID: "claude-provider")

        guard case .success(let response) = result else {
            return XCTFail("expected Claude success, got \(result)")
        }
        XCTAssertEqual(response.output.remaining, 87.5, accuracy: 0.000001)
        XCTAssertEqual(response.output.daysText, tr("7 天", "7 Days", "7 天", "7日間"))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/api/oauth/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-claude-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testCodexStoredAccessTokenOverridesInjectedReader() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.codexBody)
        }
        let client = makeClient(codexToken: "fixture-reader-value")

        _ = try waitForResult(
            client,
            clientName: .codex,
            providerID: "stored-token-provider",
            storedAccessToken: "fixture-stored-value"
        )

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-stored-value"
        )
    }

    func testCodexAccountIDUsesTheOfficialCredentialReaderSource() {
        let client = makeClient(codexAccountID: "account-from-auth")

        XCTAssertEqual(client.codexAccountID(), "account-from-auth")
    }

    func testOverlappingCredentialSourcesDoNotShareTransport() throws {
        let requestsStarted = expectation(description: "both credential-source requests reached URLProtocol")
        requestsStarted.expectedFulfillmentCount = 2
        let observedLock = NSLock()
        var observedAuthorizationHeaders: [String] = []
        let localBody = Data(#"{"rate_limit":{"secondary_window":{"used_percent":"10","limit_window_seconds":604800,"reset_after_seconds":5400}}}"#.utf8)
        let storedBody = Data(#"{"rate_limit":{"secondary_window":{"used_percent":"70","limit_window_seconds":604800,"reset_after_seconds":5400}}}"#.utf8)

        StubURLProtocol.setHandler { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
            observedLock.lock()
            observedAuthorizationHeaders.append(authorization)
            observedLock.unlock()
            requestsStarted.fulfill()
            switch authorization {
            case "Bearer fixture-local-source":
                return StubResult(data: localBody, holdsResponse: true)
            case "Bearer fixture-stored-source":
                return StubResult(data: storedBody, holdsResponse: true)
            default:
                return StubResult(statusCode: 500, data: Data(#"{"error":"unexpected fixture"}"#.utf8))
            }
        }

        let client = makeClient(codexToken: "fixture-local-source")
        let localCompletion = expectation(description: "local credential source completed")
        let storedCompletion = expectation(description: "stored credential source completed")
        var localResult: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        var storedResult: Result<OfficialQuotaResult, OfficialQuotaClientError>?

        let localStarted = client.fetchQuota(
            client: .codex,
            providerID: "overlapping-provider",
            storedAccessToken: nil
        ) { result in
            localResult = result
            localCompletion.fulfill()
        }
        let storedStarted = client.fetchQuota(
            client: .codex,
            providerID: "overlapping-provider",
            storedAccessToken: "fixture-stored-source"
        ) { result in
            storedResult = result
            storedCompletion.fulfill()
        }

        XCTAssertTrue(localStarted)
        XCTAssertTrue(storedStarted)
        wait(for: [requestsStarted], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        StubURLProtocol.releaseHeldResponses()
        wait(for: [localCompletion, storedCompletion], timeout: 2)

        guard case .success(let localResponse) = localResult else {
            return XCTFail("expected local credential source success, got \(String(describing: localResult))")
        }
        guard case .success(let storedResponse) = storedResult else {
            return XCTFail("expected stored credential source success, got \(String(describing: storedResult))")
        }
        XCTAssertEqual(localResponse.output.remaining, 90, accuracy: 0.000001)
        XCTAssertEqual(storedResponse.output.remaining, 30, accuracy: 0.000001)

        observedLock.lock()
        let authorizationHeaders = observedAuthorizationHeaders
        observedLock.unlock()
        XCTAssertEqual(
            Set(authorizationHeaders),
            Set(["Bearer fixture-local-source", "Bearer fixture-stored-source"])
        )

        let localKey = OfficialQuotaClient.requestKey(
            client: .codex,
            providerID: "overlapping-provider",
            credentialSource: .localReader
        )
        let storedKey = OfficialQuotaClient.requestKey(
            client: .codex,
            providerID: "overlapping-provider",
            credentialSource: .storedAccessToken
        )
        XCTAssertNotEqual(localKey, storedKey)
        XCTAssertFalse(localKey.contains("fixture-local-source"))
        XCTAssertFalse(storedKey.contains("fixture-stored-source"))
        XCTAssertFalse(client.isRequestInFlight(
            client: .codex,
            providerID: "overlapping-provider",
            credentialSource: .localReader
        ))
        XCTAssertFalse(client.isRequestInFlight(
            client: .codex,
            providerID: "overlapping-provider",
            credentialSource: .storedAccessToken
        ))
    }

    func testMissingCredentialsCompletesWithoutStartingTransport() throws {
        let client = makeClient()
        for clientName in [AssistantClient.codex, .claude] {
            let providerID = "missing-\(clientName.rawValue)-provider"
            let result = try waitForResult(client, clientName: clientName, providerID: providerID)

            guard case .failure(.missingCredentials) = result else {
                return XCTFail("expected missing credentials, got \(result)")
            }
            XCTAssertFalse(client.isRequestInFlight(client: clientName, providerID: providerID))
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testHTTP401403And500PreserveStatusAndCleanup() throws {
        let client = makeClient(codexToken: "fixture-codex-value")
        for statusCode in [401, 403, 500] {
            StubURLProtocol.setHandler { _ in
                StubResult(statusCode: statusCode, data: Data(#"{"error":"fixture"}"#.utf8))
            }

            let result = try waitForResult(
                client,
                clientName: .codex,
                providerID: "status-\(statusCode)"
            )
            guard case .failure(.httpStatus(let actualStatus, let dataSize)) = result else {
                return XCTFail("expected HTTP status \(statusCode), got \(result)")
            }
            XCTAssertEqual(actualStatus, statusCode)
            XCTAssertGreaterThan(dataSize, 0)
            XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "status-\(statusCode)"))
        }
    }

    func testInvalidJSONIsClassifiedWithoutLeakingResponseContent() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Data("{invalid".utf8))
        }
        let client = makeClient(codexToken: "fixture-codex-value")

        let result = try waitForResult(client, clientName: .codex, providerID: "invalid-json")

        guard case .failure(.invalidJSON(let dataSize)) = result else {
            return XCTFail("expected invalid JSON, got \(result)")
        }
        XCTAssertEqual(dataSize, "{invalid".utf8.count)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "invalid-json"))

        StubURLProtocol.setHandler { _ in
            StubResult(data: Data("[1,2]".utf8))
        }
        let nonObject = try waitForResult(client, clientName: .codex, providerID: "non-object-json")
        guard case .failure(.invalidJSON(let nonObjectSize)) = nonObject else {
            return XCTFail("expected non-object JSON to use the endpoint error path, got \(nonObject)")
        }
        XCTAssertEqual(nonObjectSize, "[1,2]".utf8.count)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "non-object-json"))
    }

    func testCancellationCompletesAndReleasesInFlightState() throws {
        let requestStarted = expectation(description: "request reached URLProtocol")
        StubURLProtocol.setHandler { _ in
            requestStarted.fulfill()
            return StubResult(holdsResponse: true)
        }
        let client = makeClient(codexToken: "fixture-codex-value")
        let completion = expectation(description: "cancellation completed")
        var captured: Result<OfficialQuotaResult, OfficialQuotaClientError>?

        let started = client.fetchQuota(
            client: .codex,
            providerID: "cancelled-provider"
        ) { result in
            captured = result
            completion.fulfill()
        }
        XCTAssertTrue(started)
        wait(for: [requestStarted], timeout: 2)
        XCTAssertTrue(client.isRequestInFlight(client: .codex, providerID: "cancelled-provider"))

        client.cancelQuota(client: .codex, providerID: "cancelled-provider")
        wait(for: [completion], timeout: 2)

        guard case .failure(.transport(.urlError(let code))) = captured else {
            return XCTFail("expected cancellation transport error, got \(String(describing: captured))")
        }
        XCTAssertEqual(code, .cancelled)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "cancelled-provider"))
    }

    func testClientReleaseDoesNotDropCompletionOrCleanup() throws {
        let requestStarted = expectation(description: "request reached URLProtocol")
        let releaseResponse = DispatchSemaphore(value: 0)
        StubURLProtocol.setHandler { _ in
            requestStarted.fulfill()
            releaseResponse.wait()
            return StubResult(data: Self.codexBody)
        }

        var client: OfficialQuotaClient? = makeClient(codexToken: "fixture-codex-value")
        weak var weakClient = client
        let completion = expectation(description: "request completed after client release")
        var captured: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        let started = client!.fetchQuota(
            client: .codex,
            providerID: "released-provider"
        ) { result in
            captured = result
            completion.fulfill()
        }
        XCTAssertTrue(started)
        wait(for: [requestStarted], timeout: 2)

        client = nil
        XCTAssertNil(weakClient)
        releaseResponse.signal()
        wait(for: [completion], timeout: 2)

        guard case .success(let response)? = captured else {
            return XCTFail("expected success after client release, got \(String(describing: captured))")
        }
        XCTAssertEqual(response.output.remaining, 45, accuracy: 0.000001)
    }

    func testCompletedRequestCanReuseSameKeyAfterCleanup() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.codexBody)
        }
        let client = makeClient(codexToken: "fixture-codex-value")

        _ = try waitForResult(client, clientName: .codex, providerID: "reusable-provider")
        let second = try waitForResult(client, clientName: .codex, providerID: "reusable-provider")

        guard case .success = second else {
            return XCTFail("expected a second request after cleanup, got \(second)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertFalse(client.isRequestInFlight(client: .codex, providerID: "reusable-provider"))
    }

    private func makeClient(
        codexToken: String? = nil,
        claudeToken: String? = nil,
        codexAccountID: String? = nil
    ) -> OfficialQuotaClient {
        OfficialQuotaClient(
            session: session,
            credentialReader: FixtureCredentialReader(
                codexToken: codexToken,
                codexAccountID: codexAccountID,
                claudeToken: claudeToken
            ),
            parser: DefaultOfficialQuotaParser {
                Date(timeIntervalSince1970: 1_700_000_000)
            }
        )
    }

    private func waitForResult(
        _ client: OfficialQuotaClient,
        clientName: AssistantClient,
        providerID: String,
        storedAccessToken: String? = nil
    ) throws -> Result<OfficialQuotaResult, OfficialQuotaClientError> {
        let expectation = expectation(description: "official quota request completed")
        var captured: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        let started = client.fetchQuota(
            client: clientName,
            providerID: providerID,
            storedAccessToken: storedAccessToken
        ) { result in
            captured = result
            expectation.fulfill()
        }
        XCTAssertTrue(started)
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(captured)
    }

    private static let codexBody = Data(#"{"rate_limit":{"primary_window":{"used_percent":"20","limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400}}}"#.utf8)

    private static let claudeBody = Data(#"{"seven_day":{"utilization":"12.5","resets_at":"2023-11-15T00:13:20Z"}}"#.utf8)
}
