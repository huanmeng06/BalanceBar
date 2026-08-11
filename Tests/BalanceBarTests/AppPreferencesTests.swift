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

    func testOpenCodexDashboardPortOverridePersistsOnlyValidPorts() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(preferences.openCodexDashboardPortOverride)
        for port in [1, 10100, 65535] {
            preferences.openCodexDashboardPortOverride = port
            XCTAssertEqual(preferences.openCodexDashboardPortOverride, port)
            XCTAssertEqual(
                defaults.integer(forKey: AppPreferences.openCodexDashboardPortOverrideKey),
                port
            )
        }

        preferences.openCodexDashboardPortOverride = 0
        XCTAssertEqual(preferences.openCodexDashboardPortOverride, 65535)
        preferences.openCodexDashboardPortOverride = 65536
        XCTAssertEqual(preferences.openCodexDashboardPortOverride, 65535)
        preferences.openCodexDashboardPortOverride = nil
        XCTAssertNil(preferences.openCodexDashboardPortOverride)
        XCTAssertNil(defaults.object(forKey: AppPreferences.openCodexDashboardPortOverrideKey))
    }

    func testOpenCodexDashboardPortOverrideIgnoresInvalidPersistedNumber() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(65536, forKey: AppPreferences.openCodexDashboardPortOverrideKey)
        XCTAssertNil(preferences.openCodexDashboardPortOverride)
        defaults.set(10100.5, forKey: AppPreferences.openCodexDashboardPortOverrideKey)
        XCTAssertNil(preferences.openCodexDashboardPortOverride)
    }

    func testOpenCodexDashboardAutomaticDetectionDefaultsOnAndPersistsMode() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(preferences.openCodexDashboardAutomaticDetection)
        preferences.openCodexDashboardAutomaticDetection = false
        XCTAssertFalse(preferences.openCodexDashboardAutomaticDetection)
        XCTAssertEqual(
            defaults.object(forKey: AppPreferences.openCodexDashboardAutomaticDetectionKey) as? Bool,
            false
        )

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.openCodexDashboardAutomaticDetection)

        reloaded.openCodexDashboardAutomaticDetection = true
        XCTAssertTrue(reloaded.openCodexDashboardAutomaticDetection)
    }

    func testExistingPortOverrideKeepsManualModeUntilExplicitlyEnabled() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(23456, forKey: AppPreferences.openCodexDashboardPortOverrideKey)
        XCTAssertFalse(preferences.openCodexDashboardAutomaticDetection)
        preferences.openCodexDashboardAutomaticDetection = true
        XCTAssertTrue(preferences.openCodexDashboardAutomaticDetection)
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

    func testLegacyStatusLinksDefaultToEnabledAndAreMigratedOnRead() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyData = Data(
            #"[{"title":"First","url":"https://first.example"},{"title":"Second","url":"https://second.example"}]"#.utf8
        )
        defaults.set(legacyData, forKey: "statusLinks")

        XCTAssertEqual(
            preferences.statusLinks,
            [
                StatusLink(title: "First", url: "https://first.example"),
                StatusLink(title: "Second", url: "https://second.example")
            ]
        )
        let migratedData = try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        let migrated = try JSONDecoder().decode([StatusLink].self, from: migratedData)
        XCTAssertEqual(migrated.map(\.enabled), [true, true])
        XCTAssertNotEqual(migratedData, legacyData)
    }

    func testStatusLinkEnabledStatePersistsAcrossRoundTrip() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let links = [
            StatusLink(title: "Enabled", url: "https://enabled.example"),
            StatusLink(title: "Disabled", url: "https://disabled.example", enabled: false)
        ]

        preferences.statusLinks = links
        XCTAssertEqual(preferences.statusLinks, links)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.statusLinks, links)
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
        let source = [
            "showMenuBarIcon": false,
            "activityPollInterval": 4.0,
            AppPreferences.openCodexDashboardPortOverrideKey: 23456,
            AppPreferences.openCodexDashboardAutomaticDetectionKey: false
        ] as [String: Any]
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: source, localDomain: [:])
        XCTAssertFalse(preferences.showMenuBarIcon)
        XCTAssertEqual(preferences.activityPollInterval, 4)
        XCTAssertEqual(preferences.openCodexDashboardPortOverride, 23456)
        XCTAssertFalse(preferences.openCodexDashboardAutomaticDetection)
        defaults.set(true, forKey: "showMenuBarIcon")
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: ["showMenuBarIcon": false], localDomain: [:])
        XCTAssertTrue(preferences.showMenuBarIcon)
    }
}
