import Foundation
import XCTest
@testable import BalanceBar

final class OfficialQuotaClientTests: XCTestCase {
    private struct StubResult {
        let statusCode: Int
        let data: Data?
        let error: Error?
        let holdsResponse: Bool
        let headers: [String: String]

        init(
            statusCode: Int = 200,
            data: Data? = nil,
            error: Error? = nil,
            holdsResponse: Bool = false,
            headers: [String: String] = [:]
        ) {
            self.statusCode = statusCode
            self.data = data
            self.error = error
            self.holdsResponse = holdsResponse
            self.headers = headers
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
        static var onStop: ((URLRequest) -> Void)?

        static func reset() {
            stateLock.lock()
            requestHandler = nil
            recordedRequests = []
            heldResponses = []
            onStop = nil
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
                headerFields: ["Content-Type": "application/json"].merging(result.headers) { _, new in new }
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() { Self.onStop?(request) }

        private static func record(_ request: URLRequest) -> URLRequest {
            stateLock.lock()
            recordedRequests.append(request)
            stateLock.unlock()
            return request
        }
    }

    private struct FixtureCredentialReader: OfficialQuotaCredentialReading {
        let codexToken: String?
        let codexAccountProfileValue: CodexAccountProfile?
        let claudeToken: String?

        init(
            codexToken: String?,
            codexAccountProfile: CodexAccountProfile? = nil,
            claudeToken: String?
        ) {
            self.codexToken = codexToken
            self.codexAccountProfileValue = codexAccountProfile
            self.claudeToken = claudeToken
        }

        func codexAccessToken() -> String? { codexToken }
        func codexAccountProfile() -> CodexAccountProfile? { codexAccountProfileValue }
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
        XCTAssertEqual(response.output.daysText, tr(.keyResponseParsers7Days))
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

    func testClaudeProxyConfigurationBuildsHTTPSAndSOCKSSessions() throws {
        let httpsSession = OfficialQuotaClient.makeClaudeSession(
            proxyConfiguration: CCSwitchProxyConfiguration(
                httpsProxy: URL(string: "http://proxy.example:8443"),
                allProxy: URL(string: "socks5://fallback.example:1080")
            )
        )
        let httpsProxy = try XCTUnwrap(httpsSession.configuration.connectionProxyDictionary)
        XCTAssertEqual(httpsProxy["HTTPSEnable"] as? Bool, true)
        XCTAssertEqual(httpsProxy["HTTPSProxy"] as? String, "proxy.example")
        XCTAssertEqual(httpsProxy["HTTPSPort"] as? Int, 8443)
        XCTAssertNil(httpsProxy["SOCKSEnable"])
        httpsSession.invalidateAndCancel()

        let socksSession = OfficialQuotaClient.makeClaudeSession(
            proxyConfiguration: CCSwitchProxyConfiguration(allProxy: URL(string: "socks5://fallback.example:1080"))
        )
        let socksProxy = try XCTUnwrap(socksSession.configuration.connectionProxyDictionary)
        XCTAssertEqual(socksProxy["SOCKSEnable"] as? Bool, true)
        XCTAssertEqual(socksProxy["SOCKSProxy"] as? String, "fallback.example")
        XCTAssertEqual(socksProxy["SOCKSPort"] as? Int, 1080)
        XCTAssertNil(socksProxy["HTTPSEnable"])
        socksSession.invalidateAndCancel()

        let directSession = OfficialQuotaClient.makeClaudeSession(
            proxyConfiguration: CCSwitchProxyConfiguration()
        )
        XCTAssertNil(directSession.configuration.connectionProxyDictionary)
        directSession.invalidateAndCancel()
    }

    func testClaudeConnectionFailureIsClassifiedAsPossibleProxy() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(error: URLError(.cannotConnectToHost))
        }
        let client = makeClient(claudeToken: "fixture-claude-value")
        let result = try waitForResult(client, clientName: .claude, providerID: "proxy-failure")

        guard case .failure(.transport(.possibleProxy(.cannotConnectToHost))) = result else {
            return XCTFail("expected a possible-proxy transport classification, got (result)")
        }
    }

    func testCodexUsageRequestDoesNotFetchBankedResetCreditsWhenUsageIncludesCards() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.codexBankedResetBody)
        }
        let client = makeClient(codexToken: "fixture-codex-value")

        let result = try waitForResult(client, clientName: .codex, providerID: "codex-banked-reset")
        guard case .success(let response) = result else {
            return XCTFail("expected Codex success, got \(result)")
        }
        XCTAssertEqual(response.output.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(response.output.bankedReset?.availableCount, 2)
        XCTAssertFalse(response.output.bankedResetNeedsCreditList)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-codex-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        XCTAssertFalse((request.url?.path ?? "").contains("consume"))
    }

    func testCodexRateLimitResetCreditsListUsesReadOnlyGet() throws {
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse((request.url?.absoluteString ?? "").contains("consume"))
            return StubResult(data: Self.codexBankedResetListBody)
        }
        let client = makeClient(codexToken: "fixture-codex-value")
        let expectation = expectation(description: "reset-credits list completed")
        var captured: Result<CodexBankedReset?, OfficialQuotaClientError>?
        client.fetchRateLimitResetCredits(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ) { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        guard case .success(let bankedReset) = captured else {
            return XCTFail("expected list success, got \(String(describing: captured))")
        }
        XCTAssertEqual(bankedReset?.availableCount, 1)
        XCTAssertEqual(bankedReset?.cards.first?.resetType, "codex_rate_limits")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-codex-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    func testCodexResetForecastParsesScoreWithoutCredentials() throws {
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, CodexResetForecastParser.forecastURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return StubResult(data: ResponseParsersTests.codexResetIssueJSON)
        }
        let client = makeClient(codexToken: nil, claudeToken: nil)
        let expectation = expectation(description: "forecast completed")
        var captured: CodexResetForecast?
        client.fetchCodexResetForecast { forecast in
            captured = forecast
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(captured?.probability24h, .percent(24))
        XCTAssertEqual(captured?.probability48h, .percent(42))
        XCTAssertEqual(captured?.confidence, .low)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "codex-reset.com")
        XCTAssertEqual(request.url?.path, "/api/forecast")
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testCodexResetForecastFailureIsUnavailable() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(statusCode: 500, data: Data("{}".utf8))
        }
        let client = makeClient(codexToken: nil, claudeToken: nil)
        let expectation = expectation(description: "forecast failed")
        var captured: CodexResetForecast?
        client.fetchCodexResetForecast { forecast in
            captured = forecast
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(captured, .unavailable)
        XCTAssertEqual(captured?.probability24h.displayText, "--%")
        XCTAssertEqual(captured?.confidence.displayText(), "--")
    }

    func testCodexRequestPublishesTheOfficialLunaReserveFields() throws {
        StubURLProtocol.setHandler { _ in
            StubResult(data: Self.codexReserveBody)
        }
        let client = makeClient(codexToken: "fixture-codex-value")

        let result = try waitForResult(client, clientName: .codex, providerID: "codex-reserve-provider")

        guard case .success(let response) = result else {
            return XCTFail("expected Codex success, got (result)")
        }
        let reserve = try XCTUnwrap(response.output.lunaReserve)
        XCTAssertEqual(reserve.status, .available)
        XCTAssertEqual(reserve.remaining ?? -1, 62, accuracy: 0.000001)
        XCTAssertEqual(reserve.reset, "2h0m")
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
        XCTAssertEqual(response.output.daysText, tr(.keyResponseParsers7Days))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/api/oauth/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-claude-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testClaudeSuccessCacheSharesSequentialConsumersAndManualRefreshHonorsTTL() throws {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        let client = makeClient(claudeToken: "fixture", now: { time })
        StubURLProtocol.setHandler { _ in StubResult(data: Self.claudeBody) }
        let first = try waitForResult(client, clientName: .claude, providerID: "standard")
        let cached = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        guard case .success(let original) = first, case .success(let reused) = cached else { return XCTFail("expected cached success") }
        XCTAssertEqual(original.fetchedAt, reused.fetchedAt, "cached data must keep its actual fetch time")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard", expectsTransport: false)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        time.addTimeInterval(59)
        _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        time.addTimeInterval(1)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testClaudeRateLimitBackoffHonorsRetryAfterEvenForManualRefresh() throws {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        let client = makeClient(claudeToken: "fixture", now: { time })
        StubURLProtocol.setHandler { _ in StubResult(statusCode: 429, data: Data(), headers: ["Retry-After": "170"]) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(169)
        let throttled = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        guard case .failure(.httpStatus(let status, _)) = throttled else { return XCTFail("expected rate-limit error") }
        XCTAssertEqual(status, 429)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        time.addTimeInterval(1)
        StubURLProtocol.setHandler { _ in StubResult(data: Self.claudeBody) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testClaudeRateLimitAcceptsHTTPDateAndUsesSafeFallback() throws {
        for header in ["Tue, 14 Nov 2023 22:16:10 GMT", "invalid", "-5"] {
            var time = Date(timeIntervalSince1970: 1_700_000_000)
            let client = makeClient(claudeToken: "fixture", now: { time })
            StubURLProtocol.setHandler { _ in StubResult(statusCode: 429, data: Data(), headers: ["Retry-After": header]) }
            _ = try waitForResult(client, clientName: .claude, providerID: "standard")
            time.addTimeInterval(header.hasSuffix("GMT") ? 169 : 59)
            _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
            time.addTimeInterval(1)
            _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 6)
    }

    func testClaudeCalibrationUsesSelectedIntervalAndAppliesChangesToCachedResults() throws {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        var interval: TimeInterval = 180
        let client = makeClient(claudeToken: "fixture", now: { time })
        client.configureClaudeCalibrationInterval { interval }
        StubURLProtocol.setHandler { _ in StubResult(data: Self.claudeBody) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(60)
        _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        interval = 90
        time.addTimeInterval(30)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testClaudeFailuresAlsoWaitOneMinuteBeforeRetrying() throws {
        for reply in [StubResult(statusCode: 503, data: Data()), StubResult(error: URLError(.timedOut)),
                      StubResult(data: Data("bad-json".utf8))] {
            var time = Date(timeIntervalSince1970: 1_700_000_000)
            let client = makeClient(claudeToken: "fixture", now: { time })
            StubURLProtocol.setHandler { _ in reply }
            _ = try waitForResult(client, clientName: .claude, providerID: "standard")
            time.addTimeInterval(59)
            _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
            time.addTimeInterval(1)
            _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 6)
    }

    func testClaudeRepeatedRateLimitsWithoutRetryAfterBackOffAndResetAfterSuccess() throws {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        let client = makeClient(claudeToken: "fixture", now: { time })
        StubURLProtocol.setHandler { _ in StubResult(statusCode: 429, data: Data()) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(60)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(60)
        _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        time.addTimeInterval(60)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(239)
        _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        time.addTimeInterval(1)
        StubURLProtocol.setHandler { _ in StubResult(data: Self.claudeBody) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(60)
        StubURLProtocol.setHandler { _ in StubResult(statusCode: 429, data: Data()) }
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        time.addTimeInterval(60)
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        XCTAssertEqual(StubURLProtocol.requestCount, 6, "successful calibration resets the failure backoff")
    }

    func testClaudeCacheDoesNotReusePreviousAccountTokenOrApplyToCodex() throws {
        final class Reader: OfficialQuotaCredentialReading {
            var token = "account-a"
            func claudeAccessToken() -> String? { token }
            func codexAccessToken() -> String? { "codex" }
            func codexAccountProfile() -> CodexAccountProfile? { nil }
        }
        let reader = Reader()
        let client = OfficialQuotaClient(session: session, credentialReader: reader)
        StubURLProtocol.setHandler { request in
            StubResult(data: request.url?.host == "api.anthropic.com" ? Self.claudeBody : Self.codexBody)
        }
        _ = try waitForResult(client, clientName: .claude, providerID: "official")
        reader.token = "account-b"
        _ = try waitForResult(client, clientName: .claude, providerID: "official")
        _ = try waitForResult(client, clientName: .codex, providerID: "official")
        _ = try waitForResult(client, clientName: .codex, providerID: "official")
        XCTAssertEqual(StubURLProtocol.requestCount, 4)
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

    func testCodexAccountProfileUsesTheOfficialCredentialReaderSource() {
        let client = makeClient(
            codexAccountProfile: CodexAccountProfile(email: "person@example.com", planType: "prolite")
        )

        XCTAssertEqual(
            client.codexAccountProfile(),
            CodexAccountProfile(email: "person@example.com", planType: "prolite")
        )
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

    func testConcurrentStoredTokensUseSeparateScopesButSameTokenSharesTransport() throws {
        let started = expectation(description: "two token transports")
        started.expectedFulfillmentCount = 2
        StubURLProtocol.setHandler { request in
            started.fulfill()
            let used = request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-A" ? 20 : 70
            return StubResult(data: Data("{\"rate_limit\":{\"secondary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":604800,\"reset_after_seconds\":5400}}}".utf8), holdsResponse: true)
        }
        let client = makeClient()
        let completed = expectation(description: "three consumers")
        completed.expectedFulfillmentCount = 3
        for (token, expected) in [("stored-A", 80.0), ("stored-A", 80.0), ("stored-B", 30.0)] {
            client.fetchQuota(client: .codex, providerID: "same-provider", storedAccessToken: token) { result in
                if case .success(let response) = result { XCTAssertEqual(response.output.remaining, expected) }
                else { XCTFail("expected successful stored-token response") }
                completed.fulfill()
            }
        }
        wait(for: [started], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertTrue(client.isRequestInFlight(client: .codex, providerID: "same-provider", credentialSource: .storedAccessToken, storedAccessToken: "stored-A"))
        XCTAssertTrue(client.isRequestInFlight(client: .codex, providerID: "same-provider", credentialSource: .storedAccessToken, storedAccessToken: "stored-B"))
        StubURLProtocol.releaseHeldResponses()
        wait(for: [completed], timeout: 2)
    }

    func testMissingCredentialsCompletesWithoutStartingTransport() throws {
        let client = makeClient()
        for clientName in [AssistantClient.codex, .claude, .grok] {
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
        codexAccountProfile: CodexAccountProfile? = nil,
        now: @escaping () -> Date = Date.init
    ) -> OfficialQuotaClient {
        OfficialQuotaClient(
            session: session,
            credentialReader: FixtureCredentialReader(
                codexToken: codexToken,
                codexAccountProfile: codexAccountProfile,
                claudeToken: claudeToken
            ),
            parser: DefaultOfficialQuotaParser {
                Date(timeIntervalSince1970: 1_700_000_000)
            },
            now: now
        )
    }

    private func waitForResult(
        _ client: OfficialQuotaClient,
        clientName: AssistantClient,
        providerID: String,
        storedAccessToken: String? = nil,
        expectsTransport: Bool = true
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
        XCTAssertEqual(started, expectsTransport)
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(captured)
    }

    private static let codexBody = Data(#"{"rate_limit":{"primary_window":{"used_percent":"20","limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400}}}"#.utf8)

    private static let codexBankedResetBody = Data(#"{"rate_limit":{"primary_window":{"used_percent":"20","limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400}},"rate_limit_reset_credits":{"available_count":2,"credits":[{"id":"RateLimitResetCredit_a","reset_type":"codex_rate_limits","status":"available","expires_at":"2023-11-15T22:13:20Z"},{"id":"RateLimitResetCredit_b","reset_type":"codex_rate_limits","status":"available","expires_at":"2023-11-16T22:13:20Z"}]}}"#.utf8)

    private static let codexBankedResetListBody = Data(#"{"available_count":1,"credits":[{"id":"RateLimitResetCredit_list","reset_type":"codex_rate_limits","status":"available","expires_at":"2023-11-15T22:13:20Z","title":"One free rate limit reset"}]}"#.utf8)

    private static let codexReserveBody = Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400}},"additional_rate_limits":[{"limit_name":"gpt-reserve","metered_feature":"base_model_inference","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":38,"limit_window_seconds":604800,"reset_after_seconds":7200}}}]}"#.utf8)

    private static let claudeBody = Data(#"{"seven_day":{"utilization":"12.5","resets_at":"2023-11-15T00:13:20Z"}}"#.utf8)
}

extension OfficialQuotaClientTests {
    func testCancelledStoredRequestLateCompletionCannotFinishNewRequestWithSameKey() throws {
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 2
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: callbacks)
        let parser = PausedQuotaReworkParser()
        defer { parser.firstGate.signal(); parser.secondGate.signal() }
        StubURLProtocol.setHandler { _ in StubResult(data: Data("{}".utf8)) }
        let client = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: nil, claudeToken: nil), parser: parser)
        let context = OfficialQuotaRequestContext(client: .codex, providerID: "same-provider",
            storedAccessToken: "fixture-stored", credentials: CodexRequestCredentials(accessToken: "fixture-stored", accountKey: nil))
        let cancelled = expectation(description: "first completion cancelled")
        client.fetchQuota(context: context) { result in
            guard case .failure(.transport(.urlError(.cancelled))) = result else { return XCTFail("expected cancellation") }
            cancelled.fulfill()
        }
        XCTAssertEqual(parser.firstStarted.wait(timeout: .now() + 2), .success)
        client.cancelQuota(context: context)
        wait(for: [cancelled], timeout: 2)
        let unexpected = expectation(description: "old completion must not consume new registry entry")
        unexpected.isInverted = true
        let finished = expectation(description: "new request finishes on its own response")
        client.fetchQuota(context: context) { result in
            if !parser.secondReleased { unexpected.fulfill(); return }
            guard case .success = result else { return XCTFail("new request lost") }
            finished.fulfill()
        }
        XCTAssertEqual(parser.secondStarted.wait(timeout: .now() + 2), .success)
        parser.firstGate.signal()
        wait(for: [unexpected], timeout: 0.2)
        XCTAssertTrue(client.isRequestInFlight(client: .codex, providerID: context.providerID,
            credentialSource: context.credentialSource, requestCredentials: context.credentials, storedAccessToken: context.storedAccessToken))
        parser.releaseSecond()
        wait(for: [finished], timeout: 2)
    }
}

private final class PausedQuotaReworkParser: OfficialQuotaParsing {
    let firstStarted = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let firstGate = DispatchSemaphore(value: 0)
    let secondGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var released = false
    var secondReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func releaseSecond() { lock.lock(); released = true; lock.unlock(); secondGate.signal() }
    func parse(data: Data, client: AssistantClient) throws -> OfficialQuotaResponseParser.Output {
        lock.lock(); count += 1; let current = count; lock.unlock()
        if current == 1 { firstStarted.signal(); firstGate.wait() }
        else { secondStarted.signal(); secondGate.wait() }
        return OfficialQuotaResponseParser.Output(windows: [OfficialQuotaWindow(kind: .fiveHour,
            remaining: 94, label: "Fixture", daysText: "Fixture", reset: nil, durationSeconds: 18000)])
    }
}


extension OfficialQuotaClientTests {
    func testOfficialContextCancellationStopsResetCreditTransport() throws {
        let started = expectation(description: "credit request started")
        let stopped = expectation(description: "credit transport actually stopped")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stored-credit-fixture")
            started.fulfill()
            return StubResult(holdsResponse: true)
        }
        StubURLProtocol.onStop = { _ in stopped.fulfill() }
        let client = OfficialQuotaClient(session: session,
            credentialReader: FixtureCredentialReader(codexToken: "other-local", claudeToken: nil))
        let context = OfficialQuotaRequestContext(client: .codex, providerID: "official",
            storedAccessToken: "stored-credit-fixture", credentials: .init(accessToken: "stored-credit-fixture", accountKey: nil))
        let finished = expectation(description: "cancelled completion")
        client.fetchRateLimitResetCredits(storedAccessToken: context.storedAccessToken, context: context) { result in
            guard case .failure(.transport(.urlError(.cancelled))) = result else { return XCTFail("expected cancelled transport") }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2)
        client.cancelQuota(context: context)
        wait(for: [stopped, finished], timeout: 2)
    }
}

// MARK: - Claude account-scoped transport (PR #508 review)

private final class LockedTestClock {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by interval: TimeInterval) { lock.lock(); value.addTimeInterval(interval); lock.unlock() }
}

extension OfficialQuotaClientTests {
    private func claudeContext(_ providerID: String, token: String?) -> OfficialQuotaRequestContext {
        OfficialQuotaRequestContext(client: .claude, providerID: providerID, storedAccessToken: nil,
            credentials: CodexRequestCredentials(accessToken: token, accountKey: nil))
    }

    func testClaudeProvidersSharingAnAccountShareOneRequestAndCancelReleasesOnlyOneConsumer() throws {
        let started = expectation(description: "shared Claude request reached transport")
        StubURLProtocol.setHandler { _ in
            started.fulfill()
            return StubResult(data: Self.claudeBody, holdsResponse: true)
        }
        let client = makeClient(claudeToken: "shared-account")
        let first = expectation(description: "first provider released by cancellation")
        let second = expectation(description: "second provider receives shared result")
        var firstResult: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        var secondResult: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        let firstContext = claudeContext("provider-a", token: "shared-account")
        XCTAssertTrue(client.fetchQuota(context: firstContext) {
            firstResult = $0; first.fulfill()
        })
        XCTAssertFalse(client.fetchQuota(context: claudeContext("provider-b", token: "shared-account")) {
            secondResult = $0; second.fulfill()
        }, "a second Provider on the same account must join the in-flight request")
        wait(for: [started], timeout: 2)

        client.cancelQuota(context: firstContext)
        wait(for: [first], timeout: 2)
        guard case .failure(.transport(.urlError(.cancelled))) = firstResult else { return XCTFail("expected cancellation") }
        XCTAssertNil(secondResult, "cancelling one Provider must not release the other")
        XCTAssertTrue(client.isRequestInFlight(client: .claude, providerID: "provider-b",
            requestCredentials: CodexRequestCredentials(accessToken: "shared-account", accountKey: nil)))

        StubURLProtocol.releaseHeldResponses()
        wait(for: [second], timeout: 2)
        guard case .success = secondResult else { return XCTFail("expected shared success") }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSameProviderCallersShareOneRequestButCancelIndependently() throws {
        let started = expectation(description: "shared request reached transport")
        StubURLProtocol.setHandler { _ in
            started.fulfill()
            return StubResult(data: Self.claudeBody, holdsResponse: true)
        }
        let client = makeClient(claudeToken: "shared-account")
        // e.g. the standard refresh and the quick-switch summary of one Provider.
        let standard = claudeContext("official", token: "shared-account")
        let summary = claudeContext("official", token: "shared-account")
        let cancelled = expectation(description: "standard caller released")
        let delivered = expectation(description: "summary caller receives the shared result")
        var summaryResult: Result<OfficialQuotaResult, OfficialQuotaClientError>?
        XCTAssertTrue(client.fetchQuota(context: standard) {
            guard case .failure(.transport(.urlError(.cancelled))) = $0 else { return XCTFail("expected cancellation") }
            cancelled.fulfill()
        })
        XCTAssertFalse(client.fetchQuota(context: summary) { summaryResult = $0; delivered.fulfill() })
        wait(for: [started], timeout: 2)

        client.cancelQuota(context: standard)
        wait(for: [cancelled], timeout: 2)
        XCTAssertNil(summaryResult, "cancelling one caller must not release another caller of the same Provider")
        XCTAssertTrue(client.isRequestInFlight(client: .claude, providerID: "official",
            requestCredentials: CodexRequestCredentials(accessToken: "shared-account", accountKey: nil)))

        StubURLProtocol.releaseHeldResponses()
        wait(for: [delivered], timeout: 2)
        guard case .success = summaryResult else { return XCTFail("expected shared success") }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testClaudeAccountFingerprintProbeIsShortLivedAndNeverExposesTheToken() throws {
        final class Reader: OfficialQuotaCredentialReading {
            var token: String? = "account-a"
            var reads = 0
            func claudeAccessToken() -> String? { reads += 1; return token }
            func codexAccessToken() -> String? { nil }
            func codexAccountProfile() -> CodexAccountProfile? { nil }
        }
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let reader = Reader()
        let client = OfficialQuotaClient(session: session, credentialReader: reader, now: { clock.now })
        let a = try XCTUnwrap(client.currentClaudeAccountFingerprint())
        XCTAssertFalse(a.contains("account-a"))
        reader.token = "account-b"
        XCTAssertEqual(client.currentClaudeAccountFingerprint(), a, "one poll shares a single Keychain read")
        XCTAssertEqual(reader.reads, 1)
        clock.advance(by: 2)
        let b = try XCTUnwrap(client.currentClaudeAccountFingerprint())
        XCTAssertNotEqual(a, b)
        reader.token = nil
        clock.advance(by: 2)
        XCTAssertNil(client.currentClaudeAccountFingerprint())
        XCTAssertEqual(reader.reads, 3)
    }

    func testConcurrentClaudeCredentialProbesAreCoalesced() {
        final class Reader: OfficialQuotaCredentialReading {
            private let lock = NSLock()
            private(set) var reads = 0
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            func claudeAccessToken() -> String? {
                lock.lock(); reads += 1; lock.unlock()
                started.signal()
                release.wait()
                return "shared-account"
            }
            func codexAccessToken() -> String? { nil }
            func codexAccountProfile() -> CodexAccountProfile? { nil }
            func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
        }
        let reader = Reader()
        let client = OfficialQuotaClient(session: session, credentialReader: reader)
        let group = DispatchGroup()
        let resultsLock = NSLock()
        var credentials: [CodexRequestCredentials] = []
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                let value = client.claudeRequestCredentials()
                resultsLock.lock(); credentials.append(value); resultsLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(reader.started.wait(timeout: .now() + 2), .success)
        reader.release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(reader.readCount(), 1)
        XCTAssertEqual(credentials.count, 8)
        XCTAssertTrue(credentials.allSatisfy { $0.accessToken == "shared-account" })
    }

    func testClaudeProbeCachesProfileAndRereadsEmailOnlyWhenAccountChanges() {
        final class Reader: OfficialQuotaCredentialReading {
            var token: String? = "account-a"
            var plan = "pro"
            var emailReads = 0
            func claudeAccessToken() -> String? { token }
            func claudeCredentials() -> ClaudeStoredCredentials { ClaudeStoredCredentials(accessToken: token, planType: plan) }
            func claudeAccountEmail() -> String? { emailReads += 1; return token.map { $0 + "@example.com" } }
            func codexAccessToken() -> String? { nil }
            func codexAccountProfile() -> CodexAccountProfile? { nil }
        }
        let reader = Reader()
        let client = OfficialQuotaClient(session: session, credentialReader: reader)
        XCTAssertNil(client.cachedClaudeAccountProfile(), "no probe has run yet")

        _ = client.claudeRequestCredentials(cacheFor: 0)
        XCTAssertEqual(client.cachedClaudeAccountProfile(), CodexAccountProfile(email: "account-a@example.com", planType: "pro"))
        reader.plan = "max_5x"
        _ = client.claudeRequestCredentials(cacheFor: 0)
        XCTAssertEqual(client.cachedClaudeAccountProfile(), CodexAccountProfile(email: "account-a@example.com", planType: "max_5x"))
        XCTAssertEqual(reader.emailReads, 1, "same account reuses the email")

        reader.token = "account-b"
        _ = client.claudeRequestCredentials(cacheFor: 0)
        XCTAssertEqual(client.cachedClaudeAccountProfile()?.email, "account-b@example.com")
        XCTAssertEqual(reader.emailReads, 2)

        reader.token = nil
        _ = client.claudeRequestCredentials(cacheFor: 0)
        XCTAssertNil(client.cachedClaudeAccountProfile(), "signed out clears the account row data")
        XCTAssertEqual(reader.emailReads, 2)
    }

    func testTimedOutConcurrentClaudeProbeDoesNotReturnStaleCredentials() {
        final class Reader: OfficialQuotaCredentialReading {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            private var tokens = ["old-account", "new-account"]
            func claudeAccessToken() -> String? {
                let token = tokens.removeFirst()
                started.signal()
                release.wait()
                return token
            }
            func codexAccessToken() -> String? { nil }
            func codexAccountProfile() -> CodexAccountProfile? { nil }
        }
        let reader = Reader()
        let client = OfficialQuotaClient(session: session, credentialReader: reader)
        reader.release.signal()
        XCTAssertEqual(client.claudeRequestCredentials(cacheFor: 0).accessToken, "old-account")
        XCTAssertEqual(reader.started.wait(timeout: .now()), .success)

        let blockedFinished = expectation(description: "blocked probe finishes")
        DispatchQueue.global().async {
            XCTAssertEqual(client.claudeRequestCredentials(cacheFor: 0).accessToken, "new-account")
            blockedFinished.fulfill()
        }
        XCTAssertEqual(reader.started.wait(timeout: .now() + 2), .success)
        let waiter = client.claudeRequestCredentials(cacheFor: 0)
        XCTAssertNil(waiter.accessToken, "a timed-out waiter must not reuse the previous account's token")
        reader.release.signal()
        wait(for: [blockedFinished], timeout: 3)
    }

    func testClaudeAccountSwitchDuringInFlightRequestUsesSeparateFrozenTokens() throws {
        let bothStarted = expectation(description: "both account requests reached transport")
        bothStarted.expectedFulfillmentCount = 2
        let bodyB = Data(#"{"seven_day":{"utilization":"80","resets_at":"2023-11-15T00:13:20Z"}}"#.utf8)
        StubURLProtocol.setHandler { request in
            defer { bothStarted.fulfill() }
            let isB = request.value(forHTTPHeaderField: "Authorization") == "Bearer account-b"
            return StubResult(data: isB ? bodyB : Self.claudeBody, holdsResponse: true)
        }
        // The reader already points at B; A's request must keep its frozen token.
        let client = makeClient(claudeToken: "account-b")
        var results: [String: Result<OfficialQuotaResult, OfficialQuotaClientError>] = [:]
        let done = expectation(description: "both accounts completed")
        done.expectedFulfillmentCount = 2
        XCTAssertTrue(client.fetchQuota(context: claudeContext("official", token: "account-a")) {
            results["a"] = $0; done.fulfill()
        })
        XCTAssertTrue(client.fetchQuota(context: claudeContext("official", token: "account-b")) {
            results["b"] = $0; done.fulfill()
        }, "account B must not coalesce into account A's in-flight request")
        wait(for: [bothStarted], timeout: 2)
        StubURLProtocol.releaseHeldResponses()
        wait(for: [done], timeout: 2)

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        guard case .success(let a) = results["a"], case .success(let b) = results["b"] else { return XCTFail("expected two successes") }
        XCTAssertNotEqual(a.output.windows.map(\.remaining), b.output.windows.map(\.remaining))
        let remainingB = try XCTUnwrap(b.output.windows.first?.remaining)
        XCTAssertEqual(Double(remainingB), 20, accuracy: 0.5, "account B's result must come from B's token")
    }

    func testClaudeMissingFrozenTokenFailsWithoutTransport() throws {
        let client = makeClient(claudeToken: "reader-token")
        let done = expectation(description: "missing credentials")
        XCTAssertTrue(client.fetchQuota(context: claudeContext("official", token: nil)) {
            guard case .failure(.missingCredentials) = $0 else { return XCTFail("expected missing credentials") }
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testClaudeBurstAroundCompletionNeverStartsADuplicateRequest() throws {
        let started = expectation(description: "first request reached transport")
        StubURLProtocol.setHandler { _ in
            started.fulfill()
            return StubResult(data: Self.claudeBody, holdsResponse: true)
        }
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(claudeToken: "burst", now: { clock.now })
        let completions = DispatchGroup()
        completions.enter()
        client.fetchQuota(context: claudeContext("provider-0", token: "burst")) { _ in completions.leave() }
        wait(for: [started], timeout: 2)
        let iterations = 200
        for _ in 0..<iterations { completions.enter() }
        DispatchQueue.global().async { StubURLProtocol.releaseHeldResponses() }
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            client.fetchQuota(context: claudeContext("provider-\(index % 4)", token: "burst")) { _ in completions.leave() }
        }
        XCTAssertEqual(completions.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "every consumer must join the request or reuse its cache")
    }

    func testClaudeCalibrationIsAnchoredToRequestStartDespiteNetworkLatency() throws {
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        StubURLProtocol.setHandler { _ in
            clock.advance(by: 2) // the response arrives two seconds after the request starts
            return StubResult(data: Self.claudeBody)
        }
        let client = makeClient(claudeToken: "latency", now: { clock.now })
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        let context = claudeContext("standard", token: "latency")
        XCTAssertEqual(try XCTUnwrap(client.claudeCalibrationAge(context: context)), 2, accuracy: 0.001)
        clock.advance(by: 57) // t = 59 after request start
        _ = try waitForResult(client, clientName: .claude, providerID: "summary", expectsTransport: false)
        XCTAssertEqual(try XCTUnwrap(client.claudeCalibrationAge(context: context)), 59, accuracy: 0.001)
        clock.advance(by: 1) // t = 60: the real request must happen now, not at t = 62
        _ = try waitForResult(client, clientName: .claude, providerID: "standard")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertNil(client.claudeCalibrationAge(context: claudeContext("standard", token: "other-account")))
    }
}
