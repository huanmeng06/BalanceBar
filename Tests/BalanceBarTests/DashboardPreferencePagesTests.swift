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
            (.english, true),
            (.english, false)
        ] {
            AppLanguage.selected = language
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
            let expectedPortText = language == .simplifiedChinese
                ? "当前端口：\(expectedPort)"
                : "Current port: \(expectedPort)"
            let expectedDashboardTitle = language == .simplifiedChinese
                ? "打开 OpenCodex 仪表盘"
                : "Open OpenCodex Dashboard"
            let expectedButtonTitle = language == .simplifiedChinese ? "打开" : "Open"

            guard let automaticSwitch = switches.first(where: {
                $0.identifier?.rawValue == "openCodexAutomaticDetection"
            }) else {
                return XCTFail("Expected OpenCodex automatic detection switch")
            }
            XCTAssertEqual(automaticSwitch.state, automaticDetection ? .on : .off)

            guard let portLabel = labels.first(where: { $0.stringValue == expectedPortText }) else {
                return XCTFail("Expected current port label \(expectedPortText)")
            }
            let expectedAutomaticTitle = language == .simplifiedChinese
                ? "自动检测端口"
                : "Detect Port Automatically"
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

            let expectedManualTitle = language == .simplifiedChinese
                ? "手动输入端口号"
                : "Enter Port Manually"
            guard let manualTitle = labels.first(where: { $0.stringValue == expectedManualTitle }) else {
                return XCTFail("Expected manual port title \(expectedManualTitle)")
            }
            guard let manualDetail = labels.first(where: {
                $0.stringValue.contains("十进制 1–65535") ||
                    $0.stringValue.contains("decimal 1–65535")
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
            XCTAssertEqual(
                nonEmptyTextFields(in: dashboardTitle.superview?.superview),
                [expectedDashboardTitle]
            )
            XCTAssertEqual(equalHeightConstraint(in: dashboardTitle.superview?.superview), 62)

            guard let openButton = buttons.first(where: { $0.title == expectedButtonTitle }) else {
                return XCTFail("Expected Dashboard button \(expectedButtonTitle)")
            }
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

        page.layoutSubtreeIfNeeded()
        let automaticWidths = rowWidths(in: page)
        controller.handleAutomaticDetection(false)
        page.layoutSubtreeIfNeeded()
        let manualWidths = rowWidths(in: page)
        controller.handleAutomaticDetection(true)
        page.layoutSubtreeIfNeeded()
        let restoredWidths = rowWidths(in: page)

        XCTAssertEqual(automaticWidths.count, 3)
        XCTAssertEqual(manualWidths.count, 3)
        XCTAssertEqual(restoredWidths.count, 3)
        for index in automaticWidths.indices {
            XCTAssertEqual(manualWidths[index], automaticWidths[index], accuracy: 0.5)
            XCTAssertEqual(restoredWidths[index], automaticWidths[index], accuracy: 0.5)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func view(withIdentifier identifier: String, in view: NSView) -> NSView? {
        descendants(of: view).first { $0.identifier?.rawValue == identifier }
    }

    private func rowWidths(in page: NSView) -> [CGFloat] {
        [
            "openCodexAutomaticDetectionRow",
            "openCodexManualPortRow",
            "openCodexDashboardRow"
        ].compactMap { view(withIdentifier: $0, in: page)?.frame.width }
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
}
