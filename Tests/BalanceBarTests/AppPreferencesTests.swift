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
        XCTAssertTrue(preferences.showOpenCodexMenu)
        XCTAssertTrue(preferences.showOpenChatGPTMenu)
        XCTAssertTrue(preferences.showStatusMenu)
        XCTAssertTrue(preferences.keepMenuOpenAfterRefresh)
        XCTAssertFalse(preferences.sortProvidersAlphabetically)
        preferences.showMenuBarReset = false
        preferences.showMenuBarAmount = false
        preferences.animateCodexActivity = false
        preferences.showQuickSwitchMenu = false
        preferences.showOpenCCSwitchMenu = false
        preferences.showOpenCodexMenu = false
        preferences.showOpenChatGPTMenu = false
        preferences.showStatusMenu = false
        preferences.keepMenuOpenAfterRefresh = false
        preferences.sortProvidersAlphabetically = true
        XCTAssertFalse(preferences.showMenuBarReset)
        XCTAssertFalse(preferences.showMenuBarAmount)
        XCTAssertFalse(preferences.animateCodexActivity)
        XCTAssertFalse(preferences.showQuickSwitchMenu)
        XCTAssertFalse(preferences.showOpenCCSwitchMenu)
        XCTAssertFalse(preferences.showOpenCodexMenu)
        XCTAssertFalse(preferences.showOpenChatGPTMenu)
        XCTAssertFalse(preferences.showStatusMenu)
        XCTAssertFalse(preferences.keepMenuOpenAfterRefresh)
        XCTAssertTrue(preferences.sortProvidersAlphabetically)
    }

    func testUpdateChannelDefaultsPersistsAcrossReloadAndRejectsUnknownValues() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(preferences.updateChannel, .stable)
        preferences.updateChannel = .beta
        XCTAssertEqual(preferences.updateChannel, .beta)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.updateChannelKey), UpdateChannel.beta.rawValue)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.updateChannel, .beta)
        defaults.set("unknown-channel", forKey: AppPreferences.updateChannelKey)
        XCTAssertEqual(reloaded.updateChannel, .stable)
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

    func testBalanceDisplayThresholdDefaultsRoundsAndRejectsInvalidValues() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            preferences.balanceDisplayThreshold,
            AppPreferences.defaultBalanceDisplayThreshold,
            accuracy: 0.000001
        )

        preferences.balanceDisplayThreshold = 0.256
        XCTAssertEqual(preferences.balanceDisplayThreshold, 0.26, accuracy: 0.000001)

        defaults.set(0, forKey: AppPreferences.balanceDisplayThresholdKey)
        XCTAssertEqual(
            preferences.balanceDisplayThreshold,
            AppPreferences.defaultBalanceDisplayThreshold,
            accuracy: 0.000001
        )
        preferences.balanceDisplayThreshold = 0.001
        XCTAssertEqual(
            preferences.balanceDisplayThreshold,
            AppPreferences.defaultBalanceDisplayThreshold,
            accuracy: 0.000001
        )
    }

    func testMenuBarElementOffsetsDefaultRoundTripAndClamp() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(preferences.menuBarIconOffsetX, 0, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarIconOffsetY, 0, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetX, 0, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetY, 0, accuracy: 0.001)

        preferences.menuBarIconOffsetX = 0.3
        preferences.menuBarIconOffsetY = -0.4
        preferences.menuBarAmountOffsetX = 10
        preferences.menuBarAmountOffsetY = -10
        XCTAssertEqual(preferences.menuBarIconOffsetX, 0.3, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarIconOffsetY, -0.4, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetX, 10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetY, -10, accuracy: 0.001)

        preferences.menuBarIconOffsetX = 100
        preferences.menuBarIconOffsetY = -100
        preferences.menuBarAmountOffsetX = 10.06
        preferences.menuBarAmountOffsetY = -10.04
        XCTAssertEqual(preferences.menuBarIconOffsetX, 10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarIconOffsetY, -10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetX, 10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetY, -10, accuracy: 0.001)

        // Repeated 0.1pt steps stay exact after the setter rounds to 0.1.
        preferences.menuBarIconOffsetX = 0
        for _ in 0..<5 {
            preferences.menuBarIconOffsetX += AppPreferences.menuBarOffsetStep
        }
        XCTAssertEqual(preferences.menuBarIconOffsetX, 0.5, accuracy: 0.001)
        preferences.menuBarIconOffsetX = 0.15
        XCTAssertEqual(preferences.menuBarIconOffsetX, 0.2, accuracy: 0.001)

        defaults.set(50, forKey: AppPreferences.menuBarIconOffsetXKey)
        defaults.set(-50, forKey: AppPreferences.menuBarAmountOffsetYKey)
        defaults.set(0.7, forKey: AppPreferences.menuBarIconOffsetYKey)
        XCTAssertEqual(preferences.menuBarIconOffsetX, 10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetY, -10, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarIconOffsetY, 0.7, accuracy: 0.001)
    }

    func testMenuBarStatusItemWidthAdjustmentDefaultsPersistsAndClamps() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(preferences.menuBarStatusItemWidthAdjustment, 0, accuracy: 0.001)
        XCTAssertEqual(
            preferences.menuBarStatusItemWidthAdjustment + AppPreferences.menuBarStatusItemWidthBaseline,
            -20,
            accuracy: 0.001
        )

        preferences.menuBarStatusItemWidthAdjustment = 0.3
        XCTAssertEqual(preferences.menuBarStatusItemWidthAdjustment, 0.3, accuracy: 0.001)
        XCTAssertEqual(
            defaults.double(forKey: AppPreferences.menuBarStatusItemWidthAdjustmentKey),
            0.3,
            accuracy: 0.001
        )

        preferences.menuBarStatusItemWidthAdjustment = 100
        XCTAssertEqual(
            preferences.menuBarStatusItemWidthAdjustment,
            AppPreferences.menuBarStatusItemWidthAdjustmentRange.upperBound,
            accuracy: 0.001
        )
        preferences.menuBarStatusItemWidthAdjustment = -100
        XCTAssertEqual(
            preferences.menuBarStatusItemWidthAdjustment,
            AppPreferences.menuBarStatusItemWidthAdjustmentRange.lowerBound,
            accuracy: 0.001
        )
        preferences.menuBarStatusItemWidthAdjustment = 20
        XCTAssertEqual(
            preferences.menuBarStatusItemWidthAdjustment + AppPreferences.menuBarStatusItemWidthBaseline,
            0,
            accuracy: 0.001
        )

        defaults.set(0.15, forKey: AppPreferences.menuBarStatusItemWidthAdjustmentKey)
        XCTAssertEqual(preferences.menuBarStatusItemWidthAdjustment, 0.2, accuracy: 0.001)
    }

    func testMenuBarStatusItemWidthAdjustmentSessionDoesNotPersistDuringDrag() {
        var session = MenuBarStatusItemWidthAdjustmentSession()

        XCTAssertNil(session.transientValue)
        XCTAssertEqual(session.update(7.44), 7.4, accuracy: 0.001)
        XCTAssertEqual(session.transientValue ?? .nan, 7.4, accuracy: 0.001)

        var persistedValues: [Double] = []
        let finalValue = session.finish(20.06) { persistedValues.append($0) }
        XCTAssertEqual(finalValue, 20, accuracy: 0.001)
        XCTAssertEqual(persistedValues, [20])
        XCTAssertNil(session.transientValue)

        _ = session.update(12.3)
        session.cancel()
        XCTAssertNil(session.transientValue)
    }

    func testMenuBarFontSizePresetsPersistAndPreserveDefaultRatio() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            preferences.menuBarFontSizePreset,
            AppPreferences.menuBarFontSizePresetDefault
        )
        XCTAssertEqual(
            preferences.menuBarFontSize,
            AppPreferences.menuBarFontSizeDefault,
            accuracy: 0.001
        )
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize,
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize / preferences.menuBarFontSize,
            AppPreferences.menuBarSecondaryToPrimaryFontRatio,
            accuracy: 0.000_001
        )

        for preset in MenuBarFontSizePreset.allCases {
            preferences.menuBarFontSizePreset = preset
            XCTAssertEqual(preferences.menuBarFontSizePreset, preset)
            XCTAssertEqual(preferences.menuBarFontSize, preset.primarySize, accuracy: 0.001)
            XCTAssertEqual(preferences.menuBarSecondaryFontSize, preset.secondarySize, accuracy: 0.001)
            XCTAssertEqual(
                preferences.menuBarSecondaryFontSize / preferences.menuBarFontSize,
                AppPreferences.menuBarSecondaryToPrimaryFontRatio,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                defaults.string(forKey: AppPreferences.menuBarFontSizePresetKey),
                preset.rawValue
            )
        }

        preferences.menuBarFontSize = 12.0
        XCTAssertEqual(preferences.menuBarFontSizePreset, .medium)
        XCTAssertEqual(preferences.menuBarFontSize, 11.7, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarSecondaryFontSize, 9.0, accuracy: 0.001)
        XCTAssertEqual(
            defaults.string(forKey: AppPreferences.menuBarFontSizePresetKey),
            MenuBarFontSizePreset.medium.rawValue
        )
        XCTAssertNil(defaults.object(forKey: AppPreferences.menuBarFontSizeKey))
        XCTAssertNil(defaults.object(forKey: AppPreferences.menuBarPrimaryFontSizeKey))
        XCTAssertNil(defaults.object(forKey: AppPreferences.menuBarSecondaryFontSizeKey))

        defaults.removeObject(forKey: AppPreferences.menuBarFontSizePresetKey)
        defaults.removeObject(forKey: AppPreferences.menuBarFontSizeKey)
        defaults.set(14.2, forKey: AppPreferences.menuBarPrimaryFontSizeKey)
        defaults.set(9.6, forKey: AppPreferences.menuBarSecondaryFontSizeKey)
        XCTAssertEqual(preferences.menuBarFontSizePreset, .large)
        XCTAssertEqual(preferences.menuBarFontSize, 13.0, accuracy: 0.001)
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize,
            10.0,
            accuracy: 0.001
        )

        defaults.removeObject(forKey: AppPreferences.menuBarFontSizePresetKey)
        defaults.removeObject(forKey: AppPreferences.menuBarPrimaryFontSizeKey)
        defaults.set(Double.nan, forKey: AppPreferences.menuBarFontSizeKey)
        XCTAssertEqual(
            preferences.menuBarFontSizePreset,
            .small
        )
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
            AppPreferences.updateChannelKey: UpdateChannel.beta.rawValue,
            "showMenuBarIcon": false,
            "activityPollInterval": 4.0,
            AppPreferences.showOpenCodexMenuKey: false,
            AppPreferences.openCodexDashboardPortOverrideKey: 23456,
            AppPreferences.openCodexDashboardAutomaticDetectionKey: false,
            AppPreferences.menuBarFontSizePresetKey: MenuBarFontSizePreset.medium.rawValue,
            AppPreferences.menuBarPrimaryFontSizeKey: 14.2,
            AppPreferences.menuBarSecondaryFontSizeKey: 9.6
        ] as [String: Any]
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: source, localDomain: [:])
        XCTAssertFalse(preferences.showMenuBarIcon)
        XCTAssertEqual(preferences.updateChannel, .beta)
        XCTAssertEqual(preferences.activityPollInterval, 4)
        XCTAssertFalse(preferences.showOpenCodexMenu)
        XCTAssertEqual(preferences.openCodexDashboardPortOverride, 23456)
        XCTAssertFalse(preferences.openCodexDashboardAutomaticDetection)
        XCTAssertEqual(preferences.menuBarFontSizePreset, .medium)
        XCTAssertEqual(preferences.menuBarFontSize, 11.7, accuracy: 0.001)
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize,
            9.0,
            accuracy: 0.001
        )
        defaults.set(true, forKey: "showMenuBarIcon")
        AppPreferencesMigration.migrate(defaults: defaults, bundleIdentifier: suite, productionDomain: ["showMenuBarIcon": false], localDomain: [:])
        XCTAssertTrue(preferences.showMenuBarIcon)
    }
}
