import Foundation
import XCTest
@testable import BalanceBar

final class ClaudeTokenAutoRefresherTests: XCTestCase {
    private final class Fixture: ClaudeRefreshCommandRunning, ClaudeExecutableLocating {
        static let ip = "203.0.113.42"
        static let proxy = URL(string: "http://user:password@proxy.invalid:8080")!
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var enabled = true
        var allowlist = ClaudeEgressGuardSettings(enabled: true, allowedIPs: [ip])
        var route = CCSwitchProxyConfiguration(httpsProxy: proxy)
        var availability = ClaudeTokenRefreshModAvailability.available
        var busy = false
        var settings: [String: Any]?
        var token: String? = "test-access-secret"
        lazy var expiry: Date? = now.addingTimeInterval(-120)
        var unreadable = false
        var pause: String?
        var executable: String? = "/fixture/claude"
        var result: ModCommandResult? = .init(exitCode: 0, stdout: "test-access-secret", stderr: "unlogged output")
        var didReadCredential: ((Int) -> Void)?
        var reply: ((URL, CCSwitchProxyConfiguration) -> ClaudeEgressGuard.ProbeResult)?
        var didRun: (() -> Void)?
        var reads = 0
        var probes: [(URL, CCSwitchProxyConfiguration)] = []
        var commands: [([String], [String: String], TimeInterval)] = []
        var logs: [String] = []

        lazy var refresher = makeRefresher()

        func makeRefresher(loadPause: (() -> String?)? = nil, savePause: ((String?) -> Void)? = nil) -> ClaudeTokenAutoRefresher {
            let guardrail = ClaudeEgressGuard(settings: { [unowned self] in allowlist }, probe: { _ in XCTFail("Wrong probe") })
            return ClaudeTokenAutoRefresher(
                isEnabled: { [unowned self] in enabled }, egressGuard: guardrail, route: { [unowned self] in route },
                probe: { [unowned self] url, route, completion in
                    probes.append((url, route))
                    completion(reply?(url, route) ?? .success(.init(ip: Self.ip, country: "US", route: route)))
                }, settings: { [unowned self] in settings },
                credentials: { [unowned self] in
                    reads += 1; didReadCredential?(reads)
                    return (token, expiry, unreadable)
                }, modAvailability: { [unowned self] in availability }, modOperationInProgress: { [unowned self] in busy },
                locator: self, runner: self,
                loadPause: loadPause ?? { [unowned self] in pause }, savePause: savePause ?? { [unowned self] in pause = $0 },
                environment: {
                    Dictionary(uniqueKeysWithValues: ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
                        "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_USE_BEDROCK",
                        "NO_PROXY", "no_proxy", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
                        .map { ($0, "inherited") })
                }, now: { [unowned self] in now }, log: { [unowned self] in logs.append($0) })
        }

        func locate() -> String? { executable }

        func run(executablePath: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> ModCommandResult? {
            XCTAssertEqual(executablePath, executable)
            commands.append((arguments, environment, timeout))
            didRun?()
            return result
        }
    }

    @discardableResult
    private func attempt(_ fixture: Fixture, using override: ClaudeTokenAutoRefresher? = nil,
                         reason: FetchRequestReason = .scheduled) -> Bool {
        let refresher = override ?? fixture.refresher
        let done = expectation(description: "refresh completed")
        var ran = false
        if !refresher.preflight(expiresAt: fixture.expiry, hasToken: fixture.token != nil, reason: reason,
                               completion: { ran = $0; done.fulfill() }) { done.fulfill() }
        wait(for: [done], timeout: 3)
        return ran
    }

    func testCurrentSettingsConflictIsReadOnlyAndReflectsRemoval() {
        let fixture = Fixture()
        fixture.pause = "signed_out"
        let refresher = fixture.refresher
        let originalState = refresher.state
        XCTAssertEqual(originalState, .paused)
        XCTAssertNil(refresher.currentSettingsConflict())
        fixture.settings = ["env": ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]]
        XCTAssertEqual(refresher.currentSettingsConflict(), "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        fixture.settings = nil
        XCTAssertNil(refresher.currentSettingsConflict())
        XCTAssertEqual(refresher.state, originalState)
        XCTAssertEqual(fixture.pause, "signed_out")
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertTrue(fixture.probes.isEmpty)
        XCTAssertTrue(fixture.logs.isEmpty)
        XCTAssertEqual(fixture.reads, 0)
    }

    func testFreshCredentialDoesNotProbeOrRun() {
        let fixture = Fixture()
        fixture.expiry = fixture.now.addingTimeInterval(10)
        XCTAssertFalse(attempt(fixture))
        XCTAssertTrue(fixture.probes.isEmpty)
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testExpiredTokenRefreshesWithExactlyTheCheckedRouteAndSafeEnvironment() throws {
        for route in [CCSwitchProxyConfiguration(httpsProxy: Fixture.proxy), .init()] {
            let fixture = Fixture()
            fixture.route = route
            fixture.didRun = { [unowned fixture] in fixture.expiry = fixture.now.addingTimeInterval(480 * 60) }
            XCTAssertTrue(attempt(fixture))
            XCTAssertEqual(fixture.refresher.state, .succeeded(at: fixture.now))
            XCTAssertEqual(fixture.probes.map { $0.0 }, [OfficialQuotaClient.claudeEgressTraceURL, OfficialQuotaClient.claudePlatformEgressTraceURL])
            XCTAssertEqual(fixture.probes.map { $0.1 }, [route, route])
            let command = try XCTUnwrap(fixture.commands.first)
            XCTAssertEqual(fixture.commands.count, 1)
            XCTAssertEqual(command.0, ["plugin", "marketplace", "update", "balancebar-mods"])
            XCTAssertEqual(command.2, 60)
            let flags = ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "DISABLE_BUG_COMMAND"]
            var expected = Dictionary(uniqueKeysWithValues: flags.map { ($0, "1") })
            for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
                expected[key] = route.httpsProxy?.absoluteString
            }
            XCTAssertEqual(command.1, expected)
            XCTAssertTrue(fixture.logs.contains { $0.contains("result=refreshed; exit=0") && $0.contains("remaining_after_min=480") })
            for secret in [Fixture.ip, Fixture.proxy.absoluteString, "test-access-secret", "unlogged output"] {
                XCTAssertFalse(fixture.logs.joined().contains(secret))
            }
            XCTAssertFalse(attempt(fixture))
        }
    }

    func testFailClosedPreconditionsDoNotProbeOrLaunch() {
        let cases: [(Fixture) -> Void] = [
            { $0.enabled = false }, { $0.allowlist.enabled = false }, { $0.allowlist.allowedIPs = [] },
            { $0.availability = .detecting }, { $0.availability = .unknown }, { $0.availability = .unavailable },
            { $0.busy = true }, { $0.unreadable = true },
            { $0.route = .init(allProxy: URL(string: "socks5://proxy.invalid:1080")) },
            { $0.route = .init(); $0.settings = ["env": ["HTTPS_PROXY": "invalid"]] },
            { $0.settings = ["env": ["https_proxy": "http://other.invalid"]] },
        ]
        for (index, configure) in cases.enumerated() {
            let fixture = Fixture()
            configure(fixture)
            XCTAssertFalse(attempt(fixture), "case \(index)")
            XCTAssertTrue(fixture.probes.isEmpty, "case \(index)")
            XCTAssertTrue(fixture.commands.isEmpty, "case \(index)")
            XCTAssertEqual(fixture.refresher.state, index < 8 ? .idle : .failed(.routeUnsupported, nextTryAt: nil))
        }
    }

    func testEitherTraceMustMatchAllowlistAndRegion() {
        let failures: [(ClaudeEgressGuardBlock, (CCSwitchProxyConfiguration) -> ClaudeEgressGuard.ProbeResult)] = [
            (.mismatch, { .success(.init(ip: "203.0.113.1", country: "US", route: $0)) }),
            (.unsupportedRegion, { .success(.init(ip: Fixture.ip, country: "ZZ", route: $0)) }),
            (.checkFailed, { _ in .failure(.unknown) }),
            (.checkFailed, { _ in .success(.init(ip: Fixture.ip, country: "US")) }),
        ]
        for host in ["claude.ai", "platform.claude.com"] {
            for (failure, reply) in failures {
                let fixture = Fixture()
                fixture.reply = { url, route in
                    url.host == host ? reply(route) : .success(.init(ip: Fixture.ip, country: "US", route: route))
                }
                XCTAssertFalse(attempt(fixture))
                XCTAssertEqual(fixture.refresher.state, .failed(.egress(failure), nextTryAt: fixture.now.addingTimeInterval(1800)))
                XCTAssertTrue(fixture.commands.isEmpty)
            }
        }
    }

    func testChangesAfterProbesPreventLaunch() {
        let cases: [(Fixture) -> Void] = [
            { $0.route = .init() }, { $0.allowlist.allowedIPs = ["203.0.113.1"] },
            { $0.expiry = $0.now.addingTimeInterval(3600) }, { $0.token = "different-test-token" },
            { $0.settings = ["env": ["CLAUDE_CONFIG_DIR": "value"]] }, { $0.enabled = false },
            { $0.allowlist.enabled = false }, { $0.allowlist.allowedIPs = [] }, { $0.busy = true },
        ]
        for configure in cases {
            let fixture = Fixture()
            fixture.didReadCredential = { [unowned fixture] index in if index == 2 { configure(fixture) } }
            XCTAssertFalse(attempt(fixture))
            XCTAssertEqual(fixture.probes.count, 2)
            XCTAssertTrue(fixture.commands.isEmpty)
        }
    }

    func testConflictingSettingsAreNamedButNotLoggedWithTheirValues() {
        let variables = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR",
                         "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]
        let cases: [(String, [String: Any])] = variables.map { ($0, ["env": [$0: "private-value"]]) } + [
            ("apiKeyHelper", ["apiKeyHelper": "private-value"]), ("NO_PROXY", ["env": ["NO_PROXY": "*"]]),
            ("NO_PROXY", ["env": ["NO_PROXY": ".claude.com"]]), ("no_proxy", ["env": ["no_proxy": "claude.ai"]]),
        ]
        for (variable, settings) in cases {
            let fixture = Fixture()
            fixture.settings = settings
            XCTAssertFalse(attempt(fixture))
            XCTAssertEqual(fixture.refresher.state, .failed(.settingsEnv(variable: variable), nextTryAt: nil))
            XCTAssertTrue(fixture.probes.isEmpty)
            XCTAssertTrue(fixture.commands.isEmpty)
            XCTAssertTrue(fixture.logs.contains { $0.hasSuffix("variable=\(variable)") })
            XCTAssertFalse(fixture.logs.joined().contains("private-value"))
        }
        XCTAssertNil(ClaudeTokenAutoRefresher.conflictingSetting(["env": ["NO_PROXY": "localhost,127.0.0.1"]]))
    }

    func testUnchangedExpiredTokenPausesAndManualCannotUnpauseButNewCredentialCan() {
        let fixture = Fixture()
        XCTAssertTrue(attempt(fixture))
        XCTAssertEqual(fixture.refresher.state, .paused)
        XCTAssertEqual(fixture.pause, ClaudeAccountIdentityProvider.credentialVersion(for: fixture.token!)?.value)
        XCTAssertFalse(attempt(fixture, reason: .manual))
        XCTAssertEqual(fixture.commands.count, 1)
        fixture.token = "new-test-token"
        fixture.expiry = fixture.now.addingTimeInterval(3600)
        XCTAssertFalse(attempt(fixture))
        XCTAssertNil(fixture.pause)
        XCTAssertEqual(fixture.refresher.state, .idle)
        XCTAssertTrue(fixture.logs.contains("token refresh resumed; reason=new_credential"))
    }

    func testClearedCredentialsPersistPauseAcrossRefresherInstances() {
        let suite = "ClaudeTokenAutoRefresherTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let fixture = Fixture()
        func instance() -> ClaudeTokenAutoRefresher {
            fixture.makeRefresher(loadPause: { preferences.claudeTokenAutoRefreshPausedCredential },
                                 savePause: { preferences.claudeTokenAutoRefreshPausedCredential = $0 })
        }
        fixture.didRun = { [unowned fixture] in fixture.token = nil; fixture.expiry = nil }
        XCTAssertTrue(attempt(fixture, using: instance()))
        XCTAssertEqual(preferences.claudeTokenAutoRefreshPausedCredential, "signed_out")
        let restarted = instance()
        XCTAssertEqual(restarted.state, .paused)
        XCTAssertFalse(attempt(fixture, using: restarted))
        XCTAssertEqual(fixture.commands.count, 1)
        fixture.token = "new-test-token"
        fixture.expiry = fixture.now.addingTimeInterval(3600)
        XCTAssertFalse(attempt(fixture, using: restarted))
        XCTAssertNil(preferences.claudeTokenAutoRefreshPausedCredential)
        XCTAssertEqual(restarted.state, .idle)
    }

    func testTemporaryFailuresCoolDownAndManualBypassesWithoutChangingPause() {
        let cases: [(ClaudeTokenRefreshFailure, (Fixture) -> Void)] = [
            (.commandFailed(exitCode: 3), { $0.result?.exitCode = 3 }), (.timedOut, { $0.result?.exitCode = -1 }),
            (.launchFailed, { $0.result = nil }), (.claudeNotFound, { $0.executable = nil }),
            (.commandFailed(exitCode: 0), { fixture in fixture.didRun = { [unowned fixture] in fixture.unreadable = true } }),
        ]
        for (failure, configure) in cases {
            let fixture = Fixture()
            configure(fixture)
            attempt(fixture)
            XCTAssertEqual(fixture.refresher.state, .failed(failure, nextTryAt: fixture.now.addingTimeInterval(1800)))
            XCTAssertNil(fixture.pause)
            fixture.unreadable = false
            let readsBeforeCooldown = fixture.probes.count
            XCTAssertFalse(attempt(fixture))
            XCTAssertEqual(fixture.probes.count, readsBeforeCooldown)
            XCTAssertTrue(fixture.logs.last?.contains("reason=cooldown") == true)
            fixture.executable = "/fixture/claude"
            fixture.result = .init(exitCode: 0, stdout: "", stderr: "")
            fixture.didRun = { [unowned fixture] in fixture.expiry = fixture.now.addingTimeInterval(100) }
            XCTAssertTrue(attempt(fixture, reason: .manual))
            XCTAssertEqual(fixture.refresher.state, .succeeded(at: fixture.now))
        }
        let fixture = Fixture()
        fixture.result?.exitCode = 3
        attempt(fixture)
        fixture.now.addTimeInterval(1800)
        XCTAssertTrue(attempt(fixture))
        XCTAssertEqual(fixture.commands.count, 2)
    }

    func testThreeConcurrentTriggersShareProcessEvenWhenSwitchTurnsOff() {
        let fixture = Fixture()
        _ = fixture.expiry
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        fixture.didRun = { [unowned fixture] in
            entered.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 3), .success)
            fixture.expiry = fixture.now.addingTimeInterval(3600)
        }
        let refresher = fixture.refresher
        let done = expectation(description: "coalesced completions")
        done.expectedFulfillmentCount = 3
        for trigger: ClaudeTokenRefreshTrigger in [.expired, .enabled, .unauthorized] {
            refresher.refresh(trigger: trigger, bypassCooldown: false) { refreshed in
                XCTAssertTrue(refreshed); done.fulfill()
            }
            if trigger == .expired { XCTAssertEqual(entered.wait(timeout: .now() + 3), .success) }
        }
        fixture.enabled = false
        refresher.enabledChanged(false)
        resume.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(fixture.commands.count, 1)
        XCTAssertTrue(fixture.logs.contains { $0.contains("result=refreshed") })
    }
}
