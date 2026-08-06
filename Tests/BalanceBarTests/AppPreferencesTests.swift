import XCTest
@testable import BalanceBar

final class AppPreferencesTests: XCTestCase {
    private func makePreferences() -> (AppPreferences, UserDefaults, String) {
        let suite = "BalanceBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppPreferences(defaults: defaults, defaultStatusLinks: [StatusLink(title: "Default", url: "https://")]), defaults, suite)
    }

    func testDefaultsAndRoundTrip() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertEqual(preferences.activityPollInterval, 0.25)
        preferences.showMenuBarIcon = false
        preferences.activityPollInterval = 2
        XCTAssertFalse(preferences.showMenuBarIcon)
        XCTAssertEqual(preferences.activityPollInterval, 2)
    }

    func testInvalidIntervalsAndStatusLinkNormalization() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-1, forKey: "activityPollInterval")
        defaults.set(try JSONEncoder().encode([StatusLink(title: "A", url: "https://")]), forKey: "statusLinks")
        XCTAssertEqual(preferences.activityPollInterval, 0.25)
        XCTAssertEqual(preferences.statusLinks.first?.url, "")
        let stored = try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        XCTAssertEqual(try JSONDecoder().decode([StatusLink].self, from: stored).first?.url, "")
    }

    func testMigrationIsIdempotentAndPreservesCurrentValues() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ["showMenuBarIcon": false, "activityPollInterval": 4.0] as [String: Any]
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: source, localDomain: [:])
        XCTAssertFalse(preferences.showMenuBarIcon)
        XCTAssertEqual(preferences.activityPollInterval, 4)
        defaults.set(true, forKey: "showMenuBarIcon")
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: ["showMenuBarIcon": false], localDomain: [:])
        XCTAssertTrue(preferences.showMenuBarIcon)
    }
}
