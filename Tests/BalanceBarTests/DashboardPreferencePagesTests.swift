import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardPreferencePagesTests: XCTestCase {
    func testRelayRoutesEachPreferenceActionOnce() {
        let relay = DashboardPreferencePageRelay()
        var calls: [(String, Bool)] = []
        relay.onToggle = { calls.append(($0, $1)) }

        let control = NSSwitch()
        control.identifier = NSUserInterfaceItemIdentifier("showMenuBarAmount")
        control.state = .off
        relay.toggle(control)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "showMenuBarAmount")
        XCTAssertEqual(calls.first?.1, false)
    }

    func testRelayActionCanPersistThroughAppPreferences() {
        let suiteName = "DashboardPreferencePagesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let relay = DashboardPreferencePageRelay()
        relay.onToggle = { identifier, enabled in
            if identifier == "showQuickSwitchMenu" {
                preferences.showQuickSwitchMenu = enabled
            }
        }
        relay.onInterval = { identifier, value in
            if identifier == "codexUsageRefreshInterval" {
                preferences.codexUsageRefreshInterval = value
            }
        }
        relay.onUpdateChannelChanged = { channel in
            preferences.updateChannel = channel
        }

        let toggle = NSSwitch()
        toggle.identifier = NSUserInterfaceItemIdentifier("showQuickSwitchMenu")
        toggle.state = .off
        relay.toggle(toggle)
        let interval = NSPopUpButton()
        interval.identifier = NSUserInterfaceItemIdentifier("codexUsageRefreshInterval")
        interval.addItem(withTitle: "5")
        interval.item(at: 0)?.representedObject = NSNumber(value: 5)
        interval.selectItem(at: 0)
        relay.interval(interval)

        let channel = NSPopUpButton()
        channel.identifier = NSUserInterfaceItemIdentifier(AppPreferences.updateChannelKey)
        channel.addItem(withTitle: "Stable")
        channel.item(at: 0)?.representedObject = UpdateChannel.stable.rawValue
        channel.addItem(withTitle: "Beta Test")
        channel.item(at: 1)?.representedObject = UpdateChannel.beta.rawValue
        channel.selectItem(at: 1)
        relay.updateChannel(channel)

        XCTAssertFalse(preferences.showQuickSwitchMenu)
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 5)
        XCTAssertEqual(preferences.updateChannel, .beta)
    }

    func testBalanceDisplayThresholdRowUsesSelectedCopyAndPersistsValue() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.BalanceDisplayThreshold.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        var changedValues: [Double] = []
        let pageController = DashboardMenuPage()
        let page = pageController.make(.init(
            preferences: preferences,
            relay: DashboardPreferencePageRelay(),
            makeStatusLinksEditor: {
                StatusLinksEditorHostingView(links: [], onChange: { _, _, _ in }, onAdd: {}, onRemove: { _ in }, onReset: {})
            },
            onBalanceDisplayThresholdChanged: { value in
                changedValues.append(value)
                preferences.balanceDisplayThreshold = value
            }
        ))

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.first { $0.stringValue == "余额显示" }?.stringValue, "余额显示")
        XCTAssertEqual(labels.first { $0.stringValue == "低余额显示阈值" }?.stringValue, "低余额显示阈值")
        XCTAssertEqual(
            labels.first { $0.stringValue == "充值后余额仍未达到此金额时，进度条保持红色状态" }?.stringValue,
            "充值后余额仍未达到此金额时，进度条保持红色状态"
        )

        guard let field = descendants(of: page)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == AppPreferences.balanceDisplayThresholdKey }) else {
            return XCTFail("Expected balance display threshold field")
        }
        XCTAssertEqual(field.stringValue, "0.10")

        guard let thresholdRow = field.superview,
        let quickSwitchRow = descendants(of: page)
            .first(where: { view in
                guard let view = view as? NSSwitch else { return false }
                return view.identifier?.rawValue == "showQuickSwitchMenu"
            })?.superview else {
            return XCTFail("Expected both balance display and dropdown-menu rows")
        }
        XCTAssertEqual(
            equalHeightConstraint(in: thresholdRow),
            equalHeightConstraint(in: quickSwitchRow),
            "Balance display row must use the same height as the dropdown-menu rows"
        )
        XCTAssertEqual(
            verticalLabelPadding(in: thresholdRow),
            verticalLabelPadding(in: quickSwitchRow),
            "Balance display row must use the same vertical padding as the dropdown-menu rows"
        )

        field.stringValue = "0.25"
        pageController.controlTextDidEndEditing(
            Notification(name: NSNotification.Name("BalanceBarTests.textDidEndEditing"), object: field)
        )
        XCTAssertEqual(changedValues, [0.25])
        XCTAssertEqual(preferences.balanceDisplayThreshold, 0.25, accuracy: 0.000001)
        XCTAssertEqual(field.stringValue, "0.25")

        field.stringValue = "0"
        pageController.controlTextDidEndEditing(
            Notification(name: NSNotification.Name("BalanceBarTests.textDidEndEditing"), object: field)
        )
        XCTAssertEqual(changedValues, [0.25])
        XCTAssertEqual(field.stringValue, "0.25")
    }

    func testMenuEntryRowsLocalizeSubtitlesAndPreserveControlsAcrossLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, [String], [String])] = [
            (
                .simplifiedChinese,
                ["打开主窗口", "打开 ChatGPT", "打开 CC Switch", "打开 OpenCodex"],
                ["显示 BalanceBar 主窗口", "显示 ChatGPT", "显示 CC Switch 主窗口", "显示 OpenCodex 仪表盘"]
            ),
            (
                .traditionalChinese,
                ["開啟主視窗", "開啟 ChatGPT", "開啟 CC Switch", "開啟 OpenCodex"],
                ["顯示 BalanceBar 主視窗", "顯示 ChatGPT", "顯示 CC Switch 主視窗", "顯示 OpenCodex 儀表板"]
            ),
            (
                .japanese,
                ["メインウインドウを開く", "ChatGPT を開く", "CC Switch を開く", "OpenCodex を開く"],
                ["BalanceBar のメインウインドウを表示", "ChatGPT を表示", "CC Switch のメインウインドウを表示", "OpenCodex ダッシュボードを表示"]
            ),
            (
                .english,
                ["Open Main Window", "Open ChatGPT", "Open CC Switch", "Open OpenCodex"],
                ["Show the BalanceBar main window", "Show ChatGPT", "Show the CC Switch main window", "Show the OpenCodex dashboard"]
            )
        ]

        for (language, expectedTitles, expectedSubtitles) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuEntryRows.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = AppPreferences(defaults: defaults)
            preferences.showOpenChatGPTMenu = false
            preferences.showOpenCCSwitchMenu = true
            preferences.showOpenCodexMenu = false
            let relay = DashboardPreferencePageRelay()
            let page = DashboardMenuPage().make(.init(
                preferences: preferences,
                relay: relay,
                makeStatusLinksEditor: {
                    StatusLinksEditorHostingView(links: [], onChange: { _, _, _ in }, onAdd: {}, onRemove: { _ in }, onReset: {})
                },
                onBalanceDisplayThresholdChanged: { _ in }
            ))

            let labels = descendants(of: page).compactMap { $0 as? NSTextField }
            let labelStrings = labels.map(\.stringValue)
            for title in expectedTitles {
                XCTAssertTrue(labelStrings.contains(title), "localized title \(title) for \(language)")
            }
            for (title, subtitle) in zip(expectedTitles, expectedSubtitles) {
                guard let subtitleLabel = labels.first(where: { $0.stringValue == subtitle }) else {
                    return XCTFail("Expected localized subtitle \(subtitle) for \(language)")
                }
                XCTAssertFalse(subtitleLabel.isHidden)
                guard let row = subtitleLabel.superview?.superview else {
                    return XCTFail("Expected row for localized subtitle \(subtitle) for \(language)")
                }
                XCTAssertEqual(nonEmptyTextFields(in: row), [title, subtitle])
                XCTAssertEqual(equalHeightConstraint(in: row), 62)
            }

            let legacySubtitles = [
                "balance bar", "顯示CC switch 主面板",
                "显示ChatGPT", "显示CC switch 主面板",
                "CC Switch のメインパネルを表示",
                "显示 ChatGPT 启动项", "Show the ChatGPT launch item", "顯示 ChatGPT 啟動項目", "ChatGPT 起動項目を表示",
                "显示 CC Switch 启动项", "Show the CC Switch launch item", "顯示 CC Switch 啟動項目", "CC Switch 起動項目を表示",
                "显示 OpenCodex 启动项", "Show the OpenCodex launch item", "顯示 OpenCodex 啟動項目", "OpenCodex 起動項目を表示"
            ]
            XCTAssertTrue(
                legacySubtitles.allSatisfy { !labelStrings.contains($0) },
                "legacy menu-entry copy for \(language)"
            )

            let expectedControls: [(String, NSSwitch.StateValue, Bool)] = [
                ("showOpenDashboardMenu", .on, false),
                ("showOpenChatGPTMenu", .off, true),
                ("showOpenCCSwitchMenu", .on, true),
                (AppPreferences.showOpenCodexMenuKey, .off, true)
            ]
            let switches = descendants(of: page).compactMap { $0 as? NSSwitch }
            for (identifier, state, isEnabled) in expectedControls {
                guard let control = switches.first(where: { $0.identifier?.rawValue == identifier }) else {
                    return XCTFail("Expected menu-entry switch \(identifier) for \(language)")
                }
                XCTAssertEqual(control.state, state, "state for \(identifier) in \(language)")
                XCTAssertEqual(control.isEnabled, isEnabled, "enabled state for \(identifier) in \(language)")
                XCTAssertTrue(control.target === relay, "relay target for \(identifier) in \(language)")
                XCTAssertEqual(control.action, #selector(DashboardPreferencePageRelay.toggle(_:)))
            }
        }
    }

    func testMenuBarPreviewPresentationUsesSharedSnapshotValues() {
        let snapshot = Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1))
        let presentation = DashboardMenuBarPage.presentation(
            for: snapshot,
            showAmount: true,
            showReset: true,
            resolving: { $0 }
        )

        XCTAssertEqual(presentation.primary, snapshot.menuBarPrimary)
        XCTAssertEqual(presentation.secondary, snapshot.menuBarSecondary)
        XCTAssertTrue(presentation.hasSecondary)
        XCTAssertFalse(presentation.isBalance)
    }

    func testMenuBarOverflowWarningUsesInjectedVisibilityAndFourLocalizations() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "菜单栏空间不足，BalanceBar 暂时不可见；请关闭或移除部分菜单栏图标后重试。", "打开设置"),
            (.english, "Menu bar space is full, so BalanceBar is temporarily hidden; hide or remove some menu bar icons and try again.", "Open Settings"),
            (.traditionalChinese, "選單列空間不足，BalanceBar 暫時不可見；請關閉或移除部分選單列圖示後重試。", "開啟設定"),
            (.japanese, "メニューバーの空き容量が不足しているためBalanceBarは一時的に非表示です。ほかのメニューバーアイコンを隠すか削除してから再試行してください。", "設定を開く")
        ]
        XCTAssertEqual(
            DashboardMenuBarPage.systemMenuBarSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
        )

        for (language, expectedText, expectedButtonTitle) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuBarOverflowWarning.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let controller = DashboardMenuBarPage()
            let relay = DashboardPreferencePageRelay()
            var openCount = 0
            relay.onOpenSystemMenuBarSettings = { openCount += 1 }
            let page = controller.make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: relay,
                statusItemVisibility: .hiddenByMenuBarSpace
            ))
            let warningLabel = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.overflowWarningIdentifier }
            )
            let warningRow = try XCTUnwrap(
                descendants(of: page)
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.overflowWarningRowIdentifier }
            )

            XCTAssertEqual(warningLabel.stringValue, expectedText)
            XCTAssertFalse(warningLabel.isHidden)
            XCTAssertFalse(warningRow.isHidden)
            XCTAssertTrue(warningLabel.usesSingleLineMode)
            XCTAssertEqual(warningLabel.maximumNumberOfLines, 1)
            XCTAssertEqual(warningLabel.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(warningLabel.font?.pointSize ?? .nan, 12, accuracy: 0.001)
            let warningRowHeight = try XCTUnwrap(
                warningRow.constraints.first {
                    $0.firstAttribute == .height && $0.relation == .equal
                }?.constant
            )
            XCTAssertEqual(warningRowHeight, DashboardMenuBarPage.previewRowHeight)

            let settingsButton = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSButton }
                    .first {
                        $0.identifier?.rawValue == DashboardMenuBarPage.overflowWarningSettingsButtonIdentifier
                    }
            )
            XCTAssertEqual(settingsButton.title, expectedButtonTitle)
            XCTAssertEqual(settingsButton.bezelStyle, .rounded)
            XCTAssertEqual(settingsButton.controlSize, .regular)
            XCTAssertEqual(
                settingsButton.action,
                #selector(DashboardPreferencePageRelay.openSystemMenuBarSettings(_:))
            )
            XCTAssertTrue(settingsButton.target === relay)
            XCTAssertFalse(settingsButton.superview?.isHidden ?? true)
            settingsButton.performClick(nil)
            XCTAssertEqual(openCount, 1)

            let snapshot = Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1))
            controller.refresh(
                snapshot: snapshot,
                preferences: AppPreferences(defaults: defaults),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                statusItemVisibility: .visible
            )
            XCTAssertTrue(warningLabel.isHidden)
            XCTAssertTrue(warningRow.isHidden)
            XCTAssertTrue(settingsButton.superview?.isHidden ?? false)

            controller.refresh(
                snapshot: snapshot,
                preferences: AppPreferences(defaults: defaults),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                statusItemVisibility: .unknown
            )
            XCTAssertTrue(warningLabel.isHidden)
            XCTAssertTrue(warningRow.isHidden)
            XCTAssertTrue(settingsButton.superview?.isHidden ?? false)
        }
    }

    func testCodexActivityAnimationBelongsToMenuBarWithLocalizedSectionOrder() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "动画", "任务进行时播放图标动画"),
            (.english, "Animation", "Play the icon animation while a task is running"),
            (.traditionalChinese, "動畫", "任務進行時播放圖示動畫"),
            (.japanese, "アニメーション", "タスク実行中にアイコンアニメーションを再生")
        ]

        for (language, animationSectionTitle, animationRowTitle) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.CodexActivityAnimation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let preferences = AppPreferences(defaults: defaults)
            let menuBarPage = DashboardMenuBarPage().make(.init(
                preferences: preferences,
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))

            let labels = descendants(of: menuBarPage).compactMap { $0 as? NSTextField }
            let labelStrings = labels.map(\.stringValue)
            guard let previewIndex = labelStrings.firstIndex(of: tr("预览", "Preview", "預覽", "プレビュー", language: language)),
                  let animationIndex = labelStrings.firstIndex(of: animationSectionTitle),
                  let displayIndex = labelStrings.firstIndex(of: tr("显示项目", "Display Items", "顯示項目", "表示項目", language: language)) else {
                defaults.removePersistentDomain(forName: suiteName)
                return XCTFail("Expected menu bar section headings for \(language)")
            }
            XCTAssertLessThan(previewIndex, animationIndex)
            XCTAssertLessThan(animationIndex, displayIndex)
            XCTAssertEqual(labelStrings.filter { $0 == animationSectionTitle }.count, 1)
            XCTAssertEqual(labelStrings.filter { $0 == animationRowTitle }.count, 1)

            let animationSwitches = descendants(of: menuBarPage)
                .compactMap { $0 as? NSSwitch }
                .filter { $0.identifier?.rawValue == "animateCodexActivity" }
            XCTAssertEqual(animationSwitches.count, 1)

            let mode = OpenCodexDashboardMode(automaticDetection: true, manualPort: nil)
            let advancedPage = DashboardAdvancedPage().make(.init(
                preferences: preferences,
                mode: mode,
                currentResolution: OpenCodexDashboardResolver.resolve(manualPort: nil, runtimeCandidate: nil),
                runtimeCandidate: nil,
                relay: DashboardPreferencePageRelay(),
                logViewer: NSView(),
                onModeChanged: { _ in },
                onClamp: {}
            ))
            let advancedLabels = descendants(of: advancedPage).compactMap { $0 as? NSTextField }
            XCTAssertFalse(advancedLabels.contains { $0.stringValue == tr("任务状态", "Task Status", "任務狀態", "タスクステータス", language: language) })
            XCTAssertTrue(
                descendants(of: advancedPage)
                    .compactMap { $0 as? NSSwitch }
                    .filter { $0.identifier?.rawValue == "animateCodexActivity" }
                    .isEmpty
            )
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testCodexActivityAnimationRelayPersistsTheExistingPreference() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.CodexActivityAnimation.Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.animateCodexActivity)
        let relay = DashboardPreferencePageRelay()
        relay.onToggle = { identifier, enabled in
            guard identifier == "animateCodexActivity" else { return }
            preferences.animateCodexActivity = enabled
        }
        let page = DashboardMenuBarPage().make(.init(
            preferences: preferences,
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))
        let animationSwitches = descendants(of: page)
            .compactMap { $0 as? NSSwitch }
            .filter { $0.identifier?.rawValue == "animateCodexActivity" }
        XCTAssertEqual(animationSwitches.count, 1)
        let animationSwitch = try XCTUnwrap(animationSwitches.first)
        XCTAssertEqual(animationSwitch.state, .on)

        animationSwitch.state = .off
        relay.toggle(animationSwitch)
        XCTAssertFalse(preferences.animateCodexActivity)
        XCTAssertFalse(AppPreferences(defaults: defaults).animateCodexActivity)

        let reloadedPage = DashboardMenuBarPage().make(.init(
            preferences: AppPreferences(defaults: defaults),
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        XCTAssertEqual(
            try XCTUnwrap(
                descendants(of: reloadedPage)
                    .compactMap { $0 as? NSSwitch }
                    .first { $0.identifier?.rawValue == "animateCodexActivity" }
            ).state,
            .off
        )
    }

    func testRelayRoutesOffsetAdjustAndResetOnce() {
        let relay = DashboardPreferencePageRelay()
        var adjustments: [(String, Int)] = []
        var values: [(String, Double)] = []
        var endedValues: [(String, Double)] = []
        var resets: [String] = []
        relay.onOffsetAdjust = { identifier, delta in adjustments.append((identifier, delta)) }
        relay.onOffsetValue = { identifier, value in values.append((identifier, value)) }
        relay.onOffsetValueEnded = { identifier, value in endedValues.append((identifier, value)) }
        relay.onOffsetReset = { identifier in resets.append(identifier) }

        let up = NSButton(
            title: "Up",
            target: relay,
            action: #selector(DashboardPreferencePageRelay.adjustOffset(_:))
        )
        up.identifier = NSUserInterfaceItemIdentifier(AppPreferences.menuBarIconOffsetYKey)
        up.tag = 1
        relay.adjustOffset(up)

        let left = NSButton(
            title: "Left",
            target: relay,
            action: #selector(DashboardPreferencePageRelay.adjustOffset(_:))
        )
        left.identifier = NSUserInterfaceItemIdentifier(AppPreferences.menuBarAmountOffsetXKey)
        left.tag = -1
        relay.adjustOffset(left)

        let widthSlider = NSSlider()
        widthSlider.identifier = NSUserInterfaceItemIdentifier(
            AppPreferences.menuBarStatusItemWidthAdjustmentKey
        )
        widthSlider.minValue = AppPreferences.menuBarStatusItemWidthAdjustmentRange.lowerBound
        widthSlider.maxValue = AppPreferences.menuBarStatusItemWidthAdjustmentRange.upperBound
        widthSlider.doubleValue = 7.3
        relay.adjustOffsetValue(widthSlider)
        relay.finishOffsetValue(widthSlider)

        let reset = NSButton(
            title: "Reset",
            target: relay,
            action: #selector(DashboardPreferencePageRelay.resetOffset(_:))
        )
        reset.identifier = NSUserInterfaceItemIdentifier(DashboardMenuBarPage.iconOffsetsResetIdentifier)
        relay.resetOffset(reset)

        XCTAssertEqual(adjustments.count, 2)
        XCTAssertEqual(adjustments[0].0, AppPreferences.menuBarIconOffsetYKey)
        XCTAssertEqual(adjustments[0].1, 1)
        XCTAssertEqual(adjustments[1].0, AppPreferences.menuBarAmountOffsetXKey)
        XCTAssertEqual(adjustments[1].1, -1)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.0, AppPreferences.menuBarStatusItemWidthAdjustmentKey)
        XCTAssertEqual(values.first?.1 ?? .nan, 7.3, accuracy: 0.001)
        XCTAssertEqual(endedValues.count, 1)
        XCTAssertEqual(endedValues.first?.0, AppPreferences.menuBarStatusItemWidthAdjustmentKey)
        XCTAssertEqual(endedValues.first?.1 ?? .nan, 7.3, accuracy: 0.001)
        XCTAssertEqual(resets, [DashboardMenuBarPage.iconOffsetsResetIdentifier])
    }

    func testMenuBarWidthSliderIdentifiesIntegerBoundariesInBothDirections() {
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: 0.2,
                to: 3.4,
                minimum: -10,
                maximum: 10
            ),
            [1, 2, 3]
        )
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: 3.4,
                to: 0.2,
                minimum: -10,
                maximum: 10
            ),
            [3, 2, 1]
        )
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: 1.0,
                to: 1.8,
                minimum: -10,
                maximum: 10
            ),
            []
        )
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: 0.8,
                to: 1.0,
                minimum: -10,
                maximum: 10
            ),
            [1]
        )
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: -0.2,
                to: 0.1,
                minimum: -10,
                maximum: 10
            ),
            [0]
        )
        XCTAssertEqual(
            MenuBarWidthSlider.integerValuesCrossed(
                from: -9.4,
                to: -10.0,
                minimum: -10,
                maximum: 10
            ),
            [-10]
        )
    }

    func testMenuBarTypographyAndPositionSectionRendersControlsAndPreviewOffsets() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.MenuBarFineTune.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.menuBarIconOffsetX = 0.2
        preferences.menuBarIconOffsetY = -0.3
        preferences.menuBarAmountOffsetX = -0.4
        preferences.menuBarAmountOffsetY = 0.5
        preferences.menuBarStatusItemWidthAdjustment = 0.6
        let relay = DashboardPreferencePageRelay()
        relay.onOffsetAdjust = { identifier, delta in
            let pointDelta = Double(delta) * AppPreferences.menuBarOffsetStep
            switch identifier {
            case AppPreferences.menuBarIconOffsetXKey:
                preferences.menuBarIconOffsetX += pointDelta
            case AppPreferences.menuBarIconOffsetYKey:
                preferences.menuBarIconOffsetY += pointDelta
            case AppPreferences.menuBarAmountOffsetXKey:
                preferences.menuBarAmountOffsetX += pointDelta
            case AppPreferences.menuBarAmountOffsetYKey:
                preferences.menuBarAmountOffsetY += pointDelta
            case AppPreferences.menuBarStatusItemWidthAdjustmentKey:
                preferences.menuBarStatusItemWidthAdjustment += pointDelta
            default:
                break
            }
        }
        relay.onOffsetValue = { identifier, value in
            switch identifier {
            case AppPreferences.menuBarIconOffsetYKey:
                preferences.menuBarIconOffsetY = value
            case AppPreferences.menuBarAmountOffsetYKey:
                preferences.menuBarAmountOffsetY = value
            case AppPreferences.menuBarStatusItemWidthAdjustmentKey:
                preferences.menuBarStatusItemWidthAdjustment = value
            default:
                break
            }
        }
        let controller = DashboardMenuBarPage()
        let snapshot = Snapshot.balance("Provider", 12.34, "USD", nil, Date(timeIntervalSince1970: 1))
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: snapshot,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))

        let buttons = descendants(of: page).compactMap { $0 as? NSButton }
        let iconXButtons = buttons.filter { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetXKey }
        let amountXButtons = buttons.filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetXKey }
        XCTAssertTrue(iconXButtons.isEmpty)
        let sliders = descendants(of: page).compactMap { $0 as? NSSlider }
        guard let widthSlider = sliders.first(where: {
            $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey
        }) else {
            return XCTFail("Expected a status item width slider")
        }
        guard let iconOffsetSlider = sliders.first(where: {
            $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetYKey
        }), let amountOffsetSlider = sliders.first(where: {
            $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetYKey
        }) else {
            return XCTFail("Expected icon and amount offset sliders")
        }
        XCTAssertTrue(amountXButtons.isEmpty)
        XCTAssertTrue(iconOffsetSlider is MenuBarWidthSlider)
        XCTAssertTrue(amountOffsetSlider is MenuBarWidthSlider)
        for offsetSlider in [iconOffsetSlider, amountOffsetSlider] {
            XCTAssertEqual(
                offsetSlider.minValue,
                AppPreferences.menuBarOffsetRange.lowerBound,
                accuracy: 0.001
            )
            XCTAssertEqual(
                offsetSlider.maxValue,
                AppPreferences.menuBarOffsetRange.upperBound,
                accuracy: 0.001
            )
            XCTAssertTrue(offsetSlider.isContinuous)
            XCTAssertFalse(offsetSlider.allowsTickMarkValuesOnly)
            XCTAssertEqual(offsetSlider.numberOfTickMarks, 21)
            if #available(macOS 26.0, *) {
                XCTAssertEqual(offsetSlider.neutralValue, 0, accuracy: 0.001)
            }
        }
        XCTAssertEqual(iconOffsetSlider.doubleValue, -0.3, accuracy: 0.001)
        XCTAssertEqual(amountOffsetSlider.doubleValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(
            widthSlider.minValue,
            AppPreferences.menuBarStatusItemWidthAdjustmentRange.lowerBound,
            accuracy: 0.001
        )
        XCTAssertEqual(
            widthSlider.maxValue,
            AppPreferences.menuBarStatusItemWidthAdjustmentRange.upperBound,
            accuracy: 0.001
        )
        XCTAssertEqual(widthSlider.doubleValue, 0.6, accuracy: 0.001)
        XCTAssertTrue(widthSlider is MenuBarWidthSlider)
        XCTAssertTrue(widthSlider.isContinuous)
        XCTAssertFalse(widthSlider.allowsTickMarkValuesOnly)
        XCTAssertEqual(widthSlider.numberOfTickMarks, 21)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(
                widthSlider.neutralValue,
                0,
                accuracy: 0.001
            )
        }
        XCTAssertEqual(
            widthSlider.constraints.first(where: { $0.firstAttribute == .width })?.constant ?? .nan,
            DashboardMenuBarPage.widthAdjustmentSliderWidth,
            accuracy: 0.001
        )
        let widthMinimumLabel = descendants(of: page)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSliderMinimumIdentifier }
        let widthMaximumLabel = descendants(of: page)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSliderMaximumIdentifier }
        XCTAssertEqual(widthMinimumLabel?.stringValue, "窄")
        XCTAssertEqual(widthMaximumLabel?.stringValue, "宽")
        XCTAssertFalse(buttons.contains {
            $0.identifier?.rawValue == "menuBarStatusItemWidthAdjustmentReset"
        })
        XCTAssertEqual(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSliderMinimumIdentifier }?.stringValue,
            "下"
        )
        XCTAssertEqual(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSliderMaximumIdentifier }?.stringValue,
            "上"
        )
        XCTAssertEqual(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSliderMinimumIdentifier }?.stringValue,
            "下"
        )
        XCTAssertEqual(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSliderMaximumIdentifier }?.stringValue,
            "上"
        )

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        let iconSummary = labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSummaryIdentifier }
        let amountSummary = labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSummaryIdentifier }
        XCTAssertEqual(iconSummary?.stringValue, "微调图标上下像素位置：Y 轴 - 0.3 pt")
        XCTAssertEqual(amountSummary?.stringValue, "微调金额上下像素位置：Y 轴 + 0.5 pt")
        XCTAssertEqual(
            labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSummaryIdentifier }?.stringValue,
            "调整 BalanceBar 与其他项目的空隙：宽度 + 0.6 pt"
        )
        let labelStrings = labels.map(\.stringValue)
        XCTAssertTrue(labelStrings.contains("字号与位置"))
        XCTAssertFalse(labelStrings.contains("字号"))
        XCTAssertFalse(labelStrings.contains("细节微调"))
        XCTAssertTrue(labelStrings.contains("调整菜单栏字体大小"))
        let rowTitles = ["菜单栏字号", "图标偏移", "金额偏移", "菜单栏宽度"]
        let rowIndices = rowTitles.compactMap { labelStrings.firstIndex(of: $0) }
        XCTAssertEqual(rowIndices.count, rowTitles.count)
        XCTAssertEqual(rowIndices, rowIndices.sorted())
        XCTAssertFalse(labelStrings.contains("10.4 / 8.0 pt"))

        let previewIcon = descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewIcon" }
        let previewText = descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewText" }
        page.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        page.layoutSubtreeIfNeeded()
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        page.layoutSubtreeIfNeeded()
        let previewIconX = previewIcon?.layer?.affineTransform().tx ?? CGFloat.nan
        let previewTextX = previewText?.layer?.affineTransform().tx ?? CGFloat.nan
        XCTAssertEqual(previewIconX - previewTextX, 0.6, accuracy: 0.001)
        // The same automatic centering compensation is applied to both
        // components; it must not consume their explicit relative offsets.
        XCTAssertEqual(previewIconX - 0.2, previewTextX - (-0.4), accuracy: 0.001)
        XCTAssertEqual(
            previewIcon?.layer?.affineTransform().ty ?? CGFloat.nan,
            -0.3 + MenuBarLayout.singleLineIconYOffset,
            accuracy: 0.001
        )
        let previewPrimary = try! XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewPrimaryIdentifier
            } as? NSTextField
        )
        let previewBackground = try! XCTUnwrap(previewBackgroundAncestor(of: previewPrimary))
        let primaryInk = try! XCTUnwrap(
            MenuBarLayout.appKitRenderedTextBounds(
                for: previewPrimary,
                frameSize: previewPrimary.bounds.size
            )
        )
        let renderedPrimaryInk = primaryInk
            .offsetBy(
                dx: previewPrimary.convert(primaryInk, to: previewBackground).minX - primaryInk.minX
                    + (previewText?.layer?.affineTransform().tx ?? 0),
                dy: previewPrimary.convert(primaryInk, to: previewBackground).minY - primaryInk.minY
                    + (previewText?.layer?.affineTransform().ty ?? 0)
            )
        XCTAssertEqual(
            renderedPrimaryInk.midY,
            previewBackground.bounds.midY
                + preferences.menuBarAmountOffsetY
                + MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                    fontSize: CGFloat(preferences.menuBarFontSizePreset.primarySize)
                ),
            accuracy: 0.5
        )

        widthSlider.doubleValue = 0.7
        relay.adjustOffsetValue(widthSlider)
        XCTAssertEqual(preferences.menuBarStatusItemWidthAdjustment, 0.7, accuracy: 0.001)
        iconOffsetSlider.doubleValue = 0.7
        relay.adjustOffsetValue(iconOffsetSlider)
        amountOffsetSlider.doubleValue = -0.8
        relay.adjustOffsetValue(amountOffsetSlider)
        XCTAssertEqual(preferences.menuBarIconOffsetY, 0.7, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarAmountOffsetY, -0.8, accuracy: 0.001)
        preferences.showMenuBarIcon = false
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        let refreshedButtons = descendants(of: page).compactMap { $0 as? NSButton }
        let refreshedSliders = descendants(of: page).compactMap { $0 as? NSSlider }
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetXKey }
            .isEmpty)
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetYKey }
            .allSatisfy { !$0.isEnabled })
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetXKey }
            .isEmpty)
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetYKey }
            .allSatisfy { $0.isEnabled })
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey }
            .allSatisfy { $0.isEnabled })

        preferences.menuBarIconOffsetY = 0.7
        preferences.menuBarAmountOffsetY = -0.8
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        let refreshedLabels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertEqual(
            refreshedLabels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSummaryIdentifier }?.stringValue,
            "微调图标上下像素位置：Y 轴 + 0.7 pt"
        )
        XCTAssertEqual(
            refreshedLabels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSummaryIdentifier }?.stringValue,
            "微调金额上下像素位置：Y 轴 - 0.8 pt"
        )
        XCTAssertEqual(
            refreshedSliders.first { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetYKey }?.doubleValue ?? .nan,
            0.7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            refreshedSliders.first { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetYKey }?.doubleValue ?? .nan,
            -0.8,
            accuracy: 0.001
        )
    }

    func testMenuBarFontSizePresetControlKeepsDefaultRatioAndRefreshesPreview() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.MenuBarFontSize.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.menuBarFontSizePreset = .medium
        let relay = DashboardPreferencePageRelay()
        relay.onOffsetValue = { identifier, value in
            guard identifier == AppPreferences.menuBarFontSizePresetKey,
                  let preset = MenuBarFontSizePreset(segmentIndex: Int(value.rounded())) else {
                return
            }
            preferences.menuBarFontSizePreset = preset
        }
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))

        let popupControls = descendants(of: page).compactMap { $0 as? NSPopUpButton }
        let fontPresetControls = popupControls.filter {
            $0.identifier?.rawValue == AppPreferences.menuBarFontSizePresetKey
        }
        XCTAssertEqual(fontPresetControls.count, 1)
        let fontPresetControl = try XCTUnwrap(fontPresetControls.first)
        let fontPresetWidthConstraint = try XCTUnwrap(fontPresetControl.constraints.first {
            $0.firstAttribute == .width && $0.relation == .equal
        })
        XCTAssertEqual(fontPresetWidthConstraint.constant, DashboardMenuBarPage.fontSizePresetWidth, accuracy: 0.001)
        XCTAssertEqual(
            (fontPresetControl.selectedItem?.representedObject as? NSNumber)?.intValue,
            MenuBarFontSizePreset.medium.segmentIndex
        )
        XCTAssertEqual(
            fontPresetControl.numberOfItems,
            MenuBarFontSizePreset.allCases.count
        )
        XCTAssertEqual(fontPresetControl.itemTitle(at: 0), "Large")
        XCTAssertEqual(fontPresetControl.itemTitle(at: 1), "Medium")
        XCTAssertEqual(fontPresetControl.itemTitle(at: 2), "Small")
        XCTAssertTrue(popupControls.allSatisfy {
            $0.identifier?.rawValue != AppPreferences.menuBarPrimaryFontSizeKey
                && $0.identifier?.rawValue != AppPreferences.menuBarSecondaryFontSizeKey
        })
        XCTAssertTrue(fontPresetControl.toolTip?.contains("11.7/9") == true)

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "Font Size & Position" })
        XCTAssertTrue(labels.contains { $0.stringValue == "Menu Bar Font Size" })
        XCTAssertTrue(labels.contains { $0.stringValue == "Adjusts the menu bar font size" })
        XCTAssertFalse(labels.contains { $0.stringValue == "11.7 / 9.0 pt" })

        let previewPrimary = try XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewPrimaryIdentifier
            } as? NSTextField
        )
        let previewSecondary = try XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewSecondaryIdentifier
            } as? NSTextField
        )
        XCTAssertEqual(previewPrimary.font?.pointSize ?? .nan, 11.7, accuracy: 0.001)
        XCTAssertEqual(
            previewSecondary.font?.pointSize ?? .nan,
            9.0,
            accuracy: 0.001
        )
        XCTAssertEqual(previewPrimary.frame.minX, previewSecondary.frame.minX, accuracy: 0.001)
        XCTAssertEqual(previewPrimary.frame.width, previewSecondary.frame.width, accuracy: 0.001)

        fontPresetControl.selectItem(at: MenuBarFontSizePreset.small.segmentIndex)
        relay.selectMenuBarFontSizePreset(fontPresetControl)
        XCTAssertEqual(preferences.menuBarFontSizePreset, .small)
        XCTAssertEqual(preferences.menuBarFontSize, 10.4, accuracy: 0.001)
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize,
            8.0,
            accuracy: 0.001
        )
        XCTAssertFalse(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .contains { $0.title == "Default" },
            "The font-size section should only expose the native preset popup"
        )

        controller.refresh(
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        XCTAssertEqual(fontPresetControl.indexOfSelectedItem, MenuBarFontSizePreset.small.segmentIndex)

        preferences.showMenuBarAmount = false
        controller.refresh(
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        let refreshedFontPresetControl = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == AppPreferences.menuBarFontSizePresetKey }
        )
        XCTAssertFalse(refreshedFontPresetControl.isEnabled)
    }

    func testMenuBarWidthOnlyRefreshUpdatesSummaryWithoutFightingSlider() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.MenuBarWidthOnlyRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: .balance("Provider", 12.34, "USD", nil, Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))

        controller.refreshWidthAdjustment(7.4, horizontalPadding: 10)

        let slider = descendants(of: page)
            .compactMap { $0 as? NSSlider }
            .first { $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey }
        let summary = descendants(of: page)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSummaryIdentifier }
        XCTAssertEqual(
            slider?.doubleValue ?? .nan,
            AppPreferences.menuBarStatusItemWidthAdjustmentDefault,
            accuracy: 0.001
        )
        XCTAssertEqual(summary?.stringValue, "调整 BalanceBar 与其他项目的空隙：宽度 + 7.4 pt")

        controller.finishWidthAdjustment(7.4, horizontalPadding: 10)
        XCTAssertEqual(slider?.doubleValue ?? .nan, 7.4, accuracy: 0.001)
    }

    func testMenuBarWidthTransientRefreshDoesNotFightSliderTracking() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.MenuBarWidthTransientRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: .balance("Provider", 12.34, "USD", nil, Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        guard let slider = descendants(of: page)
            .compactMap({ $0 as? NSSlider })
            .first(where: { $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey })
        else {
            return XCTFail("Expected width slider")
        }

        slider.doubleValue = 4.2
        controller.refreshWidthAdjustment(7.4, horizontalPadding: 10)
        XCTAssertEqual(
            slider.doubleValue,
            4.2,
            accuracy: 0.001,
            "live preview must not write back into the slider during AppKit tracking"
        )

        controller.finishWidthAdjustment(7.4, horizontalPadding: 10)
        XCTAssertEqual(slider.doubleValue, 7.4, accuracy: 0.001)
    }

    func testMenuBarTypographyAndPositionLabelsLocalizeAcrossSupportedLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, [String], [String], String)] = [
            (
                .simplifiedChinese,
                ["字号与位置", "菜单栏字号", "图标偏移", "金额偏移", "菜单栏宽度"],
                [
                    "调整菜单栏字体大小",
                    "微调图标上下像素位置：Y 轴 + 0.0 pt",
                    "微调金额上下像素位置：Y 轴 + 0.0 pt",
                    "调整 BalanceBar 与其他项目的空隙：宽度 + 0.0 pt"
                ],
                "从 -10.0 pt（窄）调整到 +10.0 pt（宽），默认 0 pt"
            ),
            (
                .traditionalChinese,
                ["字號與位置", "選單列字號", "圖示偏移", "金額偏移", "選單列寬度"],
                [
                    "調整選單列字體大小",
                    "微調圖示上下像素位置：Y 軸 + 0.0 pt",
                    "微調金額上下像素位置：Y 軸 + 0.0 pt",
                    "調整 BalanceBar 與其他項目的間距：寬度 + 0.0 pt"
                ],
                "從 -10.0 pt（窄）調整到 +10.0 pt（寬），預設 0 pt"
            ),
            (
                .japanese,
                ["フォントサイズと位置", "メニューバーのフォントサイズ", "アイコンの位置調整", "金額の位置調整", "メニューバーの幅"],
                [
                    "メニューバーのフォントサイズを調整",
                    "アイコンの上下位置を微調整：Y 軸 + 0.0 pt",
                    "金額の上下位置を微調整：Y 軸 + 0.0 pt",
                    "BalanceBar と他の項目との間隔を調整：幅 + 0.0 pt"
                ],
                "メニューバーの幅を -10.0 pt（狭い）から +10.0 pt（広い）まで調整（デフォルト 0 pt）"
            ),
            (
                .english,
                ["Font Size & Position", "Menu Bar Font Size", "Icon Offset", "Amount Offset", "Menu Bar Width"],
                [
                    "Adjusts the menu bar font size",
                    "Fine-tune the icon's vertical position: Y axis + 0.0 pt",
                    "Fine-tune the amount's vertical position: Y axis + 0.0 pt",
                    "Adjusts the gap between BalanceBar and other items: Width + 0.0 pt"
                ],
                "Adjusts menu bar width from -10.0 pt (narrow) to +10.0 pt (wide); default 0 pt"
            )
        ]

        for (language, expectedTitles, expectedSubtitles, expectedToolTip) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuBarWidthLocalization.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let preferences = AppPreferences(defaults: defaults)
            let page = DashboardMenuBarPage().make(.init(
                preferences: preferences,
                snapshot: .balance("Provider", 12.34, "USD", nil, Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))

            let labels = descendants(of: page).compactMap { $0 as? NSTextField }
            let labelStrings = labels.map(\.stringValue)
            let expectedEndpointLabels: (minimum: String, maximum: String)
            switch language {
            case .simplifiedChinese:
                expectedEndpointLabels = ("窄", "宽")
            case .traditionalChinese:
                expectedEndpointLabels = ("窄", "寬")
            case .japanese:
                expectedEndpointLabels = ("狭い", "広い")
            case .english:
                expectedEndpointLabels = ("Narrow", "Wide")
            case .system:
                expectedEndpointLabels = ("窄", "宽")
            }
            let expectedOffsetEndpointLabels: (minimum: String, maximum: String)
            switch language {
            case .simplifiedChinese, .traditionalChinese, .japanese, .system:
                expectedOffsetEndpointLabels = ("下", "上")
            case .english:
                expectedOffsetEndpointLabels = ("Down", "Up")
            }
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSliderMinimumIdentifier }?.stringValue,
                expectedEndpointLabels.minimum,
                "minimum width endpoint for \(language)"
            )
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSliderMaximumIdentifier }?.stringValue,
                expectedEndpointLabels.maximum,
                "maximum width endpoint for \(language)"
            )
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSliderMinimumIdentifier }?.stringValue,
                expectedOffsetEndpointLabels.minimum,
                "minimum icon offset endpoint for \(language)"
            )
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSliderMaximumIdentifier }?.stringValue,
                expectedOffsetEndpointLabels.maximum,
                "maximum icon offset endpoint for \(language)"
            )
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSliderMinimumIdentifier }?.stringValue,
                expectedOffsetEndpointLabels.minimum,
                "minimum amount offset endpoint for \(language)"
            )
            XCTAssertEqual(
                labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSliderMaximumIdentifier }?.stringValue,
                expectedOffsetEndpointLabels.maximum,
                "maximum amount offset endpoint for \(language)"
            )
            for expectedTitle in expectedTitles {
                XCTAssertTrue(
                    labelStrings.contains(expectedTitle),
                    "localized title \(expectedTitle) for \(language)"
                )
            }
            for expectedSubtitle in expectedSubtitles {
                XCTAssertTrue(
                    labelStrings.contains(expectedSubtitle),
                    "localized subtitle \(expectedSubtitle) for \(language)"
                )
            }
            let rowIndices = expectedTitles.dropFirst().compactMap { labelStrings.firstIndex(of: $0) }
            XCTAssertEqual(rowIndices.count, expectedTitles.count - 1)
            XCTAssertEqual(rowIndices, rowIndices.sorted(), "row order for \(language)")
            XCTAssertFalse(
                descendants(of: page).contains {
                    $0.identifier?.rawValue == "menuBarStatusItemWidthAdjustmentReset"
                },
                "width reset control must be absent for \(language)"
            )
            let slider = descendants(of: page)
                .compactMap { $0 as? NSSlider }
                .first { $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey }
            XCTAssertEqual(
                slider?.doubleValue ?? .nan,
                AppPreferences.menuBarStatusItemWidthAdjustmentDefault,
                accuracy: 0.001,
                "width slider default for \(language)"
            )
            XCTAssertEqual(slider?.toolTip, expectedToolTip, "width slider tooltip for \(language)")
            if language == .english {
                page.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
                page.layoutSubtreeIfNeeded()
                let labelsByIdentifier: [String: NSTextField] = Dictionary(
                    uniqueKeysWithValues: labels.compactMap { label in
                        guard let identifier = label.identifier?.rawValue else { return nil }
                        return (identifier, label)
                    }
                )
                guard
                    let iconMinimum = labelsByIdentifier[DashboardMenuBarPage.iconOffsetSliderMinimumIdentifier],
                    let amountMinimum = labelsByIdentifier[DashboardMenuBarPage.amountOffsetSliderMinimumIdentifier],
                    let widthMinimum = labelsByIdentifier[DashboardMenuBarPage.widthAdjustmentSliderMinimumIdentifier],
                    let iconMaximum = labelsByIdentifier[DashboardMenuBarPage.iconOffsetSliderMaximumIdentifier],
                    let amountMaximum = labelsByIdentifier[DashboardMenuBarPage.amountOffsetSliderMaximumIdentifier],
                    let widthMaximum = labelsByIdentifier[DashboardMenuBarPage.widthAdjustmentSliderMaximumIdentifier]
                else {
                    XCTFail("Expected all English slider endpoint labels")
                    defaults.removePersistentDomain(forName: suiteName)
                    continue
                }
                let minimumFrames = [iconMinimum, amountMinimum, widthMinimum].map {
                    $0.convert($0.bounds, to: page)
                }
                let maximumFrames = [iconMaximum, amountMaximum, widthMaximum].map {
                    $0.convert($0.bounds, to: page)
                }
                XCTAssertEqual(minimumFrames[0].minX, minimumFrames[1].minX, accuracy: 0.01)
                XCTAssertEqual(minimumFrames[1].minX, minimumFrames[2].minX, accuracy: 0.01)
                XCTAssertEqual(maximumFrames[0].maxX, maximumFrames[1].maxX, accuracy: 0.01)
                XCTAssertEqual(maximumFrames[1].maxX, maximumFrames[2].maxX, accuracy: 0.01)
            }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testMenuBarOfficialPreviewAppliesDefaultTextBaseline() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.MenuBarOfficialBaseline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let relay = DashboardPreferencePageRelay()
        let controller = DashboardMenuBarPage()
        let snapshot = Snapshot.official(
            "OpenAI",
            72,
            "7-day",
            "2h",
            Date(timeIntervalSince1970: 1)
        )

        preferences.showMenuBarReset = false
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: snapshot,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))
        let previewText = descendants(of: page).first {
            $0.identifier?.rawValue == "menuBarPreviewText"
        }
        // Percentage-only official text is now aligned by measured primary
        // ink; its old baseline transform is intentionally not asserted.
        XCTAssertNotNil(previewText)

        preferences.showMenuBarReset = true
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        let previewIcon = try! XCTUnwrap(
            descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewIcon" }
        )
        let previewTextView = try! XCTUnwrap(
            descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewText" }
        )
        let previewPrimary = try! XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewPrimaryIdentifier
            } as? NSTextField
        )
        let previewSecondary = try! XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewSecondaryIdentifier
            } as? NSTextField
        )
        let previewGeometry = MenuBarLayout.geometry(
            primarySize: previewPrimary.intrinsicContentSize,
            secondarySize: previewSecondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let previewBackgroundBounds = NSRect(x: 0, y: 0, width: 190, height: 42)
        let previewFrames = MenuBarLayout.frames(
            buttonSize: previewBackgroundBounds.size,
            geometry: previewGeometry,
            iconViewYOffset: 0
        )
        let previewCompensation = MenuBarLayout.horizontalCenteringCompensation(
            backgroundBounds: previewBackgroundBounds,
            geometry: previewGeometry,
            iconOffsetX: 0,
            textOffsetX: 0,
            centerVisibleUnionOnBackground: true
        )
        let centeredPreviewFrames = MenuBarLayoutFrames(
            content: previewFrames.content.offsetBy(dx: previewCompensation, dy: 0),
            iconSlot: previewFrames.iconSlot,
            icon: previewFrames.icon,
            text: previewFrames.text
        )
        let centeredPreviewVisibleBounds = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: centeredPreviewFrames,
                in: previewBackgroundBounds
            )
        )
        XCTAssertEqual(
            centeredPreviewVisibleBounds.midX,
            previewBackgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            previewTextView.layer?.affineTransform().tx ?? .nan,
            previewCompensation,
            accuracy: 0.001
        )
        XCTAssertEqual(
            previewIcon.layer?.affineTransform().tx ?? .nan,
            previewCompensation,
            accuracy: 0.001
        )
        // With reset time shown the text block defaults to 0.1pt lower.
        XCTAssertEqual(
            previewText?.layer?.affineTransform().ty ?? CGFloat.nan,
            DashboardMenuBarPage.previewAmountDefaultYOffset
                - MenuBarLayout.officialSecondaryTextYOffset,
            accuracy: 0.001
        )

        // User fine-tune offsets stack on top of the official default baseline.
        preferences.menuBarAmountOffsetY = 1
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        XCTAssertEqual(
            previewText?.layer?.affineTransform().ty ?? CGFloat.nan,
            1 - MenuBarLayout.officialSecondaryTextYOffset
                + DashboardMenuBarPage.previewAmountDefaultYOffset,
            accuracy: 0.001
        )
    }

    func testMenuBarSingleLinePreviewAnchorsPrimaryInkForOfficialAndThirdParty() throws {
        let suiteName = "DashboardPreferencePagesTests.MenuBarSingleLineAnchor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showMenuBarReset = false
        preferences.showMenuBarAmount = true
        preferences.showMenuBarIcon = true
        let relay = DashboardPreferencePageRelay()
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: .official("OpenAI", 48, "7-day", nil, Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))
        page.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        page.layoutSubtreeIfNeeded()

        let primary = try XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.previewPrimaryIdentifier
            } as? NSTextField
        )
        let icon = try XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == "menuBarPreviewIcon"
            } as? NSImageView
        )
        let previewTextView = try XCTUnwrap(
            descendants(of: page).first {
                $0.identifier?.rawValue == "menuBarPreviewText"
            }
        )
        let background = try XCTUnwrap(previewBackgroundAncestor(of: primary))

        let scenarios: [(Snapshot, Bool)] = [
            (.official("OpenAI", 48, "7-day", nil, Date(timeIntervalSince1970: 1)), false),
            (.balance("Provider", 123456.78, "USD", nil, Date(timeIntervalSince1970: 1)), true),
            (.balance("Provider", 0.10, "USD", nil, Date(timeIntervalSince1970: 1)), true)
        ]
        for (snapshot, isBalance) in scenarios {
            for showIcon in [false, true] {
                preferences.showMenuBarIcon = showIcon
                var centers: [CGFloat] = []
                for preset in MenuBarFontSizePreset.allCases {
                    preferences.menuBarFontSizePreset = preset
                    controller.refresh(
                        snapshot: snapshot,
                        preferences: preferences,
                        menuBarSnapshot: { $0 },
                        iconImage: nil
                    )
                    page.layoutSubtreeIfNeeded()
                    background.layoutSubtreeIfNeeded()

                    let ink = try XCTUnwrap(
                        MenuBarLayout.appKitRenderedTextBounds(
                            for: primary,
                            frameSize: primary.bounds.size
                        )
                    )
                    let renderedInk = primary
                        .convert(ink, to: background)
                        .offsetBy(
                            dx: previewTextView.layer?.affineTransform().tx ?? 0,
                            dy: previewTextView.layer?.affineTransform().ty ?? 0
                        )
                    let targetX = MenuBarLayout.singleLinePrimaryAnchorX(
                        backgroundBounds: background.bounds,
                        primaryText: primary.stringValue,
                        showIcon: showIcon,
                        isBalance: isBalance
                    )
                    centers.append(renderedInk.midX)
                    XCTAssertEqual(
                        renderedInk.midX,
                        targetX,
                        accuracy: 0.5,
                        "preview primary X drifted"
                    )
                    XCTAssertEqual(
                        renderedInk.midY,
                        background.bounds.midY
                            + MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                                fontSize: CGFloat(preset.primarySize)
                            ),
                        accuracy: 0.5,
                        "preview primary Y drifted"
                    )
                    if showIcon {
                        let iconFrame = icon
                            .convert(icon.bounds, to: background)
                            .offsetBy(
                                dx: icon.layer?.affineTransform().tx ?? 0,
                                dy: icon.layer?.affineTransform().ty ?? 0
                            )
                        XCTAssertEqual(
                            iconFrame.midY,
                            background.bounds.midY,
                            accuracy: 0.5,
                            "preview icon must stay on the card center while primary ink is calibrated independently"
                        )
                    }
                }
                XCTAssertLessThanOrEqual(
                    (centers.max() ?? 0) - (centers.min() ?? 0),
                    0.5,
                    "preview primary X must stay fixed across font presets"
                )
            }
        }
    }

    func testMenuBarOffsetRepeatPolicyDelaysAndAccelerates() {
        let policy = MenuBarOffsetRepeatPolicy.standard
        XCTAssertEqual(policy.initialDelay, 0.35, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 0), 0.35, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 1), 0.1, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 2), 0.09, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 3), 0.081, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 50), 0.03, accuracy: 0.001)
        XCTAssertEqual(policy.interval(afterStep: 200), 0.03, accuracy: 0.001)
    }

    func testMenuBarOffsetRepeatDriverStepsAndStops() {
        let policy = MenuBarOffsetRepeatPolicy(
            initialDelay: 0.05,
            initialInterval: 0.02,
            accelerationFactor: 0.9,
            minimumInterval: 0.01
        )
        var steps = 0
        let driver = MenuBarOffsetRepeatDriver(policy: policy) { steps += 1 }
        driver.start()

        let ran = expectation(description: "repeat driver ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            driver.stop()
            ran.fulfill()
        }
        wait(for: [ran], timeout: 2)
        XCTAssertGreaterThanOrEqual(steps, 8)
        let countAfterStop = steps

        let settled = expectation(description: "repeat driver stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(steps, countAfterStop)
    }

    func testLogsKeepViewerTextAndSeverityStyling() {
        let text = "[12:00:00] [ERROR] [configuration] value=42%"
        let styled = DashboardLogsPage.styledLog(text)
        let nsText = text as NSString

        XCTAssertEqual(styled.string, text)
        XCTAssertNotNil(styled.attribute(.foregroundColor, at: nsText.range(of: "[ERROR]").location, effectiveRange: nil))
        XCTAssertNotNil(styled.attribute(.font, at: nsText.range(of: "42").location, effectiveRange: nil))
    }

    func testAboutVersionPreservesBundleFallbackAndDevelopmentSuffix() {
        XCTAssertEqual(
            DashboardAboutPage.displayedVersion(shortVersion: nil, isDevBuild: false),
            "0.11.14"
        )
        XCTAssertEqual(
            DashboardAboutPage.displayedVersion(shortVersion: "0.11.20", isDevBuild: true),
            "0.11.20 · Dev"
        )
    }

    func testOpenCodexSettingsWordingAndControlsAcrossLanguagesAndModes() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        for (language, automaticDetection) in [
            (AppLanguage.simplifiedChinese, true),
            (.simplifiedChinese, false),
            (.traditionalChinese, true),
            (.traditionalChinese, false),
            (.japanese, true),
            (.japanese, false),
            (.english, true),
            (.english, false)
        ] {
            AppLanguage.selected = language
            let copy: (String, String, String, String) -> String = { zh, en, zhT, ja in
                switch language {
                case .simplifiedChinese: return zh
                case .traditionalChinese: return zhT
                case .japanese: return ja
                case .english, .system: return en
                }
            }
            let suiteName = "DashboardPreferencePagesTests.OpenCodex.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = AppPreferences(defaults: defaults)
            preferences.openCodexDashboardAutomaticDetection = automaticDetection
            preferences.openCodexDashboardPortOverride = automaticDetection ? nil : 23456

            let relay = DashboardPreferencePageRelay()
            var activationCount = 0
            relay.onOpenOpenCodex = { activationCount += 1 }
            let mode = OpenCodexDashboardMode(
                automaticDetection: automaticDetection,
                manualPort: automaticDetection ? nil : 23456
            )
            let resolution = OpenCodexDashboardResolver.resolve(
                manualPort: mode.effectiveManualPort,
                runtimeCandidate: nil
            )
            let page = DashboardAdvancedPage().make(.init(
                preferences: preferences,
                mode: mode,
                currentResolution: resolution,
                runtimeCandidate: nil,
                relay: relay,
                logViewer: NSView(),
                onModeChanged: { _ in },
                onClamp: {}
            ))

            let labels = descendants(of: page).compactMap { $0 as? NSTextField }
            let switches = descendants(of: page).compactMap { $0 as? NSSwitch }
            let buttons = descendants(of: page).compactMap { $0 as? NSButton }
            let expectedPort = automaticDetection ? 10100 : 23456
            let expectedPortText = copy(
                "当前端口：\(expectedPort)",
                "Current port: \(expectedPort)",
                "目前連接埠：\(expectedPort)",
                "現在のポート：\(expectedPort)"
            )
            let expectedDashboardTitle = copy(
                "打开 OpenCodex 仪表盘",
                "Open OpenCodex Dashboard",
                "開啟 OpenCodex 儀表板",
                "OpenCodex ダッシュボードを開く"
            )
            let expectedButtonTitle = copy("打开", "Open", "開啟", "開く")

            guard let automaticSwitch = switches.first(where: {
                $0.identifier?.rawValue == "openCodexAutomaticDetection"
            }) else {
                return XCTFail("Expected OpenCodex automatic detection switch")
            }
            XCTAssertEqual(automaticSwitch.state, automaticDetection ? .on : .off)

            guard let portLabel = labels.first(where: { $0.stringValue == expectedPortText }) else {
                return XCTFail("Expected current port label \(expectedPortText)")
            }
            let expectedAutomaticTitle = copy(
                "自动检测端口",
                "Detect Port Automatically",
                "自動偵測連接埠",
                "ポートを自動検出"
            )
            guard let automaticTitle = labels.first(where: { $0.stringValue == expectedAutomaticTitle }) else {
                return XCTFail("Expected automatic detection title \(expectedAutomaticTitle)")
            }
            XCTAssertFalse(automaticTitle.isEditable)
            XCTAssertFalse(automaticTitle.isSelectable)
            XCTAssertFalse(portLabel.isEditable)
            XCTAssertFalse(portLabel.isSelectable)
            XCTAssertEqual(
                nonEmptyTextFields(in: portLabel.superview?.superview),
                [expectedAutomaticTitle, expectedPortText]
            )
            XCTAssertEqual(
                equalHeightConstraint(in: portLabel.superview?.superview),
                DashboardAdvancedPageLayout.compactTwoLineRowHeight
            )
            XCTAssertEqual(
                verticalLabelPadding(in: portLabel.superview?.superview),
                DashboardAdvancedPageLayout.compactTwoLineRowVerticalPadding
            )

            let expectedManualTitle = copy(
                "手动输入端口号",
                "Enter Port Manually",
                "手動輸入連接埠號",
                "ポートを手動で入力"
            )
            guard let manualTitle = labels.first(where: { $0.stringValue == expectedManualTitle }) else {
                return XCTFail("Expected manual port title \(expectedManualTitle)")
            }
            guard let manualDetail = labels.first(where: {
                let value = $0.stringValue
                return value.contains("十进制 1–65535")
                    || value.contains("十進位 1–65535")
                    || value.contains("decimal 1–65535")
                    || value.contains("1～65535")
            }) else {
                return XCTFail("Expected manual port subtitle")
            }
            XCTAssertFalse(manualTitle.isEditable)
            XCTAssertFalse(manualTitle.isSelectable)
            XCTAssertFalse(manualDetail.isEditable)
            XCTAssertFalse(manualDetail.isSelectable)
            XCTAssertEqual(
                equalHeightConstraint(in: manualTitle.superview?.superview),
                DashboardAdvancedPageLayout.compactTwoLineRowHeight
            )
            XCTAssertEqual(
                verticalLabelPadding(in: manualTitle.superview?.superview),
                DashboardAdvancedPageLayout.compactTwoLineRowVerticalPadding
            )

            XCTAssertFalse(labels.contains { $0.stringValue.contains("手动端口只用于") })
            XCTAssertFalse(labels.contains { $0.stringValue.contains("The manual port only") })
            XCTAssertFalse(labels.contains { $0.stringValue.contains("/#dashboard") })

            guard let dashboardTitle = labels.first(where: { $0.stringValue == expectedDashboardTitle }) else {
                return XCTFail("Expected Dashboard title \(expectedDashboardTitle)")
            }
            XCTAssertEqual(dashboardTitle.stringValue, expectedDashboardTitle)
            XCTAssertEqual(equalHeightConstraint(in: dashboardTitle.superview?.superview), 62)

            guard let openButton = buttons.first(where: { $0.title == expectedButtonTitle }) else {
                return XCTFail("Expected Dashboard button \(expectedButtonTitle)")
            }
            XCTAssertEqual(openButton.title, expectedButtonTitle)
            XCTAssertTrue(openButton.isEnabled)
            relay.openOpenCodex(openButton)
            XCTAssertEqual(activationCount, 1)

            page.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            page.layoutSubtreeIfNeeded()
            guard let automaticRow = view(withIdentifier: "openCodexAutomaticDetectionRow", in: page),
                  let manualRow = view(withIdentifier: "openCodexManualPortRow", in: page),
                  let dashboardRow = view(withIdentifier: "openCodexDashboardRow", in: page) else {
                return XCTFail("Expected all OpenCodex rows")
            }
            XCTAssertEqual(automaticRow.frame.width, manualRow.frame.width, accuracy: 0.5)
            XCTAssertEqual(automaticRow.frame.width, dashboardRow.frame.width, accuracy: 0.5)

            let unchangedTwoLineRow = DashboardSettingsComponents.makeSettingsRow(
                "Unchanged",
                subtitle: "Other settings keep the default row geometry"
            )
            XCTAssertEqual(equalHeightConstraint(in: unchangedTwoLineRow), 62)
        }
    }

    func testOpenCodexRowsKeepStableWidthsAcrossLiveAutomaticDetectionToggle() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.OpenCodex.Width.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.openCodexDashboardAutomaticDetection = true
        preferences.openCodexDashboardPortOverride = nil
        let relay = DashboardPreferencePageRelay()
        let controller = DashboardAdvancedPage()
        let resolution = OpenCodexDashboardResolver.resolve(
            manualPort: nil,
            runtimeCandidate: nil
        )
        let page = controller.make(.init(
            preferences: preferences,
            mode: OpenCodexDashboardMode(automaticDetection: true, manualPort: nil),
            currentResolution: resolution,
            runtimeCandidate: nil,
            relay: relay,
            logViewer: NSView(),
            onModeChanged: { _ in },
            onClamp: {}
        ))
        page.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: page.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = page

        guard let manualRow = view(withIdentifier: "openCodexManualPortRow", in: page),
              let dashboardRow = view(withIdentifier: "openCodexDashboardRow", in: page) else {
            return XCTFail("Expected manual and Dashboard rows")
        }
        let manualHeight = equalHeightConstraint(in: manualRow)
        let manualPadding = verticalLabelPadding(in: manualRow)
        let dashboardHeight = equalHeightConstraint(in: dashboardRow)

        window.layoutIfNeeded()
        assertOpenCodexRowsUseAutomaticWidth(in: page)
        assertUnchangedOpenCodexRowGeometry(
            manualRow: manualRow,
            dashboardRow: dashboardRow,
            manualHeight: manualHeight,
            manualPadding: manualPadding,
            dashboardHeight: dashboardHeight
        )
        controller.handleAutomaticDetection(false)
        window.layoutIfNeeded()
        assertOpenCodexRowsUseAutomaticWidth(in: page)
        assertUnchangedOpenCodexRowGeometry(
            manualRow: manualRow,
            dashboardRow: dashboardRow,
            manualHeight: manualHeight,
            manualPadding: manualPadding,
            dashboardHeight: dashboardHeight
        )
        controller.handleAutomaticDetection(true)
        window.layoutIfNeeded()
        assertOpenCodexRowsUseAutomaticWidth(in: page)
        assertUnchangedOpenCodexRowGeometry(
            manualRow: manualRow,
            dashboardRow: dashboardRow,
            manualHeight: manualHeight,
            manualPadding: manualPadding,
            dashboardHeight: dashboardHeight
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func view(withIdentifier identifier: String, in view: NSView) -> NSView? {
        descendants(of: view).first { $0.identifier?.rawValue == identifier }
    }

    private func assertOpenCodexRowsUseAutomaticWidth(in page: NSView, file: StaticString = #filePath, line: UInt = #line) {
        guard let automaticRow = view(withIdentifier: "openCodexAutomaticDetectionRow", in: page),
              let manualRow = view(withIdentifier: "openCodexManualPortRow", in: page),
              let dashboardRow = view(withIdentifier: "openCodexDashboardRow", in: page) else {
            return XCTFail("Expected all OpenCodex rows", file: file, line: line)
        }
        XCTAssertEqual(manualRow.frame.width, automaticRow.frame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(dashboardRow.frame.width, automaticRow.frame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(
            automaticRow.frame.height,
            DashboardAdvancedPageLayout.compactTwoLineRowHeight,
            accuracy: 0.5,
            file: file,
            line: line
        )
        if !manualRow.isHidden {
            XCTAssertEqual(
                manualRow.frame.height,
                DashboardAdvancedPageLayout.compactTwoLineRowHeight,
                accuracy: 0.5,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(dashboardRow.frame.height, 62, accuracy: 0.5, file: file, line: line)
        if let rowsStack = automaticRow.superview,
           let card = rowsStack.superview {
            let visibleRowHeight = DashboardAdvancedPageLayout.compactTwoLineRowHeight +
                (manualRow.isHidden ? 0 : DashboardAdvancedPageLayout.compactTwoLineRowHeight) +
                62
            let visibleSeparatorCount = descendants(of: card)
                .compactMap { $0 as? NSBox }
                .filter { !$0.isHidden }
                .count
            XCTAssertEqual(
                card.frame.height,
                visibleRowHeight + CGFloat(visibleSeparatorCount) * DashboardSettingsComponents.settingsSeparatorHeight,
                accuracy: 0.5,
                file: file,
                line: line
            )
        } else {
            XCTFail("Expected OpenCodex rows to be hosted by a card", file: file, line: line)
        }
        XCTAssertNotNil(
            widthConstraint(between: manualRow, and: automaticRow, in: page),
            "Manual port row must use the automatic row as its width reference",
            file: file,
            line: line
        )
    }

    private func widthConstraint(between first: NSView, and second: NSView, in page: NSView) -> NSLayoutConstraint? {
        descendants(of: page)
            .compactMap { $0 as? NSStackView }
            .flatMap(\.constraints)
            .first { constraint in
                constraint.firstAttribute == .width &&
                    constraint.secondAttribute == .width &&
                    ((constraint.firstItem as? NSView) === first && (constraint.secondItem as? NSView) === second ||
                        (constraint.firstItem as? NSView) === second && (constraint.secondItem as? NSView) === first)
            }
    }

    private func assertUnchangedOpenCodexRowGeometry(
        manualRow: NSView,
        dashboardRow: NSView,
        manualHeight: CGFloat?,
        manualPadding: CGFloat?,
        dashboardHeight: CGFloat?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(equalHeightConstraint(in: manualRow), manualHeight, file: file, line: line)
        XCTAssertEqual(verticalLabelPadding(in: manualRow), manualPadding, file: file, line: line)
        XCTAssertEqual(equalHeightConstraint(in: dashboardRow), dashboardHeight, file: file, line: line)
    }

    private func nonEmptyTextFields(in view: NSView?) -> [String] {
        guard let view else { return [] }
        return descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
            .filter { !$0.isEmpty }
    }

    private func equalHeightConstraint(in view: NSView?) -> CGFloat? {
        view?.constraints.first {
            $0.firstAttribute == .height && $0.relation == .equal
        }?.constant
    }

    private func verticalLabelPadding(in row: NSView?) -> CGFloat? {
        guard let row,
              let labels = row.subviews.first(where: { $0 is NSStackView }) else {
            return nil
        }
        let top = row.constraints.first {
            ($0.firstItem as? NSView) === labels && $0.firstAttribute == .top
        }?.constant
        let bottom = row.constraints.first {
            ($0.firstItem as? NSView) === labels && $0.firstAttribute == .bottom
        }?.constant
        guard let top, let bottom, abs(top + bottom) < 0.001 else { return nil }
        return top
    }

    func testAboutPageGitHubEntryIsCenteredAccessibleAndOpensOnce() throws {
        var openedURLs: [URL] = []
        let resourceBundle = Bundle(for: DashboardAboutGitHubButton.self)
        let page = DashboardAboutPage.make(
            bundle: resourceBundle,
            devBundleIdentifier: "com.huanmeng06.BalanceBar.dev",
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        page.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        page.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(descendant(withIdentifier: "about.githubRow", in: page) as? NSStackView)
        let button = try XCTUnwrap(descendant(withIdentifier: "about.githubButton", in: page) as? DashboardAboutGitHubButton)
        let rowCenter = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: page).x

        XCTAssertEqual(rowCenter, page.bounds.midX, accuracy: 0.5)
        XCTAssertNotNil(button.image)
        XCTAssertNotNil(resourceBundle.url(forResource: "GitHub", withExtension: "svg"))
        XCTAssertFalse(button.isBordered)
        XCTAssertEqual(button.bezelStyle, .regularSquare)
        XCTAssertEqual(button.bounds.width, button.bounds.height, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.width, button.circularBackgroundFrameForTesting.height, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.midX, button.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.midY, button.bounds.midY, accuracy: 0.5)
        let iconWidth = try XCTUnwrap(button.image?.size.width)
        XCTAssertEqual(iconWidth, DashboardAboutGitHubButton.iconSize, accuracy: 0.5)
        XCTAssertLessThan(iconWidth, button.circularBackgroundFrameForTesting.width)
        XCTAssertEqual(button.destinationURL, DashboardAboutPage.githubRepositoryURL)
        let accessibilityLabel = button.accessibilityLabel()
        XCTAssertTrue(accessibilityLabel == "GitHub 项目" || accessibilityLabel == "GitHub repository")

        XCTAssertTrue(button.target === button)
        XCTAssertEqual(button.action, #selector(DashboardAboutGitHubButton.activate(_:)))
        button.activate(nil)

        XCTAssertEqual(openedURLs, [DashboardAboutPage.githubRepositoryURL])
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: child) { return match }
        }
        return nil
    }

    private func previewBackgroundAncestor(of view: NSView) -> NSView? {
        var current = view.superview
        while let candidate = current {
            if candidate.bounds.height >= 40,
               candidate.bounds.height <= 44,
               candidate.bounds.width >= 180 {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }
}
