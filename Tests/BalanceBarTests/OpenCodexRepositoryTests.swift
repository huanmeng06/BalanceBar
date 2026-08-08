import Foundation
import XCTest
@testable import BalanceBar

final class OpenCodexRepositoryTests: XCTestCase {
    private let candidate = OpenCodexEndpointCandidate(
        baseURL: URL(string: "http://127.0.0.1:10100/v1")!,
        modelProvider: "custom",
        wireAPI: "responses"
    )

    func testEndpointCandidateRequiresResponsesLoopbackV1Configuration() {
        let valid = """
        model_provider = "custom"
        model = "fixture-model"

        [model_providers.custom]
        name = "custom"
        wire_api = "responses"
        base_url = "http://127.0.0.1:10100/v1"
        """
        let candidate = OpenCodexEndpointCandidate.parse(settingsConfig: valid)
        XCTAssertEqual(candidate?.baseURL, URL(string: "http://127.0.0.1:10100/v1"))
        XCTAssertEqual(candidate?.modelProvider, "custom")
        XCTAssertEqual(candidate?.wireAPI, "responses")

        let ordinaryLoopback = valid.replacingOccurrences(of: "wire_api = \"responses\"", with: "wire_api = \"chat\"")
        XCTAssertNil(OpenCodexEndpointCandidate.parse(settingsConfig: ordinaryLoopback))

        let remoteEndpoint = valid.replacingOccurrences(of: "127.0.0.1", with: "provider.example")
        XCTAssertNil(OpenCodexEndpointCandidate.parse(settingsConfig: remoteEndpoint))
    }

    func testReadsStableMaximumFiveChosenPreferencesAndCurrentSelection() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let expectation = expectation(description: "read OpenCodex state")

        repository.readState(for: candidate) { result in
            guard case .recognized(let state) = result else {
                XCTFail("expected OpenCodex management API to be recognized")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(state.managementAvailable)
            XCTAssertEqual(state.preferences.count, 5)
            XCTAssertEqual(
                state.preferences.map(\OpenCodexPreference.selector),
                [
                    "gpt-5.6-sol",
                    "tokenshop/gpt-5.6-sol",
                    "gpt-5.6-luna",
                    "tokenshop/gpt-5.6-luna",
                    "deepseek/deepseek-v4-flash",
                ]
            )
            XCTAssertEqual(state.preferences.filter(\OpenCodexPreference.isCurrent).map(\OpenCodexPreference.selector), ["tokenshop/gpt-5.6-sol"])
            XCTAssertEqual(state.representativeSelector, "tokenshop/gpt-5.6-sol")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testSelectUpdatesDefaultProviderModelAndPreferenceOrderThenVerifies() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let readExpectation = expectation(description: "read state before switch")
        var state: OpenCodexRuntimeState?

        repository.readState(for: candidate) { result in
            if case .recognized(let value) = result { state = value }
            readExpectation.fulfill()
        }
        wait(for: [readExpectation], timeout: 2)
        let original = state
        let preference = try! XCTUnwrap(state?.preferences[2])

        let switchExpectation = expectation(description: "switch OpenCodex preference")
        repository.select(preference, from: try! XCTUnwrap(state)) { result in
            guard case .success(let updated) = result else {
                XCTFail("expected OpenCodex switch to succeed: \(result)")
                switchExpectation.fulfill()
                return
            }
            XCTAssertEqual(updated.defaultProvider, "openai")
            XCTAssertEqual(updated.providerDefaultModels["openai"], "gpt-5.6-luna")
            XCTAssertEqual(updated.chosenSelectors.first, "gpt-5.6-luna")
            XCTAssertEqual(updated.currentSelector, "gpt-5.6-luna")
            XCTAssertNotEqual(updated, original)
            XCTAssertTrue(transport.requests.contains {
                $0.method == "PATCH" && $0.path == "/api/providers" && $0.queryName == "openai"
            })
            XCTAssertTrue(transport.requests.contains { $0.method == "PUT" && $0.path == "/api/subagent-models" })
            XCTAssertEqual(transport.defaultProvider, "openai")
            switchExpectation.fulfill()
        }
        wait(for: [switchExpectation], timeout: 2)
    }

    func testSelectMovesDisplayedPreferenceWithoutTruncatingCompleteChosenList() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let readExpectation = expectation(description: "read state before full-list reorder")
        var state: OpenCodexRuntimeState?

        repository.readState(for: candidate) { result in
            if case .recognized(let value) = result { state = value }
            readExpectation.fulfill()
        }
        wait(for: [readExpectation], timeout: 2)

        let originalChosen = transport.chosenSelectors
        let target = try! XCTUnwrap(state?.preferences.last)
        let switchExpectation = expectation(description: "reorder complete chosen list")
        repository.select(target, from: try! XCTUnwrap(state)) { result in
            guard case .success(let updated) = result else {
                XCTFail("expected full-list reorder to succeed: \(result)")
                switchExpectation.fulfill()
                return
            }

            XCTAssertEqual(updated.chosenSelectors.count, originalChosen.count)
            XCTAssertEqual(transport.chosenSelectors.count, originalChosen.count)
            XCTAssertEqual(updated.chosenSelectors.first, target.selector)
            XCTAssertEqual(transport.chosenSelectors.first, target.selector)
            XCTAssertEqual(transport.chosenSelectors[5], originalChosen[5])
            XCTAssertTrue(transport.chosenSelectors.contains(originalChosen[5]))
            XCTAssertEqual(transport.chosenSelectors.last, originalChosen.last)
            XCTAssertEqual(
                transport.chosenSelectors,
                [target.selector] + originalChosen.filter { $0 != target.selector }
            )
            switchExpectation.fulfill()
        }
        wait(for: [switchExpectation], timeout: 2)
    }

    func testFailedSwitchLeavesFixtureStateUnchanged() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        transport.failWrites = true
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let readExpectation = expectation(description: "read state before failed switch")
        var state: OpenCodexRuntimeState?
        repository.readState(for: candidate) { result in
            if case .recognized(let value) = result { state = value }
            readExpectation.fulfill()
        }
        wait(for: [readExpectation], timeout: 2)

        let originalProvider = transport.defaultProvider
        let originalModels = transport.providerDefaultModels
        let originalChosen = transport.chosenSelectors
        let switchExpectation = expectation(description: "failed switch")
        repository.select(try! XCTUnwrap(state?.preferences.first), from: try! XCTUnwrap(state)) { result in
            guard case .failure(.switchFailed) = result else {
                XCTFail("expected switch failure, got \(result)")
                switchExpectation.fulfill()
                return
            }
            XCTAssertEqual(transport.defaultProvider, originalProvider)
            XCTAssertEqual(transport.providerDefaultModels, originalModels)
            XCTAssertEqual(transport.chosenSelectors, originalChosen)
            switchExpectation.fulfill()
        }
        wait(for: [switchExpectation], timeout: 2)
    }

    func testPartialSwitchFailureRollsBackAndVerifiesOriginalState() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        transport.failWriteAt = 2
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let readExpectation = expectation(description: "read state before partial failure")
        var state: OpenCodexRuntimeState?
        repository.readState(for: candidate) { result in
            if case .recognized(let value) = result { state = value }
            readExpectation.fulfill()
        }
        wait(for: [readExpectation], timeout: 2)

        let originalProvider = transport.defaultProvider
        let originalModels = transport.providerDefaultModels
        let originalChosen = transport.chosenSelectors
        let switchExpectation = expectation(description: "partial switch failure")
        repository.select(try! XCTUnwrap(state?.preferences.first), from: try! XCTUnwrap(state)) { result in
            guard case .failure(.switchFailed) = result else {
                XCTFail("expected switch failure, got \(result)")
                switchExpectation.fulfill()
                return
            }
            XCTAssertEqual(transport.defaultProvider, originalProvider)
            XCTAssertEqual(transport.providerDefaultModels, originalModels)
            XCTAssertEqual(transport.chosenSelectors, originalChosen)
            switchExpectation.fulfill()
        }
        wait(for: [switchExpectation], timeout: 2)
    }

    func testLocalConfigConfirmsOpenCodexWhenManagementAPIIsUnavailable() {
        let transport = AlwaysFailTransport()
        let local = OpenCodexLocalConfigSnapshot(
            port: candidate.port,
            defaultProvider: "tokenshop",
            providerDefaultModels: ["tokenshop": "gpt-5.6-sol"],
            chosenSelectors: ["gpt-5.6-sol", "tokenshop/gpt-5.6-sol", "gpt-5.6-luna", "tokenshop/gpt-5.6-luna", "deepseek/deepseek-v4-flash", "deepseek/deepseek-chat"]
        )
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: local),
            tokenProvider: NoTokenProvider()
        )
        let expectation = expectation(description: "read local OpenCodex state")

        repository.readState(for: candidate) { result in
            guard case .recognized(let state) = result else {
                XCTFail("expected local OpenCodex config to confirm the provider")
                expectation.fulfill()
                return
            }
            XCTAssertFalse(state.managementAvailable)
            XCTAssertTrue(state.preferenceDataAvailable)
            XCTAssertEqual(state.preferences.count, 5)
            XCTAssertEqual(state.representativeSelector, "tokenshop/gpt-5.6-sol")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testStructuredManagementConfigKeepsOpenCodexStateWhenPreferenceEndpointIsUnavailable() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        transport.failSubagentReads = true
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let expectation = expectation(description: "read partial OpenCodex state")

        repository.readState(for: candidate) { result in
            guard case .recognized(let state) = result else {
                XCTFail("expected structured OpenCodex config to remain recognized")
                expectation.fulfill()
                return
            }
            XCTAssertFalse(state.managementAvailable)
            XCTAssertFalse(state.preferenceDataAvailable)
            XCTAssertTrue(state.preferences.isEmpty)
            XCTAssertEqual(state.representativeSelector, "tokenshop/gpt-5.6-sol")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testUnverifiedLoopbackCandidateDoesNotBecomeOpenCodex() {
        let repository = OpenCodexRepository(
            transport: AlwaysFailTransport(),
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: NoTokenProvider()
        )
        let expectation = expectation(description: "reject unverified candidate")

        repository.readState(for: candidate) { result in
            guard case .unavailable = result else {
                XCTFail("expected an unavailable unverified loopback service to remain ordinary")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testForeignLoopbackHealthDoesNotReceiveAdminToken() {
        let transport = MutableOpenCodexTransport(candidate: candidate)
        transport.healthService = "another-local-service"
        let tokenProvider = CountingTokenProvider()
        let repository = OpenCodexRepository(
            transport: transport,
            configReader: StubConfigReader(snapshot: nil),
            tokenProvider: tokenProvider
        )
        let expectation = expectation(description: "reject foreign loopback service")

        repository.readState(for: candidate) { result in
            guard case .notRecognized = result else {
                XCTFail("expected a foreign loopback service to remain ordinary")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(tokenProvider.calls, 0)
            XCTAssertEqual(transport.requests.map { "\($0.method) \($0.path)" }, ["GET /healthz"])
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }
}

private final class NoTokenProvider: OpenCodexAdminTokenProvider {
    func token(for candidate: OpenCodexEndpointCandidate) -> String? { nil }
}

private final class CountingTokenProvider: OpenCodexAdminTokenProvider {
    private(set) var calls = 0

    func token(for candidate: OpenCodexEndpointCandidate) -> String? {
        calls += 1
        return "fixture-token"
    }
}

private final class StubConfigReader: OpenCodexConfigReader {
    let snapshot: OpenCodexLocalConfigSnapshot?

    init(snapshot: OpenCodexLocalConfigSnapshot?) {
        self.snapshot = snapshot
    }

    func read(matching candidate: OpenCodexEndpointCandidate) -> OpenCodexLocalConfigSnapshot? {
        snapshot
    }
}

private final class AlwaysFailTransport: OpenCodexHTTPTransport {
    func send(
        _ request: URLRequest,
        completion: @escaping (Result<OpenCodexHTTPResponse, Error>) -> Void
    ) {
        DispatchQueue.global().async {
            completion(.failure(OpenCodexRepositoryError.managementUnavailable))
        }
    }
}

private final class MutableOpenCodexTransport: OpenCodexHTTPTransport {
    struct RequestRecord {
        let method: String
        let path: String
        let queryName: String?
    }

    private let candidate: OpenCodexEndpointCandidate
    private let lock = NSLock()
    private(set) var defaultProvider = "tokenshop"
    private(set) var providerDefaultModels = ["tokenshop": "gpt-5.6-sol"]
    private(set) var chosenSelectors = [
        "gpt-5.6-sol",
        "tokenshop/gpt-5.6-sol",
        "gpt-5.6-luna",
        "tokenshop/gpt-5.6-luna",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-chat",
    ]
    var failWrites = false
    var failSubagentReads = false
    var failWriteAt: Int?
    var healthService = "opencodex"
    private(set) var requests: [RequestRecord] = []
    private var writeRequestCount = 0

    init(candidate: OpenCodexEndpointCandidate) {
        self.candidate = candidate
    }

    func send(
        _ request: URLRequest,
        completion: @escaping (Result<OpenCodexHTTPResponse, Error>) -> Void
    ) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let queryName = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value
            self.lock.lock()
            self.requests.append(RequestRecord(method: method, path: path, queryName: queryName))
            let shouldFailWrite: Bool
            if method == "GET" {
                shouldFailWrite = false
            } else {
                self.writeRequestCount += 1
                shouldFailWrite = self.failWrites || self.failWriteAt == self.writeRequestCount
            }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let response: OpenCodexHTTPResponse
            if self.failSubagentReads && method == "GET" && path == "/api/subagent-models" {
                response = OpenCodexHTTPResponse(statusCode: 503, data: Data())
            } else if shouldFailWrite {
                response = OpenCodexHTTPResponse(statusCode: 503, data: Data())
            } else {
                response = self.response(method: method, path: path, queryName: queryName, body: body)
            }
            self.lock.unlock()
            completion(.success(response))
        }
    }

    private func response(
        method: String,
        path: String,
        queryName: String?,
        body: [String: Any]?
    ) -> OpenCodexHTTPResponse {
        if method == "GET", path == "/healthz" {
            return json([
                "service": healthService,
                "status": "ok",
                "port": candidate.port,
            ])
        }
        if method == "GET", path == "/api/config" {
            let providers: [String: [String: Any]] = [
                "tokenshop": provider("tokenshop"),
                "openai": provider("openai"),
                "deepseek": provider("deepseek"),
            ]
            return json([
                "port": candidate.port,
                "hostname": "127.0.0.1",
                "defaultProvider": defaultProvider,
                "codexAutoStart": true,
                "websockets": true,
                "providers": providers,
            ])
        }
        if method == "GET", path == "/api/subagent-models" {
            return json([
                "chosen": chosenSelectors,
                "available": [
                    "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4",
                    "deepseek/deepseek-v4-flash", "deepseek/deepseek-chat",
                    "tokenshop/gpt-5.6-sol", "tokenshop/gpt-5.6-luna",
                ],
            ])
        }
        if method == "PATCH", path == "/api/providers", let queryName, let body {
            if body["setDefault"] as? Bool == true {
                defaultProvider = queryName
            }
            if let model = body["defaultModel"] as? String {
                if model.isEmpty {
                    providerDefaultModels.removeValue(forKey: queryName)
                } else {
                    providerDefaultModels[queryName] = model
                }
            }
            return json(["success": true])
        }
        if method == "PUT", path == "/api/subagent-models",
           let models = body?["models"] as? [String] {
            chosenSelectors = models
            return json(["ok": true, "applied": models])
        }
        return OpenCodexHTTPResponse(statusCode: 404, data: Data())
    }

    private func provider(_ name: String) -> [String: Any] {
        var value: [String: Any] = [
            "adapter": "openai-responses",
            "baseUrl": "https://\(name).example.test",
            "hasApiKey": name != "openai",
        ]
        if let model = providerDefaultModels[name] { value["defaultModel"] = model }
        return value
    }

    private func json(_ value: [String: Any]) -> OpenCodexHTTPResponse {
        OpenCodexHTTPResponse(
            statusCode: 200,
            data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        )
    }
}
