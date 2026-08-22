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

        XCTAssertFalse(preferences.showQuickSwitchMenu)
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 5)
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
        widthSlider.doubleValue = 12.3
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
        XCTAssertEqual(values.first?.1 ?? .nan, 12.3, accuracy: 0.001)
        XCTAssertEqual(endedValues.count, 1)
        XCTAssertEqual(endedValues.first?.0, AppPreferences.menuBarStatusItemWidthAdjustmentKey)
        XCTAssertEqual(endedValues.first?.1 ?? .nan, 12.3, accuracy: 0.001)
        XCTAssertEqual(resets, [DashboardMenuBarPage.iconOffsetsResetIdentifier])
    }

    func testMenuBarFineTuneSectionRendersControlsAndPreviewOffsets() {
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
            if identifier == AppPreferences.menuBarStatusItemWidthAdjustmentKey {
                preferences.menuBarStatusItemWidthAdjustment = value
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
        let iconYButtons = buttons.filter { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetYKey }
        let amountXButtons = buttons.filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetXKey }
        let amountYButtons = buttons.filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetYKey }
        XCTAssertTrue(iconXButtons.isEmpty)
        let sliders = descendants(of: page).compactMap { $0 as? NSSlider }
        guard let widthSlider = sliders.first(where: {
            $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey
        }) else {
            return XCTFail("Expected a status item width slider")
        }
        XCTAssertEqual(iconYButtons.count, 2)
        XCTAssertTrue(amountXButtons.isEmpty)
        XCTAssertEqual(amountYButtons.count, 2)
        XCTAssertEqual(
            Set(amountYButtons.map(\.tag)),
            [-1, 1]
        )
        XCTAssertTrue(iconYButtons.allSatisfy { $0 is RepeatOffsetButton })
        XCTAssertTrue(amountYButtons.allSatisfy { $0 is RepeatOffsetButton })
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
        XCTAssertEqual(widthMinimumLabel?.stringValue, "0")
        XCTAssertEqual(widthMaximumLabel?.stringValue, "+20")
        XCTAssertFalse(buttons.first {
            $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetsResetIdentifier
        } is RepeatOffsetButton)
        XCTAssertEqual(
            buttons.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetsResetIdentifier }?.title,
            "归零"
        )
        XCTAssertEqual(
            buttons.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetsResetIdentifier }?.title,
            "归零"
        )
        XCTAssertFalse(buttons.contains {
            $0.identifier?.rawValue == "menuBarStatusItemWidthAdjustmentReset"
        })
        XCTAssertEqual(
            buttons.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetsResetIdentifier }?.isEnabled,
            true
        )

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        let iconSummary = labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSummaryIdentifier }
        let amountSummary = labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSummaryIdentifier }
        XCTAssertEqual(iconSummary?.stringValue, "X 0.2 · Y -0.3")
        XCTAssertEqual(amountSummary?.stringValue, "X -0.4 · Y 0.5")
        XCTAssertEqual(
            labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSummaryIdentifier }?.stringValue,
            "横向范围 +0.6 pt"
        )
        XCTAssertEqual(labels.first { $0.stringValue == "细节微调" }?.stringValue, "细节微调")
        XCTAssertEqual(labels.first { $0.stringValue == "图标" }?.stringValue, "图标")
        XCTAssertEqual(labels.first { $0.stringValue == "金额" }?.stringValue, "金额")
        XCTAssertEqual(labels.first { $0.stringValue == "宽度" }?.stringValue, "宽度")

        let previewIcon = descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewIcon" }
        let previewText = descendants(of: page).first { $0.identifier?.rawValue == "menuBarPreviewText" }
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
        XCTAssertEqual(
            previewText?.layer?.affineTransform().ty ?? CGFloat.nan,
            0.5 - MenuBarLayout.singleLineTextYOffset
                + DashboardMenuBarPage.previewAmountDefaultYOffset,
            accuracy: 0.001
        )

        widthSlider.doubleValue = 0.7
        relay.adjustOffsetValue(widthSlider)
        XCTAssertEqual(preferences.menuBarStatusItemWidthAdjustment, 0.7, accuracy: 0.001)
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
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarIconOffsetYKey }
            .allSatisfy { !$0.isEnabled })
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetsResetIdentifier }
            .allSatisfy { !$0.isEnabled })
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetXKey }
            .isEmpty)
        XCTAssertTrue(refreshedButtons
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarAmountOffsetYKey }
            .allSatisfy { $0.isEnabled })
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarStatusItemWidthAdjustmentKey }
            .allSatisfy { $0.isEnabled })
    }

    func testMenuBarFontSizeControlsKeepRowsIndependentAndRefreshPreview() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.MenuBarFontSize.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.menuBarPrimaryFontSize = 14.2
        preferences.menuBarSecondaryFontSize = 9.6
        let relay = DashboardPreferencePageRelay()
        relay.onOffsetValue = { identifier, value in
            switch identifier {
            case AppPreferences.menuBarPrimaryFontSizeKey:
                preferences.menuBarPrimaryFontSize = AppPreferences.normalizedMenuBarFontSize(
                    value,
                    range: AppPreferences.menuBarPrimaryFontSizeRange
                )
            case AppPreferences.menuBarSecondaryFontSizeKey:
                preferences.menuBarSecondaryFontSize = AppPreferences.normalizedMenuBarFontSize(
                    value,
                    range: AppPreferences.menuBarSecondaryFontSizeRange
                )
            default:
                break
            }
        }
        relay.onOffsetReset = { identifier in
            switch identifier {
            case DashboardMenuBarPage.primaryFontSizeResetIdentifier:
                preferences.menuBarPrimaryFontSize = AppPreferences.menuBarPrimaryFontSizeDefault
            case DashboardMenuBarPage.secondaryFontSizeResetIdentifier:
                preferences.menuBarSecondaryFontSize = AppPreferences.menuBarSecondaryFontSizeDefault
            default:
                break
            }
        }
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))

        let sliders = descendants(of: page).compactMap { $0 as? NSSlider }
        let primarySlider = try XCTUnwrap(sliders.first {
            $0.identifier?.rawValue == AppPreferences.menuBarPrimaryFontSizeKey
        })
        let secondarySlider = try XCTUnwrap(sliders.first {
            $0.identifier?.rawValue == AppPreferences.menuBarSecondaryFontSizeKey
        })
        XCTAssertTrue(primarySlider is MenuBarFontSizeSlider)
        XCTAssertTrue(secondarySlider is MenuBarFontSizeSlider)
        XCTAssertEqual(primarySlider.minValue, 10, accuracy: 0.001)
        XCTAssertEqual(primarySlider.maxValue, 16, accuracy: 0.001)
        XCTAssertEqual(secondarySlider.minValue, 8, accuracy: 0.001)
        XCTAssertEqual(secondarySlider.maxValue, 13, accuracy: 0.001)
        XCTAssertEqual(primarySlider.doubleValue, 14.2, accuracy: 0.001)
        XCTAssertEqual(secondarySlider.doubleValue, 9.6, accuracy: 0.001)
        XCTAssertTrue(primarySlider.isContinuous)
        XCTAssertTrue(secondarySlider.isContinuous)
        XCTAssertFalse(primarySlider.allowsTickMarkValuesOnly)
        XCTAssertFalse(secondarySlider.allowsTickMarkValuesOnly)
        XCTAssertTrue(primarySlider.toolTip?.contains("0.1pt") == true)
        XCTAssertTrue(secondarySlider.toolTip?.contains("0.1pt") == true)

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertEqual(
            labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.primaryFontSizeSummaryIdentifier }?.stringValue,
            "14.2 pt"
        )
        XCTAssertEqual(
            labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.secondaryFontSizeSummaryIdentifier }?.stringValue,
            "9.6 pt"
        )

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
        XCTAssertEqual(previewPrimary.font?.pointSize ?? .nan, 14.2, accuracy: 0.001)
        XCTAssertEqual(previewSecondary.font?.pointSize ?? .nan, 9.6, accuracy: 0.001)
        XCTAssertEqual(previewPrimary.frame.minX, previewSecondary.frame.minX, accuracy: 0.001)
        XCTAssertEqual(previewPrimary.frame.width, previewSecondary.frame.width, accuracy: 0.001)

        primarySlider.doubleValue = 15.04
        XCTAssertTrue(primarySlider.sendAction(primarySlider.action, to: primarySlider.target))
        XCTAssertEqual(preferences.menuBarPrimaryFontSize, 15.0, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarSecondaryFontSize, 9.6, accuracy: 0.001)
        secondarySlider.doubleValue = 8.95
        XCTAssertTrue(secondarySlider.sendAction(secondarySlider.action, to: secondarySlider.target))
        XCTAssertEqual(preferences.menuBarSecondaryFontSize, 9.0, accuracy: 0.001)
        XCTAssertEqual(preferences.menuBarPrimaryFontSize, 15.0, accuracy: 0.001)

        let primaryReset = try XCTUnwrap(descendants(of: page)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == DashboardMenuBarPage.primaryFontSizeResetIdentifier })
        relay.resetOffset(primaryReset)
        XCTAssertEqual(
            preferences.menuBarPrimaryFontSize,
            AppPreferences.menuBarPrimaryFontSizeDefault,
            accuracy: 0.001
        )
        let secondaryReset = try XCTUnwrap(descendants(of: page)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == DashboardMenuBarPage.secondaryFontSizeResetIdentifier })
        relay.resetOffset(secondaryReset)
        XCTAssertEqual(
            preferences.menuBarSecondaryFontSize,
            AppPreferences.menuBarSecondaryFontSizeDefault,
            accuracy: 0.001
        )

        preferences.showMenuBarAmount = false
        controller.refresh(
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        let refreshedSliders = descendants(of: page).compactMap { $0 as? NSSlider }
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarPrimaryFontSizeKey }
            .allSatisfy { !$0.isEnabled })
        XCTAssertTrue(refreshedSliders
            .filter { $0.identifier?.rawValue == AppPreferences.menuBarSecondaryFontSizeKey }
            .allSatisfy { !$0.isEnabled })
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
        XCTAssertEqual(slider?.doubleValue ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(summary?.stringValue, "横向范围 +7.4 pt")

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

    func testMenuBarWidthFineTuneLabelLocalizesAcrossSupportedLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "宽度", "从 0pt 向右放大，最大 +20pt"),
            (.traditionalChinese, "寬度", "從 0pt 向右放大，最大 +20pt"),
            (.japanese, "幅", "0pt から右へ広げ、最大 +20pt"),
            (.english, "Width", "Drag right to widen from 0pt up to +20pt")
        ]

        for (language, expectedTitle, expectedToolTip) in cases {
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

            XCTAssertEqual(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first(where: { $0.stringValue == expectedTitle })?
                    .stringValue,
                expectedTitle,
                "width title for \(language)"
            )
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
                0,
                accuracy: 0.001,
                "width slider default for \(language)"
            )
            XCTAssertEqual(slider?.toolTip, expectedToolTip, "width slider tooltip for \(language)")
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
        // Percentage-only official text defaults to 0.5pt higher.
        XCTAssertEqual(
            previewText?.layer?.affineTransform().ty ?? CGFloat.nan,
            DashboardMenuBarPage.previewAmountDefaultYOffset
                - MenuBarLayout.officialAmountOnlyTextYOffset,
            accuracy: 0.001
        )

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
            centerTextBlock: true
        )
        let centeredPreviewFrames = MenuBarLayoutFrames(
            content: previewFrames.content.offsetBy(dx: previewCompensation, dy: 0),
            iconSlot: previewFrames.iconSlot,
            icon: previewFrames.icon,
            text: previewFrames.text
        )
        let centeredPreviewTextBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: centeredPreviewFrames,
                geometry: previewGeometry,
                in: previewBackgroundBounds
            )
        )
        XCTAssertEqual(
            centeredPreviewTextBounds.midX,
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
}
