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

    func testBooleanPreferencesDefaultsAndRoundTrips() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(preferences.showMenuBarReset)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertTrue(preferences.showMenuBarAmount)
        XCTAssertTrue(preferences.animateCodexActivity)
        XCTAssertTrue(preferences.showQuickSwitchMenu)
        XCTAssertTrue(preferences.showOpenCCSwitchMenu)
        XCTAssertTrue(preferences.showOpenChatGPTMenu)
        XCTAssertTrue(preferences.showStatusMenu)
        XCTAssertTrue(preferences.keepMenuOpenAfterRefresh)
        XCTAssertFalse(preferences.sortProvidersAlphabetically)
        preferences.showMenuBarReset = false
        preferences.showMenuBarAmount = false
        preferences.animateCodexActivity = false
        preferences.showQuickSwitchMenu = false
        preferences.showOpenCCSwitchMenu = false
        preferences.showOpenChatGPTMenu = false
        preferences.showStatusMenu = false
        preferences.keepMenuOpenAfterRefresh = false
        preferences.sortProvidersAlphabetically = true
        XCTAssertFalse(preferences.showMenuBarReset)
        XCTAssertFalse(preferences.showMenuBarAmount)
        XCTAssertFalse(preferences.animateCodexActivity)
        XCTAssertFalse(preferences.showQuickSwitchMenu)
        XCTAssertFalse(preferences.showOpenCCSwitchMenu)
        XCTAssertFalse(preferences.showOpenChatGPTMenu)
        XCTAssertFalse(preferences.showStatusMenu)
        XCTAssertFalse(preferences.keepMenuOpenAfterRefresh)
        XCTAssertTrue(preferences.sortProvidersAlphabetically)
    }

    func testNumericPreferencesDefaultsBoundsAndRoundTrips() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 3)
        XCTAssertEqual(preferences.postCodexRefreshDuration, 12)
        XCTAssertEqual(preferences.menuBarHorizontalPadding, 10)
        defaults.set(0, forKey: "codexUsageRefreshInterval")
        defaults.set(-1, forKey: "menuBarHorizontalPadding")
        defaults.set(-4, forKey: "postCodexRefreshDuration")
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 3)
        XCTAssertEqual(preferences.menuBarHorizontalPadding, 10)
        XCTAssertEqual(preferences.postCodexRefreshDuration, 0)
        preferences.codexUsageRefreshInterval = 8
        preferences.postCodexRefreshDuration = 5
        preferences.menuBarHorizontalPadding = 14
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 8)
        XCTAssertEqual(preferences.postCodexRefreshDuration, 5)
        XCTAssertEqual(preferences.menuBarHorizontalPadding, 14)
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

    func testDefaultStatusLinksStayIndependentFromPersistedCustomLinks() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = [StatusLink(title: "Custom", url: "https://custom.example")]
        preferences.statusLinks = custom

        XCTAssertEqual(preferences.statusLinks, custom)
        XCTAssertEqual(AppPreferences.makeDefaultStatusLinks().first?.title, "OpenAI Status")
        XCTAssertEqual(AppPreferences.makeDefaultStatusLinks().first?.url, "https://status.openai.com/")
        XCTAssertNotEqual(AppPreferences.makeDefaultStatusLinks(), custom)
    }

    func testDefaultStatusLinksFollowCurrentLanguageProvider() {
        let (_, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        var languageTitle = "English"
        let preferences = AppPreferences(defaults: defaults, defaultStatusLinksProvider: {
            [StatusLink(title: "OpenAI Status", url: "https://status.openai.com/"), StatusLink(title: languageTitle, url: "https://x.com/thsottiaux")]
        })
        XCTAssertEqual(preferences.statusLinks[1].title, "English")
        languageTitle = "Tibo 的动态"
        XCTAssertEqual(preferences.statusLinks[1].title, "Tibo 的动态")
    }

    func testStatusLinksRoundTripAndFallback() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(preferences.statusLinks, [StatusLink(title: "Default", url: "https://")])
        let links = [StatusLink(title: "Custom", url: "https://custom.example")]
        preferences.statusLinks = links
        XCTAssertEqual(preferences.statusLinks, links)
        defaults.removeObject(forKey: "statusLinks")
        XCTAssertEqual(preferences.statusLinks, [StatusLink(title: "Default", url: "https://")])
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
