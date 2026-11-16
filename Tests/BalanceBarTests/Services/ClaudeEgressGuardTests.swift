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
        XCTAssertFalse(editor.emptyLabel.isHidden)
        XCTAssertEqual(editor.visibleRowCount, EgressIPListEditorView.minimumVisibleRows)
        XCTAssertEqual(editor.tableView.tableColumns.map(\.title), [
            tr(.keyDashboardAdvancedPageEgressGuardColumnIp), tr(.keyDashboardAdvancedPageEgressGuardColumnRegion)])
        XCTAssertFalse(editor.isEnabled, "the guard is off by default, so the list is dimmed")
        XCTAssertFalse(section.detectButton.isEnabled)
        editor.setEnabled(true)
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
        XCTAssertEqual(editor.statusLabel.stringValue, tr(.keyDashboardAdvancedPageEgressGuardInvalidIp))
        XCTAssertTrue(editor.emptyLabel.isHidden)

        // Fixing it in place saves it.
        editor.editForTesting(row: 0, text: " 203.0.113.7 ")
        XCTAssertEqual(editor.rows, ["203.0.113.7"])
        XCTAssertEqual(saved.last, ["203.0.113.7"])
        XCTAssertEqual(editor.statusLabel.stringValue, "")

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
        preferences.claudeEgressGuardEnabled = true
        section.refresh(preferences: preferences)
        XCTAssertEqual(editor.rows, ["2001:db8::1"])
        XCTAssertEqual(section.allowedIPsForTesting, ["2001:db8::1"])
        XCTAssertTrue(editor.isEnabled)

        section.detectForTesting()
        detectCompletion?(.failure(.urlError(.timedOut)))
        XCTAssertTrue(waitUntil {
            section.detectDetailForTesting == tr(.keyDashboardAdvancedPageEgressGuardDetectFailed)
        })
        XCTAssertTrue(section.detectButton.isEnabled)

        // Turning the guard off dims the list and its controls.
        preferences.claudeEgressGuardEnabled = false
        section.refresh(preferences: preferences)
        XCTAssertFalse(editor.isEnabled)
        XCTAssertFalse(section.detectButton.isEnabled)
        XCTAssertFalse(editor.actionsControl.isEnabled(forSegment: 0))
        editor.performActionForTesting(segment: 0)
        XCTAssertEqual(editor.rows, ["2001:db8::1"], "+ does nothing while dimmed")
    }

    func testTableGrowsWithRowsUpToSixThenScrolls() {
        let editor = EgressIPListEditorView(ips: [], onSave: { _ in })
        let empty = editor.intrinsicContentSize.height
        editor.updateSavedIPs((1...4).map { "198.51.100.\($0)" })
        XCTAssertEqual(editor.visibleRowCount, 4)
        XCTAssertEqual(editor.intrinsicContentSize.height, empty + 2 * EgressIPListEditorView.rowHeight, accuracy: 0.5)
        editor.updateSavedIPs((1...9).map { "198.51.100.\($0)" })
        XCTAssertEqual(editor.visibleRowCount, EgressIPListEditorView.maximumVisibleRows)
        XCTAssertTrue(editor.scrollView.hasVerticalScroller)
    }

    func testCountryColumnShowsCachedCountryAndLooksUpUnknownOnce() {
        var lookups: [String] = []
        var pending: ((String?) -> Void)?
        var cache: [String: String] = [:]
        let editor = EgressIPListEditorView(
            ips: ["203.0.113.7"],
            cachedCountry: { ip in EgressIPCountryCache.key(for: ip).flatMap { cache[$0] } },
            lookupCountry: { ip, completion in lookups.append(ip); pending = completion },
            onSave: { _ in })
        let loading = tr(.keyDashboardAdvancedPageEgressGuardCountryLoading)
        XCTAssertEqual(editor.countryTextForTesting(row: 0), loading)
        editor.tableView.reloadData()
        XCTAssertEqual(editor.countryTextForTesting(row: 0), loading)
        XCTAssertEqual(lookups, ["203.0.113.7"], "asked once while in flight")
        cache[EgressIPCountryCache.key(for: "203.0.113.7")!] = "JP"
        pending?("JP")
        XCTAssertTrue(waitUntil { editor.countryTextForTesting(row: 0) == IPCountryCode.displayTitle("JP") })

        // Removed (the app prunes its cache) and added again: looked up again, not stuck.
        cache.removeAll()
        editor.selectForTesting(row: 0)
        editor.performActionForTesting(segment: 1)
        editor.append("203.0.113.7")
        XCTAssertEqual(editor.countryTextForTesting(row: 0), loading)
        XCTAssertEqual(lookups.count, 2)

        // A failed lookup shows "—" instead of staying on "Looking up…".
        pending?(nil)
        XCTAssertTrue(waitUntil { editor.countryTextForTesting(row: 0) == "—" })
        XCTAssertEqual(lookups.count, 2, "no retry loop after a failure")
    }

    // MARK: Country lookup

    func testCountryCodeParsingAndDisplay() {
        XCTAssertEqual(IPCountryCode.parse(Data("US\n".utf8)), "US")
        XCTAssertEqual(IPCountryCode.parse(Data("jp".utf8)), "JP")
        XCTAssertNil(IPCountryCode.parse(Data(#"{"ip":"10.0.0.1","bogon":true}"#.utf8)))
        XCTAssertNil(IPCountryCode.parse(Data("U1".utf8)))
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(IPCountryCode.displayTitle("US", locale: english), "🇺🇸 United States")
        XCTAssertEqual(IPCountryCode.displayTitle("HK", locale: Locale(identifier: "zh_CN")), "🇭🇰 中国香港")
        XCTAssertEqual(IPCountryCode.displayTitle("TW", locale: Locale(identifier: "zh_CN")), "中国台湾")
    }

    func testCountryCacheLooksUpOncePersistsAndPrunes() {
        var stored: [String: String] = [:]
        var lookups = 0
        var pending: [(String?) -> Void] = []
        let cache = EgressIPCountryCache(
            load: { stored },
            store: { stored = $0 },
            lookup: { _, completion in lookups += 1; pending.append(completion) })
        var results: [String?] = []
        cache.code(for: "2001:db8::1") { results.append($0) }
        cache.code(for: "2001:DB8:0::1") { results.append($0) }
        XCTAssertEqual(lookups, 1, "two spellings of one address share a lookup")
        pending.removeFirst()(nil)
        XCTAssertEqual(results, [nil, nil])
        XCTAssertTrue(stored.isEmpty, "a failed lookup is not remembered")

        cache.code(for: "2001:db8::1") { results.append($0) }
        XCTAssertEqual(lookups, 2, "a failed lookup is retried")
        pending.removeFirst()("DE")
        XCTAssertEqual(cache.cachedCode(for: "2001:db8:0:0::1"), "DE")
        cache.code(for: "2001:db8::1") { results.append($0) }
        XCTAssertEqual(lookups, 2, "a known address is never looked up again")
        XCTAssertEqual(results.suffix(2), ["DE", "DE"])

        cache.prune(keeping: ["203.0.113.7"])
        XCTAssertTrue(stored.isEmpty)
    }

    func testCountryLookupURL() {
        XCTAssertEqual(OfficialQuotaClient.ipCountryURL(for: "203.0.113.7")?.absoluteString, "https://ipinfo.io/203.0.113.7/country")
        XCTAssertEqual(OfficialQuotaClient.ipCountryURL(for: "2001:db8::1")?.absoluteString, "https://ipinfo.io/2001:db8::1/country")
        XCTAssertNil(OfficialQuotaClient.ipCountryURL(for: "example.com/../x"))
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
