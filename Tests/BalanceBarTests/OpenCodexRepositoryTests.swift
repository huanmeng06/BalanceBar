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

    func testEndpointCandidateUnwrapsCCSwitchJSONConfigWrapper() {
        let embedded = """
        disable_response_storage = true
        model = "fixture-model"
        model_provider = "custom"

        [model_providers.custom]
        name = "fixture"
        requires_openai_auth = false
        wire_api = "responses"
        base_url = "http://127.0.0.1:10100/v1"
        """
        let wrapper: [String: Any] = [
            "auth": ["mode": "none"],
            "config": embedded,
        ]
        let data = try! JSONSerialization.data(withJSONObject: wrapper)
        let settingsConfig = String(data: data, encoding: .utf8)!

        let candidate = OpenCodexEndpointCandidate.parse(settingsConfig: settingsConfig)
        XCTAssertEqual(candidate?.modelProvider, "custom")
        XCTAssertEqual(candidate?.wireAPI, "responses")
        XCTAssertEqual(candidate?.baseURL, URL(string: "http://127.0.0.1:10100/v1"))

        let ordinaryWrapper = embedded.replacingOccurrences(
            of: "wire_api = \"responses\"",
            with: "wire_api = \"chat\""
        )
        let ordinaryData = try! JSONSerialization.data(withJSONObject: [
            "auth": ["mode": "none"],
            "config": ordinaryWrapper,
        ])
        XCTAssertNil(
            OpenCodexEndpointCandidate.parse(
                settingsConfig: String(data: ordinaryData, encoding: .utf8)!
            )
        )
    }

    func testProviderDescriptorClassificationUsesAdapterAuthAndEndpointNotModelName() {
        let official = OpenCodexProviderDescriptor.parse(
            id: "official",
            object: [
                "adapter": "openai-responses",
                "authMode": "forward",
                "baseUrl": "https://chatgpt.com/backend-api",
                "defaultModel": "gpt-5.6",
            ]
        )
        let thirdParty = OpenCodexProviderDescriptor.parse(
            id: "relay",
            object: [
                "adapter": "openai-responses",
                "authMode": "key",
                "baseUrl": "https://relay.example.test/v1",
                "defaultModel": "gpt-5.6",
            ]
        )

        XCTAssertEqual(official?.isOfficial, true)
        XCTAssertEqual(thirdParty?.isOfficial, false)
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

    func testCardPlannerDisplaysChosenCountsFromZeroThroughFiveAndNeverMoreThanFive() {
        let allSelectors = [
            "official/alpha",
            "relay/beta",
            "relay/gamma",
            "official/delta",
            "relay/epsilon",
            "relay/zeta",
        ]
        let descriptors = [
            "official": OpenCodexProviderDescriptor(
                id: "official",
                adapter: "openai-responses",
                authMode: "forward",
                baseURL: URL(string: "https://api.openai.com/v1")!
            ),
            "relay": OpenCodexProviderDescriptor(
                id: "relay",
                adapter: "openai-responses",
                authMode: "key",
                baseURL: URL(string: "https://relay.example.test/v1")!
            ),
        ]
        let sources = [relaySummarySource(name: "relay")]

        for count in [0, 1, 3, 5, 6] {
            let selected = Array(allSelectors.prefix(count))
            let state = makeCardState(
                selectors: selected,
                descriptors: descriptors
            )
            let plans = OpenCodexCardPlanner.plans(state: state, sources: sources)
            XCTAssertEqual(plans.count, min(5, count), "count=\(count)")
            XCTAssertEqual(
                plans.map(\.selector),
                Array(selected.prefix(5)),
                "count=\(count)"
            )
        }
    }

    func testCardPlannerUsesStructuredProviderIdentityAndStableOrder() {
        let official = OpenCodexProviderDescriptor(
            id: "official",
            adapter: "openai-responses",
            authMode: "forward",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        let thirdPartyGPTNamed = OpenCodexProviderDescriptor(
            id: "relay",
            adapter: "openai-responses",
            authMode: "key",
            baseURL: URL(string: "https://relay.example.test/v1")!
        )
        let state = makeCardState(
            selectors: ["relay/gpt-5.6", "official/o4-mini", "relay/o3"],
            descriptors: [
                "official": official,
                "relay": thirdPartyGPTNamed,
            ]
        )
        let plans = OpenCodexCardPlanner.plans(
            state: state,
            sources: [relaySummarySource(name: "relay")]
        )

        XCTAssertEqual(plans.map(\.selector), ["relay/gpt-5.6", "official/o4-mini", "relay/o3"])
        XCTAssertEqual(plans[0].source, .balance(providerID: "relay-source"))
        XCTAssertEqual(plans[1].source, .official)
        XCTAssertEqual(plans[2].source, .balance(providerID: "relay-source"))
    }

    func testCardPlannerSharesOneThirdPartyBalanceSourceAcrossModels() {
        let descriptor = OpenCodexProviderDescriptor(
            id: "relay",
            adapter: "openai-responses",
            authMode: "key",
            baseURL: URL(string: "https://relay.example.test/v1")!
        )
        let state = makeCardState(
            selectors: ["relay/model-a", "relay/model-b"],
            descriptors: ["relay": descriptor]
        )
        let plans = OpenCodexCardPlanner.plans(
            state: state,
            sources: [relaySummarySource(name: "relay")]
        )
        XCTAssertEqual(plans.map(\.source), [
            .balance(providerID: "relay-source"),
            .balance(providerID: "relay-source"),
        ])
    }

    func testCardPlannerExcludesOpenCodexLoopbackBalanceSourceAndMarksMissingData() {
        let descriptor = OpenCodexProviderDescriptor(
            id: "local-relay",
            adapter: "openai-responses",
            authMode: "key",
            baseURL: URL(string: "https://127.0.0.1/v1")!,
            isOfficial: false
        )
        let state = makeCardState(
            selectors: ["local-relay/gpt-5.6"],
            descriptors: ["local-relay": descriptor]
        )
        let loopbackSource = ProviderSummarySource(
            id: "loopback-source",
            name: "local-relay",
            isOfficial: false,
            query: fixtureBalanceQuery(url: "https://127.0.0.1/usage"),
            officialAccessToken: nil,
            openCodexCandidate: candidate,
            websiteURL: nil
        )
        let plans = OpenCodexCardPlanner.plans(state: state, sources: [loopbackSource])
        XCTAssertEqual(plans.count, 1)
        guard case .unavailable(let category, _) = plans[0].source else {
            return XCTFail("an OpenCodex source must not be reused as an upstream balance source")
        }
        XCTAssertEqual(category, .balance)

        let cards = OpenCodexCardPlanner.cards(plans: plans, data: [:])
        guard case .unavailable(let cardCategory, let reason) = cards[0].data else {
            return XCTFail("missing source should produce an unavailable card")
        }
        XCTAssertEqual(cardCategory, .balance)
        XCTAssertTrue(reason.contains("余额") || reason.contains("balance"))
    }

    func testCardPlannerRejectsOrdinaryLoopbackBalanceProvider() {
        let descriptor = OpenCodexProviderDescriptor(
            id: "local-relay",
            adapter: "openai-responses",
            authMode: "key",
            baseURL: URL(string: "https://127.0.0.1/v1")!,
            isOfficial: false
        )
        let state = makeCardState(
            selectors: ["local-relay/gpt-5.6"],
            descriptors: ["local-relay": descriptor]
        )
        let ordinaryLoopbackSource = ProviderSummarySource(
            id: "ordinary-loopback-source",
            name: "local-relay",
            isOfficial: false,
            query: fixtureBalanceQuery(url: "https://127.0.0.1/usage"),
            officialAccessToken: nil,
            openCodexCandidate: nil,
            websiteURL: nil
        )

        let plans = OpenCodexCardPlanner.plans(
            state: state,
            sources: [ordinaryLoopbackSource]
        )
        guard case .unavailable(.balance, let reason) = plans[0].source else {
            return XCTFail("an ordinary loopback provider must not become a balance source")
        }
        XCTAssertTrue(reason.contains("余额") || reason.contains("balance"))
    }

    func testInjectedCardDataCoversSuccessFailureAndRecoveryWithoutSyntheticNumbers() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = makeCardState(
            selectors: ["official/o4-mini", "relay/model-a"],
            descriptors: [
                "official": OpenCodexProviderDescriptor(
                    id: "official",
                    adapter: "openai-responses",
                    authMode: "forward",
                    baseURL: URL(string: "https://api.openai.com/v1")!
                ),
                "relay": OpenCodexProviderDescriptor(
                    id: "relay",
                    adapter: "openai-responses",
                    authMode: "key",
                    baseURL: URL(string: "https://relay.example.test/v1")!
                ),
            ]
        )
        let plans = OpenCodexCardPlanner.plans(
            state: state,
            sources: [relaySummarySource(name: "relay")]
        )
        let successful: [OpenCodexCardSource: OpenCodexCardData] = [
            .official: .official(
                remaining: 73,
                label: "7-Day Quota",
                reset: "2d3h",
                updatedAt: now
            ),
            .balance(providerID: "relay-source"): .balance(
                amount: 12.34,
                unit: "USD",
                websiteURL: URL(string: "https://relay.example.test")!,
                updatedAt: now
            ),
        ]
        let successCards = OpenCodexCardPlanner.cards(plans: plans, data: successful)
        guard case .official(let remaining, _, let reset, _) = successCards[0].data,
              case .balance(let amount, let unit, let websiteURL, _) = successCards[1].data else {
            return XCTFail("injected successful data should be preserved on the matching cards")
        }
        XCTAssertEqual(remaining, 73)
        XCTAssertEqual(reset, "2d3h")
        XCTAssertEqual(amount, 12.34)
        XCTAssertEqual(unit, "USD")
        XCTAssertEqual(websiteURL, URL(string: "https://relay.example.test"))

        let failed: [OpenCodexCardSource: OpenCodexCardData] = [
            .official: .unavailable(category: .quota, reason: "quota unavailable: stub failure"),
            .balance(providerID: "relay-source"): .unavailable(category: .balance, reason: "balance unavailable: stub failure"),
        ]
        let failedCards = OpenCodexCardPlanner.cards(plans: plans, data: failed)
        for card in failedCards {
            guard case .unavailable(_, let reason) = card.data else {
                return XCTFail("failed source must be visibly unavailable")
            }
            XCTAssertFalse(reason.contains("0"))
            XCTAssertFalse(reason.contains("100"))
        }

        let recoveredCards = OpenCodexCardPlanner.cards(plans: plans, data: successful)
        XCTAssertEqual(recoveredCards, successCards)
    }

    private func makeCardState(
        selectors: [String],
        descriptors: [String: OpenCodexProviderDescriptor]
    ) -> OpenCodexRuntimeState {
        let preferences = selectors.enumerated().compactMap { index, selector -> OpenCodexPreference? in
            let parts = selector.split(separator: "/", maxSplits: 1).map(String.init)
            guard !parts.isEmpty else { return nil }
            let provider = parts.count == 1 ? "openai" : parts[0]
            let model = parts.count == 1 ? parts[0] : parts[1]
            return OpenCodexPreference(
                selector: selector,
                provider: provider,
                model: model,
                isCurrent: index == 0
            )
        }
        return OpenCodexRuntimeState(
            candidate: candidate,
            defaultProvider: preferences.first?.provider ?? "openai",
            providerDefaultModels: [:],
            providers: descriptors,
            chosenSelectors: selectors,
            availableSelectors: selectors,
            preferences: preferences,
            managementAvailable: true,
            preferenceDataAvailable: true
        )
    }

    private func relaySummarySource(name: String) -> ProviderSummarySource {
        ProviderSummarySource(
            id: "relay-source",
            name: name,
            isOfficial: false,
            query: fixtureBalanceQuery(url: "https://relay.example.test/usage"),
            officialAccessToken: nil,
            openCodexCandidate: nil,
            websiteURL: URL(string: "https://relay.example.test")!
        )
    }

    private func fixtureBalanceQuery(url: String) -> BalanceQuery {
        BalanceQuery(
            url: url,
            websiteURL: URL(string: "https://relay.example.test")!,
            apiKey: "test-only",
            intervalMinutes: 30,
            timeoutSeconds: 5,
            isRightCode: false,
            subscriptionPrefix: "/codex",
            nativeBalanceProvider: nil,
            isNewAPI: false,
            additionalHeaders: [:]
        )
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
