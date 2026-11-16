import Foundation
import XCTest
@testable import BalanceBar

final class ClaudeEgressGuardTests: XCTestCase {
    // MARK: Address normalization

    func testNormalizeAcceptsIPv4AndIPv6WithSurroundingWhitespace() {
        XCTAssertNotNil(EgressIPAddress.normalize("203.0.113.7"))
        XCTAssertEqual(EgressIPAddress.normalize("  203.0.113.7\n"), EgressIPAddress.normalize("203.0.113.7"))
        XCTAssertEqual(
            EgressIPAddress.normalize("2001:db8::1"),
            EgressIPAddress.normalize("2001:0DB8:0000:0000:0000:0000:0000:0001"),
            "compressed and full IPv6 spellings are the same address")
    }

    func testNormalizeRejectsNonAddresses() {
        for text in ["", "   ", "example.com", "203.0.113", "203.0.113.256", "1.2.3.4.5", "fe80::1%en0", "ip=1.2.3.4"] {
            XCTAssertNil(EgressIPAddress.normalize(text), text)
        }
    }

    func testIPv4AndIPv6AreNeverTreatedAsTheSameAddress() {
        XCTAssertFalse(EgressIPAddress.contains(["::ffff:203.0.113.7"], "203.0.113.7"))
        XCTAssertFalse(EgressIPAddress.contains(["203.0.113.7"], "::ffff:203.0.113.7"))
    }

    func testSanitizedListTrimsDropsInvalidAndDeduplicatesByAddress() {
        XCTAssertEqual(
            EgressIPAddress.sanitizedList([" 203.0.113.7 ", "nope", "2001:db8::1", "203.0.113.7", "2001:DB8:0:0::1"]),
            ["203.0.113.7", "2001:db8::1"])
    }

    // MARK: Trace parsing

    func testTraceParserReadsTheIPLine() {
        let body = "fl=12f\nh=claude.ai\nip=198.51.100.23\nts=1700000000.1\nloc=JP\n"
        XCTAssertEqual(CloudflareTraceParser.ip(from: Data(body.utf8)), "198.51.100.23")
        XCTAssertEqual(CloudflareTraceParser.ip(from: Data("h=claude.ai\r\nip=2001:db8::5\r\n".utf8)), "2001:db8::5")
    }

    func testTraceParserRejectsMissingOrInvalidIP() {
        XCTAssertNil(CloudflareTraceParser.ip(from: Data("h=claude.ai\nloc=JP\n".utf8)))
        XCTAssertNil(CloudflareTraceParser.ip(from: Data("ip=not-an-ip\n".utf8)))
        XCTAssertNil(CloudflareTraceParser.ip(from: Data([0xFF, 0xFE])))
    }

    // MARK: Decisions

    private final class Box {
        let lock = NSLock()
        var settings: ClaudeEgressGuardSettings
        var probes = 0
        var pending: [(ClaudeEgressGuard.ProbeResult) -> Void] = []
        var diagnostics: [String] = []
        init(_ settings: ClaudeEgressGuardSettings) { self.settings = settings }
    }

    private func makeGuard(_ box: Box, reply: ClaudeEgressGuard.ProbeResult?) -> ClaudeEgressGuard {
        ClaudeEgressGuard(
            settings: { box.lock.withLock { box.settings } },
            probe: { completion in
                box.lock.withLock { box.probes += 1 }
                if let reply { completion(reply) } else { box.lock.withLock { box.pending.append(completion) } }
            },
            diagnostics: { message in box.lock.withLock { box.diagnostics.append(message) } })
    }

    private func decide(_ egressGuard: ClaudeEgressGuard) -> ClaudeEgressGuardDecision? {
        var decision: ClaudeEgressGuardDecision?
        egressGuard.evaluate { decision = $0 }
        return decision
    }

    func testDisabledBlocksWithoutProbing() {
        let box = Box(.init(enabled: false, allowedIPs: ["203.0.113.7"]))
        XCTAssertEqual(decide(makeGuard(box, reply: .success("203.0.113.7"))), .blocked(.disabled))
        XCTAssertEqual(box.probes, 0)
    }

    func testEnabledWithoutTargetsBlocksWithoutProbing() {
        let box = Box(.init(enabled: true, allowedIPs: ["not-an-ip"]))
        XCTAssertEqual(decide(makeGuard(box, reply: .success("203.0.113.7"))), .blocked(.noTargets))
        XCTAssertEqual(box.probes, 0)
    }

    func testMatchingAnyAllowedIPPasses() {
        let box = Box(.init(enabled: true, allowedIPs: ["198.51.100.1", "2001:db8::1", "203.0.113.7"]))
        XCTAssertEqual(decide(makeGuard(box, reply: .success("203.0.113.7"))), .allowed)
        XCTAssertEqual(decide(makeGuard(box, reply: .success("2001:0db8::0001"))), .allowed)
    }

    func testMismatchAndProbeFailureBlock() {
        let box = Box(.init(enabled: true, allowedIPs: ["203.0.113.7"]))
        XCTAssertEqual(decide(makeGuard(box, reply: .success("198.51.100.9"))), .blocked(.mismatch))
        XCTAssertEqual(decide(makeGuard(box, reply: .failure(.urlError(.timedOut)))), .blocked(.checkFailed))
        XCTAssertEqual(decide(makeGuard(box, reply: .failure(.unknown))), .blocked(.checkFailed))
    }

    func testSettingsChangedDuringProbeAreHonored() {
        let box = Box(.init(enabled: true, allowedIPs: ["203.0.113.7"]))
        let egressGuard = makeGuard(box, reply: nil)
        var decision: ClaudeEgressGuardDecision?
        egressGuard.evaluate { decision = $0 }
        box.lock.withLock { box.settings.enabled = false }
        box.pending.removeFirst()(.success("203.0.113.7"))
        XCTAssertEqual(decision, .blocked(.disabled), "switching the guard off mid-check never lets the request out")
    }

    func testConcurrentEvaluationsShareOneProbe() {
        let box = Box(.init(enabled: true, allowedIPs: ["203.0.113.7"]))
        let egressGuard = makeGuard(box, reply: nil)
        var decisions: [ClaudeEgressGuardDecision] = []
        egressGuard.evaluate { decisions.append($0) }
        egressGuard.evaluate { decisions.append($0) }
        var detected: String?
        egressGuard.currentEgressIP { detected = try? $0.get() }
        XCTAssertEqual(box.probes, 1)
        box.pending.removeFirst()(.success("203.0.113.7"))
        XCTAssertEqual(decisions, [.allowed, .allowed])
        XCTAssertEqual(detected, "203.0.113.7")
        // A later evaluation probes again: results are never cached across requests.
        egressGuard.evaluate { decisions.append($0) }
        XCTAssertEqual(box.probes, 2)
    }

    func testDiagnosticsNeverContainTheAddress() {
        let box = Box(.init(enabled: true, allowedIPs: ["203.0.113.7"]))
        _ = decide(makeGuard(box, reply: .success("198.51.100.9")))
        _ = decide(makeGuard(box, reply: .success("203.0.113.7")))
        XCTAssertEqual(box.diagnostics, ["egress guard; result=mismatch", "egress guard; result=passed"])
        XCTAssertFalse(box.diagnostics.joined().contains("198.51.100.9"))
        XCTAssertFalse(box.diagnostics.joined().contains("203.0.113.7"))
    }

    // MARK: Preferences

    func testPreferencesDefaultOffAndStoreSanitizedIPs() throws {
        let suite = "BalanceBar.EgressGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.claudeEgressGuardSettings, .disabled, "the guard is off, so official requests are off, by default")
        preferences.claudeEgressGuardAllowedIPs = [" 203.0.113.7", "bad", "203.0.113.7", "2001:db8::1"]
        XCTAssertEqual(preferences.claudeEgressGuardAllowedIPs, ["203.0.113.7", "2001:db8::1"])
        XCTAssertEqual(defaults.stringArray(forKey: AppPreferences.claudeEgressGuardAllowedIPsKey), ["203.0.113.7", "2001:db8::1"])
        preferences.claudeEgressGuardEnabled = true
        XCTAssertEqual(preferences.claudeEgressGuardSettings.enabled, true)
    }

    // MARK: Settings section

    func testSettingsSectionValidatesAddsRemovesAndDetects() {
        let suite = "BalanceBar.EgressGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        var saved: [[String]] = []
        var detectCompletion: ((Result<String, OfficialQuotaTransportError>) -> Void)?
        let section = ClaudeEgressGuardSectionController(
            preferences: preferences, relay: DashboardPreferencePageRelay(),
            actions: ClaudeEgressGuardPageActions(
                setAllowedIPs: { saved.append($0) },
                detectEgressIP: { detectCompletion = $0 }))
        _ = section.makeSection()
        let editor = section.listEditor!
        XCTAssertEqual(editor.tableView.numberOfRows, 0)
        XCTAssertEqual(editor.messageLabel.stringValue, tr(.keyDashboardAdvancedPageEgressGuardAllowedEmpty))
        XCTAssertFalse(editor.actionsControl.isEnabled(forSegment: 1), "nothing selected, nothing to remove")

        // "+" adds a blank row; leaving it blank drops it again.
        editor.performActionForTesting(segment: 0)
        XCTAssertEqual(editor.rows, [""])
        editor.editForTesting(row: 0, text: "   ")
        XCTAssertEqual(editor.rows, [])
        XCTAssertTrue(saved.isEmpty)

        // An invalid address stays in the table, flagged, and is never saved.
        editor.performActionForTesting(segment: 0)
        editor.editForTesting(row: 0, text: "example.com")
        XCTAssertEqual(editor.rows, ["example.com"])
        XCTAssertTrue(saved.isEmpty, "an invalid address is never saved")
        XCTAssertEqual(editor.messageLabel.stringValue, tr(.keyDashboardAdvancedPageEgressGuardInvalidIp))

        // Fixing it in place saves it.
        editor.editForTesting(row: 0, text: " 203.0.113.7 ")
        XCTAssertEqual(editor.rows, ["203.0.113.7"])
        XCTAssertEqual(saved.last, ["203.0.113.7"])
        XCTAssertEqual(editor.messageLabel.stringValue, "")

        // A second spelling of a listed address is dropped instead of duplicated.
        editor.performActionForTesting(segment: 0)
        editor.editForTesting(row: 1, text: "203.0.113.7")
        XCTAssertEqual(editor.rows, ["203.0.113.7"])

        section.detectForTesting()
        XCTAssertEqual(section.detectDetailForTesting, tr(.keyDashboardAdvancedPageEgressGuardDetecting))
        detectCompletion?(.success("198.51.100.9"))
        let unlisted = tr(.keyDashboardAdvancedPageEgressGuardDetectedUnlistedValue, arguments: ["198.51.100.9"])
        XCTAssertTrue(waitUntil { section.detectDetailForTesting == unlisted })
        XCTAssertFalse(section.addDetectedButton.isHidden)

        section.addDetectedForTesting()
        XCTAssertEqual(saved.last, ["203.0.113.7", "198.51.100.9"])
        XCTAssertEqual(editor.rows, ["203.0.113.7", "198.51.100.9"])
        XCTAssertTrue(section.addDetectedButton.isHidden)
        XCTAssertEqual(section.detectDetailForTesting,
                       tr(.keyDashboardAdvancedPageEgressGuardDetectedListedValue, arguments: ["198.51.100.9"]))

        // "−" removes the selected row.
        editor.selectForTesting(row: 0)
        XCTAssertTrue(editor.actionsControl.isEnabled(forSegment: 1))
        editor.performActionForTesting(segment: 1)
        XCTAssertEqual(editor.rows, ["198.51.100.9"])
        XCTAssertEqual(saved.last, ["198.51.100.9"])

        // A change saved from the other page copy replaces the table.
        preferences.claudeEgressGuardAllowedIPs = ["2001:db8::1"]
        section.refresh(preferences: preferences)
        XCTAssertEqual(editor.rows, ["2001:db8::1"])
        XCTAssertEqual(section.allowedIPsForTesting, ["2001:db8::1"])

        section.detectForTesting()
        detectCompletion?(.failure(.urlError(.timedOut)))
        XCTAssertTrue(waitUntil {
            section.detectDetailForTesting == tr(.keyDashboardAdvancedPageEgressGuardDetectFailed)
        })
        XCTAssertTrue(section.detectButton.isEnabled)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
