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

    func testLaunchAtLoginGeneralRowReflectsStatesAndRoutesToggle() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.LaunchAtLogin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let relay = DashboardPreferencePageRelay()
        var launchAtLoginRequests: [Bool] = []
        relay.onLaunchAtLogin = { launchAtLoginRequests.append($0) }
        let controller = DashboardGeneralPage()
        let page = controller.make(.init(
            preferences: AppPreferences(defaults: defaults),
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
            launchAtLoginState: LaunchAtLoginState(status: .notRegistered)
        ))

        let launchSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
        )
        let launchAtLoginRow = try XCTUnwrap(launchSwitch.superview)
        let launchAtLoginButtons = {
            self.descendants(of: launchAtLoginRow).compactMap { $0 as? NSButton }
        }
        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains { $0.stringValue == "Launch at Login" })
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Automatically start BalanceBar after you log in to your Mac"
        })

        launchSwitch.state = .on
        relay.launchAtLogin(launchSwitch)
        XCTAssertEqual(launchAtLoginRequests, [true])

        controller.refreshLaunchAtLogin(LaunchAtLoginState(status: .requiresApproval))
        XCTAssertEqual(launchSwitch.state, .on)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Automatically start BalanceBar after you log in to your Mac"
        })

        controller.refreshLaunchAtLogin(
            LaunchAtLoginState(status: .notRegistered, notice: .operationFailed)
        )
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Could not update Launch at Login. Check System Settings → General → Login Items and try again."
        })

        controller.refreshLaunchAtLogin(LaunchAtLoginState(status: .unknown))
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Unable to read the login item status"
        })

        controller.refreshLaunchAtLogin(LaunchAtLoginState(status: .notFound))
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Automatically start BalanceBar after you log in to your Mac"
        })
        controller.refreshLaunchAtLogin(LaunchAtLoginState(status: .enabled))
        XCTAssertEqual(launchSwitch.state, .on)
        XCTAssertTrue(launchSwitch.isEnabled)
        XCTAssertTrue(launchAtLoginButtons().isEmpty)
        XCTAssertTrue(labels.contains {
            $0.stringValue == "Automatically start BalanceBar after you log in to your Mac"
        })
        launchSwitch.state = .on
        relay.launchAtLogin(launchSwitch)
        XCTAssertEqual(launchAtLoginRequests, [true, true])
    }

    func testStartupSectionKeepsLaunchRowsIndependentAndRoutesSilentLaunchPreference() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.StartupRows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        for mask in 0..<8 {
            let loginEnabled = mask & 1 != 0
            let silentEnabled = mask & 2 != 0
            let chatGPTEnabled = mask & 4 != 0
            preferences.silentLaunch = silentEnabled

            let page = DashboardGeneralPage().make(.init(
                preferences: preferences,
                currentProviderName: "OpenAI",
                relay: DashboardPreferencePageRelay(),
                updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
                launchAtLoginState: LaunchAtLoginState(
                    status: loginEnabled ? .enabled : .notRegistered
                ),
                launchWithChatGPTState: LaunchWithChatGPTState(
                    status: chatGPTEnabled ? .enabled : .notRegistered
                )
            ))
            let switches = descendants(of: page).compactMap { $0 as? NSSwitch }
            for identifier in [
                LaunchAtLoginController.toggleIdentifier,
                AppPreferences.silentLaunchKey,
                LaunchWithChatGPTController.toggleIdentifier
            ] {
                let matchingSwitches = switches.filter {
                    $0.identifier?.rawValue == identifier
                }
                XCTAssertEqual(matchingSwitches.count, 1)
                guard let matchingSwitch = matchingSwitches.first else { continue }
                XCTAssertFalse(matchingSwitch.isHidden)
                XCTAssertTrue(matchingSwitch.isEnabled)
            }
        }
        preferences.silentLaunch = false
        let relay = DashboardPreferencePageRelay()
        var genericToggleRequests: [(String, Bool)] = []
        var chatGPTRequests: [Bool] = []
        relay.onToggle = { genericToggleRequests.append(($0, $1)) }
        relay.onLaunchWithChatGPT = { chatGPTRequests.append($0) }
        let page = DashboardGeneralPage().make(.init(
            preferences: preferences,
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
            launchAtLoginState: LaunchAtLoginState(status: .enabled),
            launchWithChatGPTState: LaunchWithChatGPTState(status: .requiresApproval)
        ))

        let switches = descendants(of: page).compactMap { $0 as? NSSwitch }
        let launchAtLoginSwitch = try XCTUnwrap(
            switches.first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
        )
        let silentLaunchSwitch = try XCTUnwrap(
            switches.first { $0.identifier?.rawValue == AppPreferences.silentLaunchKey }
        )
        let launchWithChatGPTSwitch = try XCTUnwrap(
            switches.first { $0.identifier?.rawValue == LaunchWithChatGPTController.toggleIdentifier }
        )
        let launchAtLoginRow = try XCTUnwrap(launchAtLoginSwitch.superview)
        XCTAssertTrue(
            descendants(of: launchAtLoginRow).compactMap { $0 as? NSButton }.isEmpty
        )
        let launchWithChatGPTControls = try XCTUnwrap(launchWithChatGPTSwitch.superview)
        let launchWithChatGPTRow = try XCTUnwrap(launchWithChatGPTControls.superview)
        let launchWithChatGPTOpenSettingsButton = try XCTUnwrap(
            descendants(of: launchWithChatGPTRow)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginOpenSettings) }
        )
        XCTAssertEqual(launchAtLoginSwitch.state, .on)
        XCTAssertEqual(silentLaunchSwitch.state, .off)
        XCTAssertEqual(launchWithChatGPTSwitch.state, .on)
        XCTAssertTrue(launchAtLoginSwitch.isEnabled)
        XCTAssertTrue(silentLaunchSwitch.isEnabled)
        XCTAssertTrue(launchWithChatGPTSwitch.isEnabled)
        XCTAssertFalse(launchWithChatGPTOpenSettingsButton.isHidden)

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }.map(\.stringValue)
        let sectionTitles = [
            tr(.keyDashboardGeneralAndRefreshPagesSystem),
            tr(.keyDashboardGeneralAndRefreshPagesRefresh),
            tr(.keyDashboardGeneralAndRefreshPagesStartup),
            tr(.keyDashboardGeneralAndRefreshPagesApplication)
        ]
        let sectionIndexes = try sectionTitles.map { title in
            try XCTUnwrap(labels.firstIndex(of: title), "Missing settings section title: \(title)")
        }
        XCTAssertEqual(sectionIndexes, sectionIndexes.sorted())
        XCTAssertTrue(labels.contains(tr(.keyDashboardGeneralAndRefreshPagesSilentLaunch)))
        XCTAssertTrue(labels.contains(tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPT)))
        XCTAssertTrue(labels.contains(tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPTRequiresApproval)))

        silentLaunchSwitch.state = .on
        relay.toggle(silentLaunchSwitch)
        XCTAssertEqual(genericToggleRequests.count, 1)
        XCTAssertEqual(genericToggleRequests.first?.0, AppPreferences.silentLaunchKey)
        XCTAssertEqual(genericToggleRequests.first?.1, true)
        preferences.silentLaunch = genericToggleRequests[0].1
        XCTAssertTrue(preferences.silentLaunch)

        launchWithChatGPTSwitch.state = .off
        relay.launchWithChatGPT(launchWithChatGPTSwitch)
        XCTAssertEqual(chatGPTRequests, [false])
    }

    func testLaunchAtLoginRowKeepsLongLocalizedTextAndControlSeparatedAcrossWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        for language in [
            AppLanguage.german,
            .french,
            .portuguese,
            .italian,
            .russian
        ] {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.LaunchAtLoginLayout.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let controller = DashboardGeneralPage()
            let page = controller.make(.init(
                preferences: AppPreferences(defaults: defaults),
                currentProviderName: "OpenAI",
                relay: DashboardPreferencePageRelay(),
                updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
                launchAtLoginState: LaunchAtLoginState(status: .notRegistered)
            ))
            let launchSwitch = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSSwitch }
                    .first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
            )
            let subtitle = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription) }
            )
            let labels = try XCTUnwrap(subtitle.superview)
            let row = try XCTUnwrap(labels.superview)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 760),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 760))
            window.contentView = host
            host.addSubview(page)
            defer {
                window.contentView = nil
                window.orderOut(nil)
            }

            for width in [880.0, 800.0, 516.0, 320.0] {
                host.setFrameSize(NSSize(width: width, height: 760))
                page.setFrameSize(host.bounds.size)
                window.layoutIfNeeded()
                page.layoutSubtreeIfNeeded()

                let labelsFrame = labels.convert(labels.bounds, to: row)
                let controlFrame = launchSwitch.convert(launchSwitch.bounds, to: row)
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame),
                    "localized labels stay inside the row for \(language) at \(width)"
                )
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(controlFrame),
                    "launch switch stays inside the row for \(language) at \(width)"
                )
                XCTAssertFalse(
                    labelsFrame.intersects(controlFrame),
                    "localized labels do not overlap launch switch for \(language) at \(width)"
                )
                XCTAssertGreaterThanOrEqual(
                    row.frame.height,
                    DashboardSettingsComponents.standardRowHeight,
                    "launch row preserves its minimum height for \(language) at \(width)"
                )

                controller.refreshLaunchAtLogin(LaunchAtLoginState(status: .requiresApproval))
                window.layoutIfNeeded()
                page.layoutSubtreeIfNeeded()
                let refreshedLabelsFrame = labels.convert(labels.bounds, to: row)
                let switchFrame = launchSwitch.convert(launchSwitch.bounds, to: row)
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(switchFrame),
                    "approval switch stays inside the row for \(language) at \(width)"
                )
                XCTAssertFalse(
                    refreshedLabelsFrame.intersects(switchFrame),
                    "approval switch does not overlap labels for \(language) at \(width)"
                )
                XCTAssertEqual(
                    switchFrame.maxX,
                    row.bounds.maxX - 20,
                    accuracy: 0.5,
                    "launch switch remains trailing-aligned for \(language) at \(width)"
                )
            }
        }
    }

    func testRefreshIntervalPopupsExpandForLongSpanishAndFrenchTitles() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, [String], [String])] = [
            (
                .spanish,
                ["Cada 1 s", "Cada 2 s", "Cada 3 s", "Cada 5 s", "Cada 10 s"],
                ["Desactivado", "Durante 6 s", "Durante 12 s", "Durante 30 s"]
            ),
            (
                .french,
                ["Toutes les 1 s", "Toutes les 2 s", "Toutes les 3 s", "Toutes les 5 s", "Toutes les 10 s"],
                ["Désactivé", "Pendant 6 s", "Pendant 12 s", "Pendant 30 s"]
            )
        ]

        for (language, expectedRunningTitles, expectedTrailingTitles) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.RefreshIntervalPopup.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let page = DashboardGeneralPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                currentProviderName: "OpenAI",
                relay: DashboardPreferencePageRelay(),
                updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6")))
            ))

            let popupControls = descendants(of: page).compactMap { $0 as? NSPopUpButton }
            let runningPopup = try XCTUnwrap(popupControls.first {
                $0.identifier?.rawValue == "codexUsageRefreshInterval"
            })
            let trailingPopup = try XCTUnwrap(popupControls.first {
                $0.identifier?.rawValue == "postCodexRefreshDuration"
            })
            let popups = [runningPopup, trailingPopup]
            XCTAssertEqual(popups[0].itemTitles, expectedRunningTitles)
            XCTAssertEqual(popups[1].itemTitles, expectedTrailingTitles)

            var localizedWidths: [CGFloat] = []
            for popup in popups {
                let width = try XCTUnwrap(
                    popup.constraints
                        .filter { $0.firstAttribute == .width && $0.relation == .equal }
                        .max { $0.constant < $1.constant }
                )
                localizedWidths.append(width.constant)
                XCTAssertGreaterThanOrEqual(
                    width.constant,
                    ceil(popup.fittingSize.width),
                    "\(language) interval popup must fit every localized item title"
                )
            }
            XCTAssertEqual(
                localizedWidths[0],
                localizedWidths[1],
                accuracy: 0.001,
                "\(language) refresh labels and controls must share one right-aligned column"
            )
            XCTAssertGreaterThan(
                localizedWidths.max() ?? 0,
                108,
                "\(language) interval popups must grow when at least one localized item needs more room"
            )
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testBalanceUpdatesDuringTasksUsesOrderedAdaptiveControlsAcrossWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.RefreshControlsLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let relay = DashboardPreferencePageRelay()
        relay.onInterval = { identifier, value in
            switch identifier {
            case "codexUsageRefreshInterval":
                preferences.codexUsageRefreshInterval = value
            case "postCodexRefreshDuration":
                preferences.postCodexRefreshDuration = value
            default:
                break
            }
        }
        let page = DashboardGeneralPage().make(.init(
            preferences: preferences,
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6")))
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        window.contentView = host
        page.frame = host.bounds
        page.autoresizingMask = []
        host.addSubview(page)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        let runningPopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "codexUsageRefreshInterval" }
        )
        let trailingPopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "postCodexRefreshDuration" }
        )
        let runningControls = try XCTUnwrap(runningPopup.superview as? NSStackView)
        let trailingControls = try XCTUnwrap(trailingPopup.superview as? NSStackView)
        let controls = try XCTUnwrap(runningControls.superview as? DashboardAdaptiveControlsStackView)
        let row = try XCTUnwrap(controls.superview)
        let labels = try XCTUnwrap(
            row.subviews
                .compactMap { $0 as? NSStackView }
                .first { $0 !== controls }
        )
        let rowsStack = try XCTUnwrap(row.superview as? NSStackView)
        let card = try XCTUnwrap(rowsStack.superview)
        let separators = rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }

        XCTAssertEqual(controls.arrangedSubviews.count, 2)
        XCTAssertTrue(controls.arrangedSubviews[0] === runningControls)
        XCTAssertTrue(controls.arrangedSubviews[1] === trailingControls)

        func assertCardHeight(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                card.frame.height,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: rowsStack,
                    separators: separators
                ),
                accuracy: 0.5,
                message,
                file: file,
                line: line
            )
        }

        func assertLayout(
            width: CGFloat,
            orientation: NSUserInterfaceLayoutOrientation,
            usesDedicatedRow: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            window.setContentSize(NSSize(width: width, height: 520))
            host.setFrameSize(NSSize(width: width, height: 520))
            page.setFrameSize(host.bounds.size)
            window.layoutIfNeeded()
            page.layoutSubtreeIfNeeded()

            XCTAssertEqual(controls.orientation, orientation, file: file, line: line)
            let runningFrame = runningControls.convert(runningControls.bounds, to: row)
            let trailingFrame = trailingControls.convert(trailingControls.bounds, to: row)
            let labelsFrame = labels.convert(labels.bounds, to: row)
            let controlsFrame = controls.convert(controls.bounds, to: row)
            XCTAssertTrue(
                row.bounds.insetBy(dx: 0, dy: -0.5).contains(runningFrame),
                "running controls stay inside the row",
                file: file,
                line: line
            )
            XCTAssertTrue(
                row.bounds.insetBy(dx: 0, dy: -0.5).contains(trailingFrame),
                "after controls stay inside the row",
                file: file,
                line: line
            )
            if orientation == .horizontal {
                XCTAssertEqual(
                    runningFrame.maxY,
                    trailingFrame.maxY,
                    accuracy: 0.5,
                    "running controls precede after controls on one line",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertGreaterThan(
                    runningFrame.minY,
                    trailingFrame.minY,
                    "running controls remain before after controls in the vertical reflow",
                    file: file,
                    line: line
                )
            }
            if usesDedicatedRow {
                XCTAssertLessThanOrEqual(
                    controlsFrame.maxY,
                    labelsFrame.minY + 0.5,
                    "refresh controls occupy a row below the title and subtitle",
                    file: file,
                    line: line
                )
                XCTAssertGreaterThan(
                    row.frame.height,
                    DashboardSettingsComponents.standardRowHeight,
                    "refresh controls move to a dedicated row at the text line threshold",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertFalse(
                    labelsFrame.intersects(controlsFrame),
                    "refresh controls stay beside the text without overlap",
                    file: file,
                    line: line
                )
                XCTAssertGreaterThanOrEqual(
                    controlsFrame.minX,
                    labelsFrame.maxX + 19.5,
                    "refresh controls stay in the right-side column",
                    file: file,
                    line: line
                )
                XCTAssertGreaterThanOrEqual(
                    row.frame.height,
                    DashboardSettingsComponents.standardRowHeight,
                    "the refresh row grows for its side-by-side content when needed",
                    file: file,
                    line: line
                )
            }
            assertCardHeight("refresh card height follows its adaptive control row", file: file, line: line)
        }

        assertLayout(width: 720, orientation: .horizontal, usesDedicatedRow: false)
        assertLayout(width: 516, orientation: .horizontal, usesDedicatedRow: true)
        assertLayout(width: 320, orientation: .vertical, usesDedicatedRow: true)

        runningPopup.selectItem(at: 4)
        relay.interval(runningPopup)
        trailingPopup.selectItem(at: 2)
        relay.interval(trailingPopup)
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 10)
        XCTAssertEqual(preferences.postCodexRefreshDuration, 12)
        XCTAssertEqual(defaults.double(forKey: "codexUsageRefreshInterval"), 10)
        XCTAssertEqual(defaults.double(forKey: "postCodexRefreshDuration"), 12)
    }

    func testMenuBarIconDisplayModeIsLocalizedFitsAndPersistsAcrossRefresh() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String, [String])] = [
            (
                .simplifiedChinese,
                "菜单栏图标显示",
                "选择始终显示图标，或仅在任务运行时显示",
                ["始终显示", "仅在运行时显示"]
            ),
            (
                .traditionalChineseTaiwan,
                "選單列圖示顯示",
                "選擇始終顯示圖示，或僅在任務執行時顯示",
                ["始終顯示", "僅在執行時顯示"]
            ),
            (
                .traditionalChineseHongKong,
                "選單列圖示顯示",
                "選擇始終顯示圖示，或僅在任務執行時顯示",
                ["始終顯示", "僅在執行時顯示"]
            ),
            (
                .english,
                "Menu Bar Icon Display",
                "Choose to always show the icon, or only while a task is running",
                ["Always Visible", "Only While Running"]
            ),
            (
                .japanese,
                "メニューバーアイコンの表示",
                "アイコンを常に表示するか、タスク実行中のみ表示するかを選択",
                ["常に表示", "実行中のみ表示"]
            ),
            (
                .korean,
                "메뉴 막대 아이콘 표시",
                "아이콘을 항상 표시하거나 작업 실행 중에만 표시하도록 선택",
                ["항상 표시", "실행 중에만 표시"]
            ),
            (
                .spanish,
                "Mostrar el icono de la barra de menús",
                "Elige mostrar siempre el icono o solo mientras se ejecuta una tarea",
                ["Siempre visible", "Solo durante la ejecución"]
            ),
            (
                .german,
                "Anzeige des Menüleistensymbols",
                "Wählen Sie, ob das Symbol immer oder nur während einer laufenden Aufgabe angezeigt wird",
                ["Immer sichtbar", "Nur während der Ausführung"]
            ),
            (
                .french,
                "Affichage de l’icône de la barre des menus",
                "Choisissez d’afficher l’icône toujours ou uniquement pendant l’exécution d’une tâche",
                ["Toujours visible", "Uniquement pendant l’exécution"]
            )
        ]

        for (language, title, subtitle, optionTitles) in cases {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuBarIconDisplayMode.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = AppPreferences(defaults: defaults)
            let relay = DashboardPreferencePageRelay()
            relay.onMenuBarIconDisplayModeChanged = { mode in
                preferences.menuBarIconDisplayMode = mode
            }
            let page = DashboardMenuBarPage().make(.init(
                preferences: preferences,
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: relay,
                statusItemVisibility: .unknown
            ))

            let popup = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconDisplayModeIdentifier }
            )
            XCTAssertEqual(popup.itemTitles, optionTitles, "option titles for \(language)")
            XCTAssertEqual(popup.indexOfSelectedItem, 0)
            XCTAssertEqual(
                popup.itemArray.compactMap { $0.representedObject as? String },
                MenuBarIconDisplayMode.allCases.map(\.rawValue)
            )
            XCTAssertGreaterThanOrEqual(popup.fittingSize.width, 108)
            XCTAssertGreaterThanOrEqual(
                popup.constraints.first {
                    $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual
                }?.constant ?? 0,
                ceil(popup.fittingSize.width)
            )

            let labels = descendants(of: page).compactMap { $0 as? NSTextField }
            XCTAssertTrue(labels.contains { $0.stringValue == title }, "title for \(language)")
            XCTAssertTrue(labels.contains { $0.stringValue == subtitle }, "subtitle for \(language)")

            popup.selectItem(at: 1)
            relay.menuBarIconDisplayMode(popup)
            XCTAssertEqual(preferences.menuBarIconDisplayMode, .onlyWhileRunning)
            XCTAssertEqual(
                defaults.string(forKey: AppPreferences.menuBarIconDisplayModeKey),
                MenuBarIconDisplayMode.onlyWhileRunning.rawValue
            )

            let rebuiltPage = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay(),
                statusItemVisibility: .unknown
            ))
            let rebuiltPopup = try XCTUnwrap(
                descendants(of: rebuiltPage)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconDisplayModeIdentifier }
            )
            XCTAssertEqual(rebuiltPopup.indexOfSelectedItem, 1, "reloaded selection for \(language)")
        }
    }

    func testMenuBarIconDisplayDelaySelectorIsConditionalLocalizedFitsAndPersists() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .english,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french
        ]

        for language in languages {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuBarIconDisplayDelay.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = AppPreferences(defaults: defaults)
            let snapshot = Snapshot.official(
                "OpenAI",
                72,
                "7-day",
                "2h",
                Date(timeIntervalSince1970: 1)
            )
            let controller = DashboardMenuBarPage()
            let relay = DashboardPreferencePageRelay()
            relay.onMenuBarIconDisplayModeChanged = { mode in
                preferences.menuBarIconDisplayMode = mode
                controller.refresh(
                    snapshot: snapshot,
                    preferences: preferences,
                    menuBarSnapshot: { $0 },
                    iconImage: nil
                )
            }
            relay.onMenuBarIconDisplayDelayChanged = { delay in
                preferences.menuBarIconDisplayDelay = delay
            }
            let page = controller.make(.init(
                preferences: preferences,
                snapshot: snapshot,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: relay,
                statusItemVisibility: .unknown
            ))
            page.frame = NSRect(x: 0, y: 0, width: 516, height: 900)
            let window = NSWindow(
                contentRect: page.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            window.layoutIfNeeded()

            let delayPopup = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconDisplayDelayIdentifier }
            )
            let delayRow = try XCTUnwrap(delayPopup.superview)
            let modePopup = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconDisplayModeIdentifier }
            )
            let modeRow = try XCTUnwrap(modePopup.superview)
            let taskStatusSwitch = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSSwitch }
                    .first { $0.identifier?.rawValue == "showMenuBarIcon" }
            )
            let taskStatusRow = try XCTUnwrap(taskStatusSwitch.superview)
            let animationSwitch = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSSwitch }
                    .first { $0.identifier?.rawValue == "animateCodexActivity" }
            )
            let animationRow = try XCTUnwrap(animationSwitch.superview)
            XCTAssertTrue(
                delayRow.isHidden,
                "the delay selector is hidden while Always Visible is selected in (language)"
            )
            let iconTaskStatusRowsStack = try XCTUnwrap(delayRow.superview as? NSStackView)
            let iconRows = iconTaskStatusRowsStack.arrangedSubviews.filter { !($0 is NSBox) }
            XCTAssertTrue(
                zip(iconRows, [taskStatusRow, animationRow, modeRow, delayRow])
                    .allSatisfy { $0.0 === $0.1 },
                "icon/task rows follow task status, animation, display mode, delay order in (language)"
            )
            let iconTaskStatusSeparators = iconTaskStatusRowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
            XCTAssertEqual(iconTaskStatusSeparators.count, 3)
            XCTAssertFalse(
                iconTaskStatusSeparators[0].isHidden,
                "the divider between task status and animation is visible in (language)"
            )
            XCTAssertFalse(
                iconTaskStatusSeparators[1].isHidden,
                "the divider between animation and display mode is visible in (language)"
            )
            XCTAssertTrue(
                iconTaskStatusSeparators[2].isHidden,
                "the divider after display mode is collapsed with hidden delay in (language)"
            )
            XCTAssertFalse(taskStatusRow.isHidden)
            XCTAssertFalse(animationRow.isHidden)
            XCTAssertFalse(modeRow.isHidden)
            if language == .simplifiedChinese {
                XCTAssertEqual(
                    modeRow.frame.height,
                    DashboardSettingsComponents.standardRowHeight,
                    accuracy: 1,
                    "Always Visible keeps the display-mode row at one-row height"
                )
            }
            XCTAssertEqual(
                delayPopup.itemTitles,
                [
                    tr(.keyDashboardMenuBarPageIconDisplayDelayZeroSeconds, language: language),
                    tr(.keyDashboardMenuBarPageIconDisplayDelayTenSeconds, language: language),
                    tr(.keyDashboardMenuBarPageIconDisplayDelayThirtySeconds, language: language),
                    tr(.keyDashboardMenuBarPageIconDisplayDelayOneMinute, language: language),
                    tr(.keyDashboardMenuBarPageIconDisplayDelayTwoMinutes, language: language),
                    tr(.keyDashboardMenuBarPageIconDisplayDelayThreeMinutes, language: language)
                ],
                "delay option titles for (language)"
            )
            XCTAssertEqual(
                delayPopup.itemArray.compactMap { $0.representedObject as? String },
                MenuBarIconDisplayDelay.allCases.map(\.rawValue)
            )
            XCTAssertGreaterThanOrEqual(delayPopup.fittingSize.width, 108)
            XCTAssertGreaterThanOrEqual(
                delayPopup.constraints.first {
                    $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual
                }?.constant ?? 0,
                ceil(delayPopup.fittingSize.width)
            )
            let labels = descendants(of: delayRow).compactMap { $0 as? NSTextField }
            XCTAssertTrue(
                labels.contains {
                    $0.stringValue == tr(
                        .keyDashboardMenuBarPageIconDisplayDelay,
                        language: language
                    )
                },
                "delay title for (language)"
            )
            XCTAssertTrue(
                labels.contains {
                    $0.stringValue == tr(
                        .keyDashboardMenuBarPageIconDisplayDelayDescription,
                        language: language
                    )
                },
                "delay subtitle for (language)"
            )
            XCTAssertFalse(delayPopup.itemTitles.contains { $0.hasPrefix("⟦") })

            modePopup.selectItem(at: 1)
            relay.menuBarIconDisplayMode(modePopup)
            window.layoutIfNeeded()
            XCTAssertEqual(preferences.menuBarIconDisplayMode, .onlyWhileRunning)
            XCTAssertFalse(
                delayRow.isHidden,
                "changing to Only While Running reveals the delay selector immediately in (language)"
            )
            XCTAssertTrue(
                iconTaskStatusSeparators.allSatisfy { !$0.isHidden },
                "all display dividers are visible with the delay selector in (language)"
            )

            delayPopup.selectItem(at: 0)
            relay.menuBarIconDisplayDelay(delayPopup)
            XCTAssertEqual(preferences.menuBarIconDisplayDelay, .zeroSeconds)
            XCTAssertEqual(
                defaults.string(forKey: AppPreferences.menuBarIconDisplayDelayKey),
                MenuBarIconDisplayDelay.zeroSeconds.rawValue
            )

            delayPopup.selectItem(at: MenuBarIconDisplayDelay.allCases.count - 1)
            relay.menuBarIconDisplayDelay(delayPopup)
            XCTAssertEqual(preferences.menuBarIconDisplayDelay, .threeMinutes)
            XCTAssertEqual(
                defaults.string(forKey: AppPreferences.menuBarIconDisplayDelayKey),
                MenuBarIconDisplayDelay.threeMinutes.rawValue
            )

            preferences.menuBarIconDisplayMode = .alwaysVisible
            controller.refresh(
                snapshot: snapshot,
                preferences: preferences,
                menuBarSnapshot: { $0 },
                iconImage: nil
            )
            window.layoutIfNeeded()
            XCTAssertTrue(delayRow.isHidden, "switching back hides the delay selector in (language)")
            XCTAssertFalse(
                iconTaskStatusSeparators[0].isHidden,
                "the divider between task status and animation remains visible after switching back in (language)"
            )
            XCTAssertFalse(
                iconTaskStatusSeparators[1].isHidden,
                "the divider between animation and display mode remains visible after switching back in (language)"
            )
            XCTAssertTrue(
                iconTaskStatusSeparators[2].isHidden,
                "the divider after display mode is collapsed after switching back in (language)"
            )

            relay.onToggle = { identifier, enabled in
                guard identifier == "showMenuBarIcon" else { return }
                preferences.showMenuBarIcon = enabled
                controller.refresh(
                    snapshot: snapshot,
                    preferences: preferences,
                    menuBarSnapshot: { $0 },
                    iconImage: nil
                )
            }
            taskStatusSwitch.state = .off
            relay.toggle(taskStatusSwitch)
            window.layoutIfNeeded()
            XCTAssertFalse(taskStatusRow.isHidden)
            XCTAssertTrue(animationRow.isHidden)
            XCTAssertTrue(modeRow.isHidden)
            XCTAssertTrue(delayRow.isHidden)
            XCTAssertTrue(
                iconTaskStatusSeparators.allSatisfy(\.isHidden),
                "dependent icon rows have no stray separators when task status icon is off in (language)"
            )

            taskStatusSwitch.state = .on
            relay.toggle(taskStatusSwitch)
            window.layoutIfNeeded()
            XCTAssertFalse(animationRow.isHidden)
            XCTAssertFalse(modeRow.isHidden)
            XCTAssertTrue(delayRow.isHidden)

            let rebuiltPage = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: snapshot,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay(),
                statusItemVisibility: .unknown
            ))
            let rebuiltDelayPopup = try XCTUnwrap(
                descendants(of: rebuiltPage)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.iconDisplayDelayIdentifier }
            )
            XCTAssertEqual(rebuiltDelayPopup.indexOfSelectedItem, 5)
            window.contentView = nil
        }
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
                StatusLinksEditorView(links: [], onLinksChanged: { _ in }, onReset: { [] })
            },
            onBalanceDisplayThresholdChanged: { value in
                changedValues.append(value)
                preferences.balanceDisplayThreshold = value
            }
        ))

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.first { $0.stringValue == "余额显示" }?.stringValue, "余额显示")
        XCTAssertEqual(labels.first { $0.stringValue == "低余额警示阈值" }?.stringValue, "低余额警示阈值")
        XCTAssertEqual(
            labels.first { $0.stringValue == "充值后若余额仍低于此金额，进度条继续显示为红色" }?.stringValue,
            "充值后若余额仍低于此金额，进度条继续显示为红色"
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

    func testLunaReserveMenuDisplaySettingsLocalizePersistAndRevealExhaustedQuotaSwitch() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.LunaReserveDisplayMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let controller = DashboardMenuPage()
        let relay = DashboardPreferencePageRelay()
        var changedModes: [LunaReserveDisplayMode] = []
        relay.onLunaReserveDisplayModeChanged = { mode in
            changedModes.append(mode)
            preferences.menuLunaReserveDisplayMode = mode
            controller.refresh(preferences: preferences)
        }
        relay.onToggle = { identifier, enabled in
            if identifier == AppPreferences.menuLunaReserveHideExhaustedQuotaKey {
                preferences.menuLunaReserveHideExhaustedQuota = enabled
            }
        }

        let page = controller.make(.init(
            preferences: preferences,
            relay: relay,
            makeStatusLinksEditor: {
                StatusLinksEditorView(links: [], onLinksChanged: { _ in }, onReset: { [] })
            },
            onBalanceDisplayThresholdChanged: { _ in }
        ))
        page.frame = NSRect(x: 0, y: 0, width: 516, height: 900)
        let window = NSWindow(
            contentRect: page.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        window.layoutIfNeeded()
        defer {
            window.contentView = nil
            controller.teardown()
        }

        let displayModeControl = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == DashboardMenuPage.lunaReserveDisplayModeIdentifier }
        )
        XCTAssertEqual(
            displayModeControl.itemTitles,
            ["不显示", "额度用完后显示", "始终显示"]
        )
        XCTAssertEqual(displayModeControl.indexOfSelectedItem, 2)
        XCTAssertEqual(
            displayModeControl.action,
            #selector(DashboardPreferencePageRelay.lunaReserveDisplayMode(_:))
        )

        let displayModeRow = try XCTUnwrap(displayModeControl.superview)
        let hideSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == DashboardMenuPage.lunaReserveHideExhaustedQuotaIdentifier }
        )
        let hideRow = try XCTUnwrap(hideSwitch.superview)
        XCTAssertTrue(
            descendants(of: displayModeRow).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == "🌙 Luna 储备额度显示方式"
            }
        )
        XCTAssertTrue(
            descendants(of: displayModeRow).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == "选择 Luna 储备额度 在菜单中的显示时机"
            }
        )
        let thresholdField = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == AppPreferences.balanceDisplayThresholdKey }
        )
        let thresholdRow = try XCTUnwrap(thresholdField.superview)
        let rowsStack = try XCTUnwrap(displayModeRow.superview as? NSStackView)
        XCTAssertEqual(
            Array(rowsStack.arrangedSubviews.filter { !($0 is NSBox) }.prefix(3)).map(ObjectIdentifier.init),
            [displayModeRow, hideRow, thresholdRow].map(ObjectIdentifier.init)
        )
        XCTAssertFalse(hideRow.isHidden)
        XCTAssertTrue(hideSwitch.isEnabled)

        displayModeControl.selectItem(at: 1)
        relay.lunaReserveDisplayMode(displayModeControl)
        XCTAssertEqual(changedModes, [.whenQuotaExhausted])
        XCTAssertEqual(preferences.menuLunaReserveDisplayMode, .whenQuotaExhausted)
        XCTAssertFalse(hideRow.isHidden)
        XCTAssertTrue(hideSwitch.isEnabled)
        XCTAssertEqual(hideSwitch.state, .off)

        hideSwitch.state = .on
        relay.toggle(hideSwitch)
        XCTAssertTrue(preferences.menuLunaReserveHideExhaustedQuota)

        displayModeControl.selectItem(at: 2)
        relay.lunaReserveDisplayMode(displayModeControl)
        XCTAssertEqual(changedModes, [.whenQuotaExhausted, .always])
        XCTAssertEqual(preferences.menuLunaReserveDisplayMode, .always)
        XCTAssertFalse(hideRow.isHidden)
        XCTAssertTrue(hideSwitch.isEnabled)
        XCTAssertEqual(hideSwitch.state, .on)

        displayModeControl.selectItem(at: 0)
        relay.lunaReserveDisplayMode(displayModeControl)
        XCTAssertEqual(changedModes, [.whenQuotaExhausted, .always, .disabled])
        XCTAssertTrue(hideRow.isHidden)
        XCTAssertFalse(hideSwitch.isEnabled)
        XCTAssertEqual(
            AppPreferences(defaults: defaults).menuLunaReserveDisplayMode,
            .disabled
        )
        XCTAssertTrue(AppPreferences(defaults: defaults).menuLunaReserveHideExhaustedQuota)

        displayModeControl.selectItem(at: 2)
        relay.lunaReserveDisplayMode(displayModeControl)
        XCTAssertFalse(hideRow.isHidden)
        XCTAssertTrue(hideSwitch.isEnabled)
        XCTAssertEqual(hideSwitch.state, .on)

        hideSwitch.state = .off
        relay.toggle(hideSwitch)
        XCTAssertFalse(preferences.menuLunaReserveHideExhaustedQuota)
    }

    func testMenuEntryRowsLocalizeSubtitlesAndPreserveControlsAcrossLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, [String], [String])] = [
            (
                .simplifiedChinese,
                ["打开主窗口", "打开 ChatGPT", "打开 CC Switch", "打开 OpenCodex"],
                ["显示 BalanceBar 主窗口", "显示 ChatGPT", "显示 CC Switch 主窗口", "显示 OpenCodex 控制台"]
            ),
            (
                .traditionalChineseTaiwan,
                ["開啟主視窗", "開啟 ChatGPT", "開啟 CC Switch", "開啟 OpenCodex"],
                ["顯示 BalanceBar 主視窗", "顯示 ChatGPT", "顯示 CC Switch 主視窗", "顯示 OpenCodex 控制台"]
            ),
            (
                .traditionalChineseHongKong,
                ["開啟主視窗", "開啟 ChatGPT", "開啟 CC Switch", "開啟 OpenCodex"],
                ["顯示 BalanceBar 主視窗", "顯示 ChatGPT", "顯示 CC Switch 主視窗", "顯示 OpenCodex 控制台"]
            ),
            (
                .japanese,
                ["メインウインドウを開く", "ChatGPT を開く", "CC Switch を開く", "OpenCodex を開く"],
                ["BalanceBar のメインウインドウを表示", "ChatGPT を表示", "CC Switch のメインウインドウを表示", "OpenCodex コンソールを表示"]
            ),
            (
                .english,
                ["Open Main Window", "Open ChatGPT", "Open CC Switch", "Open OpenCodex"],
                ["Show the BalanceBar main window", "Show ChatGPT", "Show the CC Switch main window", "Show the OpenCodex console"]
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
                    StatusLinksEditorView(links: [], onLinksChanged: { _ in }, onReset: { [] })
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

    func testMenuPageStatusLinksCardRemeasuresItsRowAndEditorAcrossVisibilityChanges() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.StatusLinksCard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showStatusMenu = true
        let controller = DashboardMenuPage()
        let page = controller.make(.init(
            preferences: preferences,
            relay: DashboardPreferencePageRelay(),
            makeStatusLinksEditor: {
                StatusLinksEditorView(
                    links: [StatusLink(title: "Status", url: "https://status.example")],
                    onLinksChanged: { _ in },
                    onReset: { [] }
                )
            },
            onBalanceDisplayThresholdChanged: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 516, height: 820),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer { window.orderOut(nil) }

        let subtitle = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks) }
        )
        let statusRow = try XCTUnwrap(subtitle.superview?.superview)
        let rowsStack = try XCTUnwrap(statusRow.superview as? NSStackView)
        let card = try XCTUnwrap(rowsStack.superview)
        let editor = try XCTUnwrap(descendants(of: page).compactMap { $0 as? StatusLinksEditorView }.first)
        let statusSwitch = try XCTUnwrap(
            descendants(of: statusRow)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == "showStatusMenu" }
        )
        let separators = rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
        XCTAssertEqual(separators.count, 1)
        XCTAssertFalse(separators[0].isHidden)
        XCTAssertTrue(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == tr(.keyDashboardMenuPageStatusLinks) }
        )
        let quickLinkSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == "showOpenDashboardMenu" }
        )
        let quickLinkRow = try XCTUnwrap(quickLinkSwitch.superview)
        let quickLinkRowsStack = try XCTUnwrap(quickLinkRow.superview as? NSStackView)
        XCTAssertFalse(quickLinkRowsStack === rowsStack)
        let statusLabels = try XCTUnwrap(
            statusRow.subviews
                .compactMap { $0 as? NSStackView }
                .first
        )

        func expectedCardHeight() -> CGFloat {
            DashboardSettingsComponents.settingsCardHeight(
                rowsStack: rowsStack,
                separators: separators
            )
        }

        func layout(at width: CGFloat) -> (statusRowHeight: CGFloat, cardHeight: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 820))
            window.layoutIfNeeded()
            XCTAssertEqual(card.frame.height, expectedCardHeight(), accuracy: 0.5)
            let statusLabelsFrame = statusLabels.convert(statusLabels.bounds, to: statusRow)
            let statusSwitchFrame = statusSwitch.convert(statusSwitch.bounds, to: statusRow)
            if statusSwitchFrame.maxY <= statusLabelsFrame.minY + 0.5 {
                XCTAssertGreaterThan(statusRow.frame.height, DashboardSettingsComponents.standardRowHeight)
            } else {
                XCTAssertEqual(statusSwitch.frame.midY, statusRow.bounds.midY, accuracy: 0.5)
            }
            XCTAssertEqual(editor.frame.height, editor.currentHeight, accuracy: 0.5)
            return (statusRow.frame.height, card.frame.height)
        }

        let longSubtitle = "This status-link summary is intentionally long so the Status Links row must reflow its switch without truncating the complete text after every width and content transition."
        subtitle.stringValue = longSubtitle
        subtitle.invalidateIntrinsicContentSize()
        statusRow.needsLayout = true
        let narrow = layout(at: 516)
        XCTAssertFalse(subtitle.usesSingleLineMode)
        XCTAssertEqual(subtitle.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(
            subtitle.maximumNumberOfLines,
            DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines,
            "status subtitle remains uncapped so the complete text is measurable"
        )
        XCTAssertTrue(subtitle.cell?.wraps == true)
        XCTAssertGreaterThan(narrow.statusRowHeight, 62)
        let wide = layout(at: 740)
        XCTAssertLessThan(wide.statusRowHeight, narrow.statusRowHeight)
        XCTAssertLessThan(wide.cardHeight, narrow.cardHeight)
        let narrowAgain = layout(at: 516)
        XCTAssertEqual(narrowAgain.statusRowHeight, narrow.statusRowHeight, accuracy: 0.5)
        XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5)

        subtitle.stringValue = "Short status summary"
        subtitle.invalidateIntrinsicContentSize()
        statusRow.needsLayout = true
        let short = layout(at: 516)
        XCTAssertLessThan(short.statusRowHeight, narrow.statusRowHeight)
        subtitle.stringValue = longSubtitle
        subtitle.invalidateIntrinsicContentSize()
        statusRow.needsLayout = true
        let restored = layout(at: 516)
        XCTAssertEqual(restored.statusRowHeight, narrow.statusRowHeight, accuracy: 0.5)
        XCTAssertEqual(restored.cardHeight, narrow.cardHeight, accuracy: 0.5)

        for visible in [false, true, false, true, false, true] {
            controller.updateStatusVisibility(visible, animated: false)
            XCTAssertEqual(separators[0].isHidden, !visible)
            _ = layout(at: 516)
        }
        XCTAssertEqual(editor.currentHeight, editor.layoutHeight, accuracy: 0.5)
        XCTAssertEqual(card.frame.height, expectedCardHeight(), accuracy: 0.5)
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

    func testMenuBarOverflowWarningUsesInjectedVisibilityAndAllSupportedLocalizations() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "菜单栏空间不足，BalanceBar 暂时不可见；请关闭或移除部分菜单栏图标后重试。", "打开设置"),
            (.english, "Menu bar space is full, so BalanceBar is temporarily hidden; hide or remove some menu bar icons and try again.", "Open Settings"),
            (.traditionalChineseTaiwan, "選單列空間不足，BalanceBar 暫時不可見；請關閉或移除部分選單列圖示後重試。", "開啟設定"),
            (.traditionalChineseHongKong, "選單列空間不足，BalanceBar 暫時不可見；請關閉或移除部分選單列圖示後再試。", "開啟設定"),
            (.japanese, "メニューバーの空き容量が不足しているためBalanceBarは一時的に非表示です。ほかのメニューバーアイコンを隠すか削除してから再試行してください。", "設定を開く"),
            (.korean, "메뉴 막대 공간이 부족하여 BalanceBar가 일시적으로 숨겨졌습니다; 일부 메뉴 막대 아이콘을 숨기거나 제거한 후 다시 시도하세요.", "설정 열기"),
            (.spanish, "No queda espacio en la barra de menús, por lo que BalanceBar está oculto temporalmente; oculta o elimina algunos iconos de la barra de menús y vuelve a intentarlo.", "Abrir ajustes"),
            (.german, "Der Platz in der Menüleiste ist voll, daher ist BalanceBar vorübergehend ausgeblendet; weitere Menüleistensymbole ausblenden oder entfernen und erneut versuchen.", "Einstellungen öffnen")
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
            XCTAssertFalse(warningLabel.usesSingleLineMode)
            XCTAssertEqual(warningLabel.maximumNumberOfLines, 0)
            XCTAssertEqual(warningLabel.lineBreakMode, .byWordWrapping)
            XCTAssertEqual(warningLabel.font?.pointSize ?? .nan, 12, accuracy: 0.001)
            let warningRowHeight = try XCTUnwrap(
                warningRow.constraints.first {
                    $0.firstAttribute == .height && $0.relation == .equal
                }?.constant
            )
            XCTAssertEqual(warningRowHeight, DashboardSettingsComponents.standardRowHeight)

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

    func testMenuBarPendingVisibilityDoesNotRebuildDashboardHierarchy() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "DashboardPreferencePagesTests.MenuBarPendingVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let controller = DashboardMenuBarPage()
        let snapshot = Snapshot.official(
            "OpenAI",
            72,
            "7-day",
            "2h",
            Date(timeIntervalSince1970: 1)
        )
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: snapshot,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay(),
            statusItemVisibility: .hiddenByMenuBarSpace
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        page.layoutSubtreeIfNeeded()

        let warningRow = try XCTUnwrap(
            descendant(
                withIdentifier: DashboardMenuBarPage.overflowWarningRowIdentifier,
                in: page
            )
        )
        let rowsStack = try XCTUnwrap(warningRow.superview as? NSStackView)
        let previewCard = try XCTUnwrap(rowsStack.superview)
        let separator = try XCTUnwrap(
            rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }.first
        )
        let scrollView = try XCTUnwrap(
            page.subviews
                .flatMap { descendants(of: $0) }
                .compactMap { $0 as? NSScrollView }
                .first
        )
        let documentView = try XCTUnwrap(scrollView.documentView)
        let initialCardHeight = previewCard.frame.height
        let initialDocumentFrame = documentView.frame
        let initialDocumentBounds = documentView.bounds
        let initialScrollBounds = scrollView.contentView.bounds

        XCTAssertGreaterThan(initialCardHeight, 0)
        XCTAssertGreaterThan(initialDocumentFrame.height, 0)
        XCTAssertFalse(warningRow.isHidden)
        XCTAssertFalse(separator.isHidden)

        // Repeated committed-hidden refreshes model the Dashboard input while
        // the visibility state machine is confirming changing geometry. They
        // must update in place rather than rebuild the warning/card/document
        // hierarchy or move the scroll viewport.
        for _ in 0..<8 {
            controller.refresh(
                snapshot: snapshot,
                preferences: preferences,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                statusItemVisibility: .hiddenByMenuBarSpace
            )
            window.layoutIfNeeded()
            XCTAssertEqual(ObjectIdentifier(warningRow), ObjectIdentifier(
                try XCTUnwrap(
                    descendant(
                        withIdentifier: DashboardMenuBarPage.overflowWarningRowIdentifier,
                        in: page
                    )
                )
            ))
            XCTAssertEqual(ObjectIdentifier(rowsStack), ObjectIdentifier(
                try XCTUnwrap(warningRow.superview)
            ))
            XCTAssertEqual(ObjectIdentifier(previewCard), ObjectIdentifier(rowsStack.superview!))
            XCTAssertEqual(ObjectIdentifier(scrollView), ObjectIdentifier(
                try XCTUnwrap(
                    page.subviews
                        .flatMap { descendants(of: $0) }
                        .compactMap { $0 as? NSScrollView }
                        .first
                )
            ))
            XCTAssertTrue(scrollView.documentView === documentView)
            XCTAssertFalse(warningRow.isHidden)
            XCTAssertFalse(separator.isHidden)
            XCTAssertEqual(previewCard.frame.height, initialCardHeight, accuracy: 0.5)
            XCTAssertEqual(documentView.frame, initialDocumentFrame)
            XCTAssertEqual(documentView.bounds, initialDocumentBounds)
            XCTAssertEqual(scrollView.contentView.bounds, initialScrollBounds)
        }

        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            statusItemVisibility: .visible
        )
        window.layoutIfNeeded()
        XCTAssertTrue(warningRow.isHidden)
        XCTAssertTrue(separator.isHidden)

        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            statusItemVisibility: .hiddenByMenuBarSpace
        )
        window.layoutIfNeeded()
        XCTAssertFalse(warningRow.isHidden)
        XCTAssertFalse(separator.isHidden)
        XCTAssertTrue(scrollView.documentView === documentView)
    }

    func testCodexActivityAnimationBelongsToMenuBarWithLocalizedTaskOrientedSectionOrder() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String)] = [
            (.simplifiedChinese, "任务运行时播放菜单栏图标动画"),
            (.english, "Animate the menu bar icon while a task runs"),
            (.traditionalChineseTaiwan, "任務執行時播放選單列圖示動畫"),
            (.traditionalChineseHongKong, "任務執行時播放選單列圖示動畫"),
            (.japanese, "タスク実行中にメニューバーアイコンをアニメーション"),
            (.korean, "작업 실행 중 메뉴 막대 아이콘 애니메이션"),
            (.spanish, "Anima el icono de la barra de menús mientras se ejecuta una tarea"),
            (.german, "Menüleistensymbol während einer Aufgabe animieren"),
            (.french, "Animer l’icône de la barre des menus pendant une tâche")
        ]

        for (language, animationRowTitle) in cases {
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
            guard let previewIndex = labelStrings.firstIndex(of: tr(.keyDashboardMenuBarPagePreview, language: language)),
                  let quotaAndResetIndex = labelStrings.firstIndex(of: tr(.keyDashboardMenuBarPageQuotaAndReset, language: language)),
                  let iconAndTaskStatusIndex = labelStrings.firstIndex(of: tr(.keyDashboardMenuBarPageIconAndTaskStatus, language: language)),
                  let layoutIndex = labelStrings.firstIndex(of: tr(.keyDashboardMenuBarPageLayout, language: language)) else {
                defaults.removePersistentDomain(forName: suiteName)
                return XCTFail("Expected menu bar section headings for \(language)")
            }
            let sectionIndices = [
                previewIndex,
                quotaAndResetIndex,
                iconAndTaskStatusIndex,
                layoutIndex
            ]
            XCTAssertEqual(sectionIndices, sectionIndices.sorted())
            XCTAssertEqual(Set(sectionIndices).count, sectionIndices.count)
            let quotaRowTitles = [
                tr(.keyDashboardMenuBarPageBalanceAmount, language: language),
                tr(.keyDashboardMenuBarPageResetCountdown, language: language),
                tr(.keyDashboardMenuBarPageQuotaDisplayPriority, language: language),
                tr(.keyDashboardMenuBarPageQuotaResetDisplayMode, language: language)
            ]
            let quotaRowIndices = quotaRowTitles.compactMap { labelStrings.firstIndex(of: $0) }
            XCTAssertEqual(quotaRowIndices.count, quotaRowTitles.count)
            XCTAssertEqual(quotaRowIndices, quotaRowIndices.sorted())
            let iconRowTitles = [
                tr(.keyDashboardMenuBarPageAgentIcon, language: language),
                animationRowTitle,
                tr(.keyDashboardMenuBarPageIconDisplayMode, language: language),
                tr(.keyDashboardMenuBarPageIconDisplayDelay, language: language)
            ]
            let iconRowIndices = iconRowTitles.compactMap { labelStrings.firstIndex(of: $0) }
            XCTAssertEqual(iconRowIndices.count, iconRowTitles.count)
            XCTAssertEqual(iconRowIndices, iconRowIndices.sorted())
            XCTAssertFalse(
                labelStrings.contains(tr(.keyDashboardMenuBarPageDisplayItems, language: language)),
                "the legacy mixed display-content heading is no longer shown in \(language)"
            )
            XCTAssertFalse(
                labelStrings.contains(tr(.keyDashboardMenuBarPageAnimation, language: language)),
                "animation is a row under Icon & Task Status, not a separate section in \(language)"
            )
            XCTAssertEqual(labelStrings.filter { $0 == animationRowTitle }.count, 1)

            let animationSwitches = descendants(of: menuBarPage)
                .compactMap { $0 as? NSSwitch }
                .filter { $0.identifier?.rawValue == "animateCodexActivity" }
            XCTAssertEqual(animationSwitches.count, 1)
            let animationRow = try XCTUnwrap(animationSwitches.first?.superview)
            let iconTaskStatusRowsStack = try XCTUnwrap(animationRow.superview as? NSStackView)
            XCTAssertTrue(
                iconTaskStatusRowsStack.arrangedSubviews.contains { $0 === animationRow },
                "animation belongs to Icon & Task Status in \(language)"
            )

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
            XCTAssertFalse(advancedLabels.contains {
                $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesCodexTaskStatusDetection, language: language)
            })
            XCTAssertTrue(
                descendants(of: advancedPage)
                    .compactMap { $0 as? NSSwitch }
                    .filter { $0.identifier?.rawValue == "animateCodexActivity" }
                    .isEmpty
            )
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testMenuBarQuotaRowsFollowVisibilityDependenciesAndRequestedOrder() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "DashboardPreferencePagesTests.MenuBarQuotaVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let controller = DashboardMenuBarPage()
        let relay = DashboardPreferencePageRelay()
        let snapshot = Snapshot.official(
            "OpenAI",
            72,
            "7-day",
            "2h",
            Date(timeIntervalSince1970: 1)
        )
        func refreshPage() {
            controller.refresh(
                snapshot: snapshot,
                preferences: preferences,
                menuBarSnapshot: { $0 },
                iconImage: nil
            )
        }
        relay.onToggle = { identifier, enabled in
            switch identifier {
            case "showMenuBarAmount":
                preferences.showMenuBarAmount = enabled
            case "showMenuBarReset":
                preferences.showMenuBarReset = enabled
            case AppPreferences.menuBarAutoSwitchLunaReserveKey:
                preferences.menuBarAutoSwitchLunaReserve = enabled
            default:
                return
            }
            refreshPage()
        }
        relay.onMenuBarLunaReserveResetTimeModeChanged = { mode in
            preferences.menuBarLunaReserveResetTimeMode = mode
            refreshPage()
        }
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: snapshot,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: relay
        ))
        page.frame = NSRect(x: 0, y: 0, width: 516, height: 900)
        let window = NSWindow(
            contentRect: page.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        let amountSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == "showMenuBarAmount" }
        )
        let resetSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == "showMenuBarReset" }
        )
        let autoSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.autoSwitchLunaReserveIdentifier }
        )
        let quotaWindowPopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaWindowPreferenceIdentifier }
        )
        let quotaResetPopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaResetDisplayModeIdentifier }
        )
        let lunaReserveResetTimePopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == DashboardMenuBarPage.lunaReserveResetTimeModeIdentifier }
        )
        let amountRow = try XCTUnwrap(amountSwitch.superview)
        let resetRow = try XCTUnwrap(resetSwitch.superview)
        let autoSwitchRow = try XCTUnwrap(autoSwitch.superview)
        let quotaWindowRow = try XCTUnwrap(quotaWindowPopup.superview)
        let lunaReserveResetTimeRow = try XCTUnwrap(lunaReserveResetTimePopup.superview)
        let quotaResetRow = try XCTUnwrap(quotaResetPopup.superview)
        let rowsStack = try XCTUnwrap(amountRow.superview as? NSStackView)
        let card = try XCTUnwrap(rowsStack.superview)
        let rowViews = rowsStack.arrangedSubviews.filter { !($0 is NSBox) }
        XCTAssertTrue(
            zip(
                rowViews,
                [amountRow, resetRow, quotaWindowRow, quotaResetRow, autoSwitchRow, lunaReserveResetTimeRow]
            )
                .allSatisfy { $0.0 === $0.1 }
        )
        let separators = rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
        XCTAssertEqual(separators.count, 5)

        func assertCardLayout() {
            window.layoutIfNeeded()
            XCTAssertEqual(
                card.frame.height,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: rowsStack,
                    separators: separators
                ),
                accuracy: 0.5
            )
        }

        XCTAssertTrue([amountRow, resetRow, quotaWindowRow, autoSwitchRow, quotaResetRow].allSatisfy { !$0.isHidden })
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)
        XCTAssertTrue(separators.dropLast().allSatisfy { !$0.isHidden })
        XCTAssertTrue(separators.last?.isHidden == true)
        assertCardLayout()

        autoSwitch.state = .on
        relay.toggle(autoSwitch)
        XCTAssertTrue(preferences.menuBarAutoSwitchLunaReserve)
        XCTAssertFalse(lunaReserveResetTimeRow.isHidden)
        XCTAssertEqual(
            lunaReserveResetTimePopup.itemTitles,
            [
                tr(.keyDashboardMenuBarPageLunaReserveResetTimeOriginalQuota),
                tr(
                    .keyDashboardMenuBarPageLunaReserveResetTimeLunaReserve,
                    arguments: [tr(.keyLunaReserveTitle)]
                )
            ]
        )
        lunaReserveResetTimePopup.selectItem(at: 0)
        relay.menuBarLunaReserveResetTimeMode(lunaReserveResetTimePopup)
        XCTAssertEqual(preferences.menuBarLunaReserveResetTimeMode, .originalQuota)
        autoSwitch.state = .off
        relay.toggle(autoSwitch)
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)

        amountSwitch.state = .off
        relay.toggle(amountSwitch)
        XCTAssertFalse(amountRow.isHidden)
        XCTAssertTrue(resetRow.isHidden)
        XCTAssertTrue(quotaWindowRow.isHidden)
        XCTAssertTrue(autoSwitchRow.isHidden)
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)
        XCTAssertTrue(quotaResetRow.isHidden)
        XCTAssertTrue(separators.allSatisfy(\.isHidden))
        assertCardLayout()

        amountSwitch.state = .on
        relay.toggle(amountSwitch)
        XCTAssertFalse(resetRow.isHidden)
        XCTAssertFalse(quotaWindowRow.isHidden)
        XCTAssertFalse(autoSwitchRow.isHidden)
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)
        XCTAssertFalse(quotaResetRow.isHidden)
        XCTAssertTrue(separators.dropLast().allSatisfy { !$0.isHidden })
        XCTAssertTrue(separators.last?.isHidden == true)

        resetSwitch.state = .off
        relay.toggle(resetSwitch)
        XCTAssertFalse(amountRow.isHidden)
        XCTAssertFalse(resetRow.isHidden)
        XCTAssertTrue(quotaWindowRow.isHidden)
        XCTAssertFalse(autoSwitchRow.isHidden)
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)
        XCTAssertTrue(quotaResetRow.isHidden)
        XCTAssertFalse(separators[0].isHidden)
        XCTAssertFalse(separators[1].isHidden)
        XCTAssertTrue(separators[2].isHidden)
        XCTAssertTrue(separators[3].isHidden)
        XCTAssertTrue(separators[4].isHidden)
        assertCardLayout()

        resetSwitch.state = .on
        relay.toggle(resetSwitch)
        XCTAssertTrue([amountRow, resetRow, quotaWindowRow, autoSwitchRow, quotaResetRow].allSatisfy { !$0.isHidden })
        XCTAssertTrue(lunaReserveResetTimeRow.isHidden)
        XCTAssertTrue(separators.dropLast().allSatisfy { !$0.isHidden })
        XCTAssertTrue(separators.last?.isHidden == true)
        assertCardLayout()
    }

    func testQuotaWindowPreferenceSelectorUsesLocalizedOptionsPersistsAndKeepsLayoutStable() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french,
            .english
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5-hour",
                daysText: "5 hours",
                reset: "1h0m",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: "7-day",
                daysText: "7 days",
                reset: "1h30m",
                durationSeconds: 604_800
            )
        ]
        let snapshot = Snapshot.official(
            "OpenAI",
            45,
            "7-day",
            "1h30m",
            date,
            windows: windows
        )

        for language in languages {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.QuotaWindowPreference.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let preferences = AppPreferences(defaults: defaults)
            let relay = DashboardPreferencePageRelay()
            var changedPreferences: [OfficialQuotaWindowPreference] = []
            relay.onMenuBarQuotaWindowPreferenceChanged = { preference in
                changedPreferences.append(preference)
                preferences.menuBarQuotaWindowPreference = preference
            }
            let controller = DashboardMenuBarPage()
            let page = controller.make(.init(
                preferences: preferences,
                snapshot: snapshot,
                menuBarSnapshot: { current in
                    current.menuBarSnapshot(
                        preferredQuotaWindow: preferences.menuBarQuotaWindowPreference
                    )
                },
                iconImage: nil,
                relay: relay
            ))
            page.frame = NSRect(x: 0, y: 0, width: 516, height: 900)
            let window = NSWindow(
                contentRect: page.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            window.layoutIfNeeded()

            let popup = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaWindowPreferenceIdentifier }
            )
            XCTAssertEqual(
                popup.itemTitles,
                [
                    tr(.keyDashboardMenuBarPageFiveHourQuota, language: language),
                    tr(.keyDashboardMenuBarPageSevenDayQuota, language: language)
                ]
            )
            if language == .simplifiedChinese {
                XCTAssertEqual(
                    tr(.keyDashboardMenuBarPageQuotaDisplayPriority, language: language),
                    "优先显示额度"
                )
                XCTAssertEqual(
                    tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription, language: language),
                    "选择菜单栏和“快速切换”菜单中优先显示 5 小时额度还是 7 日额度"
                )
            }
            XCTAssertFalse(popup.itemTitles.contains { $0.hasPrefix("⟦") })
            XCTAssertEqual(popup.indexOfSelectedItem, 0)
            XCTAssertEqual(
                popup.item(at: 0)?.representedObject as? String,
                OfficialQuotaWindowPreference.fiveHour.rawValue
            )
            XCTAssertEqual(
                popup.item(at: 1)?.representedObject as? String,
                OfficialQuotaWindowPreference.sevenDay.rawValue
            )
            XCTAssertGreaterThanOrEqual(
                popup.constraints
                    .filter { $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual }
                    .map(\.constant)
                    .max() ?? 0,
                ceil(popup.fittingSize.width)
            )

            let selectorRow = try XCTUnwrap(popup.superview)
            let autoSwitchRow = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSSwitch }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.autoSwitchLunaReserveIdentifier }
                    .flatMap(\.superview)
            )
            let lunaReserveResetTimeRow = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.lunaReserveResetTimeModeIdentifier }
                    .flatMap(\.superview)
            )
            let quotaAndResetHeading = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first {
                        $0.stringValue == tr(.keyDashboardMenuBarPageQuotaAndReset, language: language)
                    }
            )
            let quotaAndResetRows = try XCTUnwrap(selectorRow.superview as? NSStackView)
            let quotaRows = quotaAndResetRows.arrangedSubviews.filter { !($0 is NSBox) }
            XCTAssertEqual(quotaRows.count, 6)
            XCTAssertTrue(
                zip(
                    quotaRows,
                    [
                        try XCTUnwrap(
                            descendants(of: page)
                                .compactMap { $0 as? NSSwitch }
                                .first { $0.identifier?.rawValue == "showMenuBarAmount" }
                                .flatMap(\.superview)
                        ),
                        try XCTUnwrap(
                            descendants(of: page)
                                .compactMap { $0 as? NSSwitch }
                                .first { $0.identifier?.rawValue == "showMenuBarReset" }
                                .flatMap(\.superview)
                        ),
                        selectorRow,
                        try XCTUnwrap(
                            descendants(of: page)
                                .compactMap { $0 as? NSPopUpButton }
                                .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaResetDisplayModeIdentifier }
                                .flatMap(\.superview)
                        ),
                        autoSwitchRow,
                        lunaReserveResetTimeRow
                    ]
                ).allSatisfy { $0.0 === $0.1 },
                "quota rows follow usage, reset countdown, priority, reset display, Reserve switch, Reserve reset source order"
            )
            XCTAssertTrue(
                descendants(of: selectorRow)
                    .compactMap { $0 as? NSTextField }
                    .contains {
                        $0.stringValue == tr(.keyDashboardMenuBarPageQuotaDisplayPriority, language: language)
                    }
            )
            XCTAssertTrue(
                descendants(of: selectorRow)
                    .compactMap { $0 as? NSTextField }
                    .contains {
                        $0.stringValue == tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription, language: language)
                    }
            )
            XCTAssertTrue(
                quotaAndResetHeading.convert(quotaAndResetHeading.bounds, to: page).minY
                    < selectorRow.convert(selectorRow.bounds, to: page).minY
            )

            let previewPrimary = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.previewPrimaryIdentifier }
            )
            XCTAssertEqual(previewPrimary.stringValue, "80%")
            let narrowRowHeight = selectorRow.frame.height

            popup.selectItem(at: 1)
            relay.menuBarQuotaWindowPreference(popup)
            XCTAssertEqual(changedPreferences, [.sevenDay])
            XCTAssertEqual(preferences.menuBarQuotaWindowPreference, .sevenDay)
            controller.refresh(
                snapshot: snapshot,
                preferences: preferences,
                menuBarSnapshot: { current in
                    current.menuBarSnapshot(
                        preferredQuotaWindow: preferences.menuBarQuotaWindowPreference
                    )
                },
                iconImage: nil
            )
            window.layoutIfNeeded()
            XCTAssertEqual(popup.indexOfSelectedItem, 1)
            XCTAssertEqual(previewPrimary.stringValue, "45%")

            window.setContentSize(NSSize(width: 740, height: 900))
            window.layoutIfNeeded()
            XCTAssertGreaterThan(selectorRow.frame.height, 0)
            XCTAssertLessThanOrEqual(selectorRow.frame.height, narrowRowHeight + 0.5)
            for label in descendants(of: selectorRow).compactMap({ $0 as? NSTextField }) {
                XCTAssertGreaterThanOrEqual(label.frame.minY, -1)
                XCTAssertLessThanOrEqual(label.frame.maxY, selectorRow.bounds.height + 1)
            }

            let reloadedPage = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: snapshot,
                menuBarSnapshot: { current in
                    current.menuBarSnapshot(
                        preferredQuotaWindow: AppPreferences(defaults: defaults).menuBarQuotaWindowPreference
                    )
                },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))
            XCTAssertEqual(
                try XCTUnwrap(
                    descendants(of: reloadedPage)
                        .compactMap { $0 as? NSPopUpButton }
                        .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaWindowPreferenceIdentifier }
                ).indexOfSelectedItem,
                1
            )
            window.contentView = nil
        }
    }

    func testQuotaResetDisplayModeSelectorUsesLocalizedOptionsPersistsAndRefreshesPreview() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french,
            .english
        ]
        let now = Date()
        let snapshot = Snapshot.official(
            "OpenAI",
            80,
            "5-hour",
            "1h",
            now,
            windows: [OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5-hour",
                daysText: "5 hours",
                reset: "1h",
                durationSeconds: 18_000,
                resetAt: now.addingTimeInterval(3_600)
            )]
        )

        for language in languages {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.QuotaResetDisplayMode.\(language.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let preferences = AppPreferences(defaults: defaults)
            let relay = DashboardPreferencePageRelay()
            var changedModes: [OfficialQuotaResetDisplayMode] = []
            let controller = DashboardMenuBarPage()
            relay.onMenuBarQuotaResetDisplayModeChanged = { mode in
                changedModes.append(mode)
                preferences.menuBarQuotaResetDisplayMode = mode
                controller.refresh(
                    snapshot: snapshot,
                    preferences: preferences,
                    menuBarSnapshot: { $0 },
                    iconImage: nil
                )
            }
            let page = controller.make(.init(
                preferences: preferences,
                snapshot: snapshot,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: relay
            ))
            page.frame = NSRect(x: 0, y: 0, width: 516, height: 900)
            let window = NSWindow(
                contentRect: page.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            window.layoutIfNeeded()

            let popup = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaResetDisplayModeIdentifier }
            )
            XCTAssertEqual(
                popup.itemTitles,
                [
                    tr(.keyDashboardMenuBarPageQuotaResetDisplayRemaining, language: language),
                    tr(.keyDashboardMenuBarPageQuotaResetDisplayTarget, language: language),
                    tr(.keyDashboardMenuBarPageQuotaResetDisplayBoth, language: language)
                ]
            )
            XCTAssertFalse(popup.itemTitles.contains { $0.hasPrefix("⟦") })
            XCTAssertEqual(
                popup.indexOfSelectedItem,
                try XCTUnwrap(OfficialQuotaResetDisplayMode.allCases.firstIndex(of: .both))
            )
            XCTAssertEqual(
                popup.action,
                #selector(DashboardPreferencePageRelay.menuBarQuotaResetDisplayMode(_:))
            )
            XCTAssertGreaterThanOrEqual(
                popup.constraints
                    .filter { $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual }
                    .map(\.constant)
                    .max() ?? 0,
                ceil(popup.fittingSize.width)
            )

            let previewSecondary = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.identifier?.rawValue == DashboardMenuBarPage.previewSecondaryIdentifier }
            )
            XCTAssertFalse(previewSecondary.stringValue.isEmpty)
            XCTAssertNotEqual(previewSecondary.stringValue, "1h")

            let modeRow = try XCTUnwrap(popup.superview)
            let narrowRowHeight = modeRow.frame.height
            popup.selectItem(
                at: try XCTUnwrap(OfficialQuotaResetDisplayMode.allCases.firstIndex(of: .remaining))
            )
            relay.menuBarQuotaResetDisplayMode(popup)
            XCTAssertEqual(changedModes, [.remaining])
            XCTAssertEqual(preferences.menuBarQuotaResetDisplayMode, .remaining)
            XCTAssertEqual(previewSecondary.stringValue, "1h")

            window.setContentSize(NSSize(width: 740, height: 900))
            window.layoutIfNeeded()
            XCTAssertGreaterThan(modeRow.frame.height, 0)
            XCTAssertLessThanOrEqual(modeRow.frame.height, narrowRowHeight + 0.5)
            for label in descendants(of: modeRow).compactMap({ $0 as? NSTextField }) {
                XCTAssertGreaterThanOrEqual(label.frame.minY, -1)
                XCTAssertLessThanOrEqual(label.frame.maxY, modeRow.bounds.height + 1)
            }

            let reloadedPage = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: snapshot,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))
            XCTAssertEqual(
                try XCTUnwrap(
                    descendants(of: reloadedPage)
                        .compactMap { $0 as? NSPopUpButton }
                        .first { $0.identifier?.rawValue == DashboardMenuBarPage.quotaResetDisplayModeIdentifier }
                ).indexOfSelectedItem,
                try XCTUnwrap(OfficialQuotaResetDisplayMode.allCases.firstIndex(of: .remaining))
            )
            window.contentView = nil
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
        XCTAssertEqual(
            iconSummary.map { normalizeSettingsText($0.stringValue) },
            "微调图标的上下位置Y 轴 - 0.3 pt"
        )
        XCTAssertEqual(
            amountSummary.map { normalizeSettingsText($0.stringValue) },
            "微调数值的上下位置Y 轴 + 0.5 pt"
        )
        XCTAssertEqual(
            labels.first { $0.identifier?.rawValue == DashboardMenuBarPage.widthAdjustmentSummaryIdentifier }
                .map { normalizeSettingsText($0.stringValue) },
            "调整 BalanceBar 与其他菜单栏图标的间距宽度 + 0.6 pt"
        )
        let labelStrings = labels.map(\.stringValue)
        XCTAssertTrue(labelStrings.contains("布局"))
        XCTAssertFalse(labelStrings.contains("字号"))
        XCTAssertFalse(labelStrings.contains("细节微调"))
        XCTAssertTrue(labelStrings.contains("调整菜单栏文字大小"))
        let rowTitles = ["菜单栏字号", "图标上下位置", "数值上下位置", "与其他菜单栏图标的间距"]
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
            refreshedLabels.first { $0.identifier?.rawValue == DashboardMenuBarPage.iconOffsetSummaryIdentifier }
                .map { normalizeSettingsText($0.stringValue) },
            "微调图标的上下位置 Y 轴 + 0.7 pt"
        )
        XCTAssertEqual(
            refreshedLabels.first { $0.identifier?.rawValue == DashboardMenuBarPage.amountOffsetSummaryIdentifier }
                .map { normalizeSettingsText($0.stringValue) },
            "微调数值的上下位置 Y 轴 - 0.8 pt"
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

    func testMenuBarPreviewRowsAdaptForJapaneseAndEnglishWindowWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        let suiteName = "DashboardPreferencePagesTests.MenuBarAdaptiveRows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1))
        for language in [AppLanguage.japanese, .english] {
            AppLanguage.selected = language
            let page = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: snapshot,
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 516, height: 520),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            defer { window.orderOut(nil) }

            let subtitleText = language == .japanese
                ? "サービスプロバイダーのデータをメニューバーにリアルタイム表示"
                : "The menu bar updates with Provider data in real time"
            let subtitle = try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == subtitleText }
            )
            let row = try XCTUnwrap(subtitle.superview?.superview)
            let rowsStack = try XCTUnwrap(row.superview as? NSStackView)
            let card = try XCTUnwrap(rowsStack.superview)
            let control = try XCTUnwrap(row.subviews.first { !($0 is NSStackView) })

            window.layoutIfNeeded()
            let narrowHeight = row.frame.height
            XCTAssertGreaterThan(narrowHeight, DashboardMenuBarPage.previewRowHeight, "(language) preview must grow when its subtitle wraps")
            XCTAssertLessThanOrEqual(
                subtitle.cell!.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: subtitle.bounds.width, height: .greatestFiniteMagnitude)
                ).height,
                subtitle.bounds.height + 0.5,
                "(language) preview subtitle must not be clipped"
            )
            XCTAssertEqual(control.frame.midY, row.bounds.midY, accuracy: 0.5, "(language) preview control must remain centered")
            XCTAssertEqual(
                card.frame.height,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: rowsStack,
                    separators: rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
                ),
                accuracy: 0.5
            )

            window.setContentSize(NSSize(width: 740, height: 520))
            window.layoutIfNeeded()
            XCTAssertEqual(
                row.frame.height,
                DashboardSettingsComponents.standardRowHeight,
                accuracy: 0.5,
                "(language) preview row must match the standard settings-row height at a wide width"
            )
            XCTAssertLessThan(row.frame.height, narrowHeight, "(language) preview row should shrink at wide width")
            XCTAssertLessThan(card.frame.height, narrowHeight + DashboardSettingsComponents.settingsSeparatorHeight)

            window.setContentSize(NSSize(width: 516, height: 520))
            window.layoutIfNeeded()
            XCTAssertEqual(row.frame.height, narrowHeight, accuracy: 0.5, "(language) preview row should recover at narrow width")
        }
    }

    func testMenuBarTypographySummaryRowsWrapExternalLabelsAcrossWindowWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let summaryIdentifiers = [
            DashboardMenuBarPage.iconOffsetSummaryIdentifier,
            DashboardMenuBarPage.amountOffsetSummaryIdentifier,
            DashboardMenuBarPage.widthAdjustmentSummaryIdentifier
        ]
        let expectedSignedSuffixes: [AppLanguage: [String]] = [
            .simplifiedChinese: ["Y 轴 + 0.0 pt", "Y 轴 + 0.0 pt", "宽度 + 0.0 pt"],
            .traditionalChineseTaiwan: ["Y 軸 + 0.0 pt", "Y 軸 + 0.0 pt", "寬度 + 0.0 pt"],
            .traditionalChineseHongKong: ["Y 軸 + 0.0 pt", "Y 軸 + 0.0 pt", "寬度 + 0.0 pt"],
            .japanese: ["Y 軸 + 0.0 pt", "Y 軸 + 0.0 pt", "幅 + 0.0 pt"],
            .english: ["Y axis + 0.0 pt", "Y axis + 0.0 pt", "Width + 0.0 pt"],
            .korean: ["Y 축 + 0.0 pt", "Y 축 + 0.0 pt", "너비 + 0.0 pt"],
            .spanish: ["Eje Y + 0.0 pt", "Eje Y + 0.0 pt", "Ancho + 0.0 pt"],
            .german: ["Y Achse + 0.0 pt", "Y Achse + 0.0 pt", "Breite + 0.0 pt"],
            .french: ["Axe Y + 0.0 pt", "Axe Y + 0.0 pt", "Largeur + 0.0 pt"]
        ]
        let expectedDescriptions: [AppLanguage: [String]] = [
            .simplifiedChinese: ["微调图标的上下位置", "微调数值的上下位置", "调整 BalanceBar 与其他菜单栏图标的间距"],
            .traditionalChineseTaiwan: ["微調圖示的上下位置", "微調數值的上下位置", "調整 BalanceBar 與其他選單列圖示的間距"],
            .traditionalChineseHongKong: ["微調圖示的上下位置", "微調數值的上下位置", "調整 BalanceBar 與其他選單列圖示的間距"],
            .japanese: ["アイコンの上下位置を微調整", "数値の上下位置を微調整", "BalanceBar と他のメニューバーアイコンとの間隔を調整"],
            .english: ["Fine-tune the icon's vertical position", "Fine-tune the amount's vertical position", "Adjust the gap between BalanceBar and other menu bar icons"],
            .korean: ["아이콘 세로 위치 미세 조정", "수치 세로 위치 미세 조정", "BalanceBar와 다른 메뉴 막대 아이콘 사이의 간격 조정"],
            .spanish: ["Ajusta con precisión la posición vertical del icono", "Ajusta con precisión la posición vertical del valor", "Ajusta el espacio entre BalanceBar y los demás iconos de la barra de menús"],
            .german: ["Vertikale Symbolposition fein einstellen", "Vertikale Position des Werts fein einstellen", "Abstand zwischen BalanceBar und anderen Menüleistensymbolen anpassen"],
            .french: ["Ajuste précisément la position verticale de l’icône", "Ajuste précisément la position verticale de la valeur", "Ajuste l’espacement entre BalanceBar et les autres icônes de la barre des menus"]
        ]
        let longReplacement = "This newly reported summary is intentionally long so the shared settings row must wrap it beside the slider and remeasure the card when the text changes."

        for language in [
            AppLanguage.simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .english,
            .korean,
            .spanish,
            .german,
            .french
        ] {
            AppLanguage.selected = language
            let suiteName = "DashboardPreferencePagesTests.MenuBarExternalSummaries.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let page = DashboardMenuBarPage().make(.init(
                preferences: AppPreferences(defaults: defaults),
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                menuBarSnapshot: { $0 },
                iconImage: nil,
                relay: DashboardPreferencePageRelay()
            ))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 516, height: 700),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            defer { window.orderOut(nil) }

            let summaries = try summaryIdentifiers.map { identifier in
                try XCTUnwrap(
                    descendants(of: page)
                        .compactMap { $0 as? NSTextField }
                        .first { $0.identifier?.rawValue == identifier }
                )
            }
            let rows = try summaries.map { try XCTUnwrap($0.superview?.superview) }
            let rowsStack = try XCTUnwrap(rows.first?.superview as? NSStackView)
            let card = try XCTUnwrap(rowsStack.superview)
            XCTAssertTrue(rows.allSatisfy { $0.superview === rowsStack })
            let expectedSuffixes = try XCTUnwrap(expectedSignedSuffixes[language])
            let expectedDescriptionLines = try XCTUnwrap(expectedDescriptions[language])
            // Structured subtitles use word wrapping so AppKit honors the
            // marked range's non-breaking layout tokens. Unicode still
            // supplies CJK character-boundary opportunities in the prefix.
            let expectedLineBreakMode: NSLineBreakMode = .byWordWrapping

            func layout(at width: CGFloat) throws -> (rowHeights: [CGFloat], cardHeight: CGFloat) {
                window.setContentSize(NSSize(width: width, height: 700))
                window.layoutIfNeeded()
                var sliderCenters: [CGFloat] = []
                for index in summaries.indices {
                    let summary = summaries[index]
                    let row = rows[index]
                    XCTAssertFalse(summary.usesSingleLineMode, "multiline mode for \(language)")
                    XCTAssertEqual(summary.lineBreakMode, expectedLineBreakMode, "wrapping mode for \(language)")
                    XCTAssertEqual(
                        summary.maximumNumberOfLines,
                        DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines,
                        "summary line budget for \(language)"
                    )
                    XCTAssertTrue(summary.cell?.wraps == true, "cell wrapping for \(language)")
                    if normalizeSettingsText(summary.stringValue).contains(expectedSuffixes[index]) {
                        let renderedLines = renderedTextLines(for: summary).map {
                            normalizeSettingsText($0).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        XCTAssertTrue(
                            normalizeSettingsText(summary.stringValue).contains(expectedDescriptionLines[index]),
                            "description must remain in the first semantic block for \(language): \(renderedLines)"
                        )
                        let suffixLineIndex = renderedLines.firstIndex {
                            $0.contains(expectedSuffixes[index])
                        }
                        XCTAssertNotNil(
                            suffixLineIndex,
                            "complete semantic suffix must be rendered for \(language): \(renderedLines)"
                        )
                        if let suffixLineIndex {
                            XCTAssertGreaterThan(
                                suffixLineIndex,
                                0,
                                "complete semantic suffix must start after the description block for \(language): \(renderedLines)"
                            )
                            XCTAssertFalse(
                                renderedLines[suffixLineIndex].contains(expectedDescriptionLines[index]),
                                "description and dynamic suffix must not share a line for \(language): \(renderedLines)"
                            )
                        }
                        XCTAssertTrue(
                            renderedLines.contains {
                                $0.contains(expectedSuffixes[index])
                            },
                            "signed descriptor/value suffix must stay together for \(language): \(renderedLines)"
                        )
                    }
                    let summaryFrame = summary.convert(summary.bounds, to: row)
                    XCTAssertLessThanOrEqual(
                        summary.cell!.cellSize(
                            forBounds: NSRect(
                                x: 0,
                                y: 0,
                                width: summary.bounds.width,
                                height: .greatestFiniteMagnitude
                            )
                        ).height,
                        summaryFrame.height + 0.5,
                        "summary fitting height for \(language)"
                    )
                    let slider = try XCTUnwrap(
                        descendants(of: row).compactMap { $0 as? NSSlider }.first
                    )
                    let sliderFrame = slider.convert(slider.bounds, to: row)
                    XCTAssertEqual(
                        sliderFrame.midY,
                        row.bounds.midY,
                        accuracy: 0.5,
                        "slider remains centered for \(language)"
                    )
                    sliderCenters.append(sliderFrame.midX)
                }
                for center in sliderCenters.dropFirst() {
                    XCTAssertEqual(
                        center,
                        sliderCenters[0],
                        accuracy: 0.5,
                        "slider tracks must share one horizontal alignment for \(language) at width \(width)"
                    )
                }
                XCTAssertEqual(
                    card.frame.height,
                    DashboardSettingsComponents.settingsCardHeight(
                        rowsStack: rowsStack,
                        separators: rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
                    ),
                    accuracy: 0.5,
                    "typography card height for \(language)"
                )
                return (rows.map(\.frame.height), card.frame.height)
            }

            let narrow = try layout(at: 516)
            XCTAssertTrue(
                narrow.rowHeights.contains { $0 > 66.5 },
                "at least one real slider summary must grow at narrow width for \(language)"
            )
            let wide = try layout(at: 740)
            XCTAssertTrue(
                zip(wide.rowHeights, narrow.rowHeights).allSatisfy { $0 <= $1 + 0.5 },
                "real slider rows must not grow when widened for \(language)"
            )
            XCTAssertLessThanOrEqual(
                wide.cardHeight,
                narrow.cardHeight + 0.5,
                "card must not grow when widened for \(language)"
            )
            let narrowAgain = try layout(at: 516)
            for (restored, original) in zip(narrowAgain.rowHeights, narrow.rowHeights) {
                XCTAssertEqual(restored, original, accuracy: 0.5)
            }
            XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5)

            summaries[0].stringValue = "Short summary"
            summaries[0].invalidateIntrinsicContentSize()
            rows[0].needsLayout = true
            page.needsLayout = true
            let short = try layout(at: 516)
            summaries[0].stringValue = longReplacement
            summaries[0].invalidateIntrinsicContentSize()
            rows[0].needsLayout = true
            page.needsLayout = true
            let changed = try layout(at: 516)
            XCTAssertGreaterThan(changed.rowHeights[0], short.rowHeights[0], "content changes must grow the real row for \(language)")
            XCTAssertGreaterThan(changed.cardHeight, short.cardHeight, "content changes must grow the real card for \(language)")
        }
    }

    func testJapaneseMultilineSummariesKeepAllSliderTracksAlignedAcrossWidthsAndUpdates() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .japanese

        let suiteName = "DashboardPreferencePagesTests.JapaneseSliderAlignment.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let snapshot = Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1))
        let controller = DashboardMenuBarPage()
        let page = controller.make(.init(
            preferences: preferences,
            snapshot: snapshot,
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 516, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer { window.orderOut(nil) }

        let summaryIdentifiers = [
            DashboardMenuBarPage.iconOffsetSummaryIdentifier,
            DashboardMenuBarPage.amountOffsetSummaryIdentifier,
            DashboardMenuBarPage.widthAdjustmentSummaryIdentifier
        ]
        let summaries = try summaryIdentifiers.map { identifier in
            try XCTUnwrap(
                descendants(of: page)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.identifier?.rawValue == identifier }
            )
        }
        let rows = try summaries.map { try XCTUnwrap($0.superview?.superview) }
        let rowsStack = try XCTUnwrap(rows.first?.superview as? NSStackView)
        let card = try XCTUnwrap(rowsStack.superview)
        let sliders = try rows.map { row in
            try XCTUnwrap(descendants(of: row).compactMap { $0 as? NSSlider }.first)
        }

        func controlGroup(for slider: NSSlider, in row: NSView) throws -> NSView {
            var current: NSView = slider
            while let parent = current.superview, parent !== row {
                current = parent
            }
            return try XCTUnwrap(current.superview === row ? current : nil)
        }

        func layout(at width: CGFloat) throws -> (rowHeights: [CGFloat], cardHeight: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 700))
            window.layoutIfNeeded()

            var sliderCenters: [CGFloat] = []
            for index in rows.indices {
                let row = rows[index]
                let summary = summaries[index]
                let slider = sliders[index]
                let group = try controlGroup(for: slider, in: row)
                let sliderFrame = slider.convert(slider.bounds, to: row)
                let groupFrame = group.convert(group.bounds, to: row)
                let lines = renderedTextLines(for: summary)
                XCTAssertGreaterThanOrEqual(
                    lines.count,
                    2,
                    "Japanese summary must remain multiline at width \(width): \(lines)"
                )
                XCTAssertEqual(
                    sliderFrame.midY,
                    row.bounds.midY,
                    accuracy: 0.5,
                    "Japanese slider \(index) must be vertically centered at width \(width)"
                )
                XCTAssertEqual(
                    groupFrame.midY,
                    row.bounds.midY,
                    accuracy: 0.5,
                    "Japanese slider group \(index) must be vertically centered at width \(width)"
                )
                sliderCenters.append(sliderFrame.midX)
            }
            for center in sliderCenters.dropFirst() {
                XCTAssertEqual(
                    center,
                    sliderCenters[0],
                    accuracy: 0.5,
                    "Japanese slider tracks must share one horizontal alignment at width \(width)"
                )
            }
            XCTAssertEqual(
                card.frame.height,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: rowsStack,
                    separators: rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
                ),
                accuracy: 0.5,
                "Japanese card height must follow its rows at width \(width)"
            )
            return (rows.map(\.frame.height), card.frame.height)
        }

        let narrow = try layout(at: 516)
        let wide = try layout(at: 740)
        let narrowAgain = try layout(at: 516)
        for (restored, original) in zip(narrowAgain.rowHeights, narrow.rowHeights) {
            XCTAssertEqual(restored, original, accuracy: 0.5)
        }
        XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5)
        XCTAssertTrue(
            zip(wide.rowHeights, narrow.rowHeights).allSatisfy { $0 <= $1 + 0.5 },
            "Japanese rows must not grow when the window widens"
        )

        preferences.menuBarIconOffsetY = -0.7
        preferences.menuBarAmountOffsetY = 0.8
        preferences.menuBarStatusItemWidthAdjustment = -0.4
        controller.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: { $0 },
            iconImage: nil
        )
        _ = try layout(at: 516)
        XCTAssertEqual(
            normalizeSettingsText(summaries[0].stringValue),
            "アイコンの上下位置を微調整 Y 軸 - 0.7 pt"
        )
        XCTAssertEqual(
            normalizeSettingsText(summaries[1].stringValue),
            "数値の上下位置を微調整 Y 軸 + 0.8 pt"
        )
        XCTAssertEqual(
            normalizeSettingsText(summaries[2].stringValue),
            "BalanceBar と他のメニューバーアイコンとの間隔を調整 幅 - 0.4 pt"
        )
        XCTAssertEqual(sliders[0].doubleValue, -0.7, accuracy: 0.001)
        XCTAssertEqual(sliders[1].doubleValue, 0.8, accuracy: 0.001)
        XCTAssertEqual(sliders[2].doubleValue, -0.4, accuracy: 0.001)
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
        let controller = DashboardMenuBarPage()
        let relay = DashboardPreferencePageRelay()
        relay.onMenuBarFontSizePreset = { preset in
            preferences.menuBarFontSizePreset = preset
            controller.refresh(
                snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
                preferences: preferences,
                menuBarSnapshot: { $0 },
                iconImage: nil
            )
        }
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
            fontPresetControl.selectedItem?.representedObject as? String,
            MenuBarFontSizePreset.medium.rawValue
        )
        XCTAssertEqual(
            fontPresetControl.numberOfItems,
            MenuBarFontSizePreset.allCases.count
        )
        XCTAssertEqual(fontPresetControl.itemTitle(at: 0), "Large")
        XCTAssertEqual(fontPresetControl.itemTitle(at: 1), "Medium")
        XCTAssertEqual(fontPresetControl.itemTitle(at: 2), "Small")
        XCTAssertEqual(fontPresetControl.item(at: MenuBarFontSizePreset.large.segmentIndex)?.state, .off)
        XCTAssertEqual(fontPresetControl.item(at: MenuBarFontSizePreset.medium.segmentIndex)?.state, .on)
        XCTAssertEqual(fontPresetControl.item(at: MenuBarFontSizePreset.small.segmentIndex)?.state, .off)
        XCTAssertTrue(popupControls.allSatisfy {
            $0.identifier?.rawValue != AppPreferences.menuBarPrimaryFontSizeKey
                && $0.identifier?.rawValue != AppPreferences.menuBarSecondaryFontSizeKey
        })
        XCTAssertEqual(
            fontPresetControl.action,
            #selector(DashboardPreferencePageRelay.menuBarFontSizePreset(_:))
        )
        XCTAssertTrue(fontPresetControl.toolTip?.contains("11.7/9") == true)

        let labels = descendants(of: page).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "Layout" })
        XCTAssertTrue(labels.contains { $0.stringValue == "Menu Bar Font Size" })
        XCTAssertTrue(labels.contains { $0.stringValue == "Adjust menu bar text size" })
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

        for preset in MenuBarFontSizePreset.allCases {
            fontPresetControl.selectItem(at: preset.segmentIndex)
            relay.menuBarFontSizePreset(fontPresetControl)

            XCTAssertEqual(preferences.menuBarFontSizePreset, preset)
            XCTAssertEqual(preferences.menuBarFontSize, preset.primarySize, accuracy: 0.001)
            XCTAssertEqual(
                preferences.menuBarSecondaryFontSize,
                preset.secondarySize,
                accuracy: 0.001
            )
            XCTAssertEqual(fontPresetControl.indexOfSelectedItem, preset.segmentIndex)
            XCTAssertEqual(fontPresetControl.title, fontPresetControl.itemTitle(at: preset.segmentIndex))
            for (index, item) in fontPresetControl.itemArray.enumerated() {
                XCTAssertEqual(item.state, index == preset.segmentIndex ? .on : .off)
            }
            XCTAssertEqual(previewPrimary.font?.pointSize ?? .nan, preset.primarySize, accuracy: 0.001)
            XCTAssertEqual(previewSecondary.font?.pointSize ?? .nan, preset.secondarySize, accuracy: 0.001)
        }

        preferences.menuBarFontSizePreset = .small
        fontPresetControl.selectItem(at: MenuBarFontSizePreset.medium.segmentIndex)
        for (index, item) in fontPresetControl.itemArray.enumerated() {
            item.state = index == MenuBarFontSizePreset.medium.segmentIndex ? .on : .off
        }
        XCTAssertEqual(fontPresetControl.indexOfSelectedItem, MenuBarFontSizePreset.medium.segmentIndex)
        NotificationCenter.default.post(
            name: NSMenu.didEndTrackingNotification,
            object: fontPresetControl.menu
        )
        XCTAssertEqual(fontPresetControl.indexOfSelectedItem, MenuBarFontSizePreset.small.segmentIndex)
        XCTAssertEqual(fontPresetControl.title, "Small")
        for (index, item) in fontPresetControl.itemArray.enumerated() {
            XCTAssertEqual(item.state, index == MenuBarFontSizePreset.small.segmentIndex ? .on : .off)
        }

        let restoredPreferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(restoredPreferences.menuBarFontSizePreset, .small)
        let rebuiltController = DashboardMenuBarPage()
        let rebuiltPage = rebuiltController.make(.init(
            preferences: restoredPreferences,
            snapshot: .official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1)),
            menuBarSnapshot: { $0 },
            iconImage: nil,
            relay: DashboardPreferencePageRelay()
        ))
        let rebuiltFontPresetControl = try XCTUnwrap(
            descendants(of: rebuiltPage)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == AppPreferences.menuBarFontSizePresetKey }
        )
        XCTAssertEqual(rebuiltFontPresetControl.indexOfSelectedItem, MenuBarFontSizePreset.small.segmentIndex)
        XCTAssertEqual(rebuiltFontPresetControl.title, "Small")

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
        XCTAssertEqual(fontPresetControl.title, "Small")

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
        XCTAssertEqual(
            summary.map { normalizeSettingsText($0.stringValue) },
            "调整 BalanceBar 与其他菜单栏图标的间距宽度 + 7.4 pt"
        )

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
                ["布局", "菜单栏字号", "图标上下位置", "数值上下位置", "与其他菜单栏图标的间距"],
                [
                    "调整菜单栏文字大小",
                    "微调图标的上下位置Y 轴 + 0.0 pt",
                    "微调数值的上下位置Y 轴 + 0.0 pt",
                    "调整 BalanceBar 与其他菜单栏图标的间距宽度 + 0.0 pt"
                ],
                "调整与其他菜单栏图标的间距：-10.0 pt 更窄，+10.0 pt 更宽；默认 0 pt"
            ),
            (
                .traditionalChineseTaiwan,
                ["版面", "選單列字號", "圖示上下位置", "數值上下位置", "與其他選單列圖示的間距"],
                [
                    "調整選單列文字大小",
                    "微調圖示的上下位置 Y 軸 + 0.0 pt",
                    "微調數值的上下位置 Y 軸 + 0.0 pt",
                    "調整 BalanceBar 與其他選單列圖示的間距 寬度 + 0.0 pt"
                ],
                "調整與其他選單列圖示的間距：-10.0 pt 更窄，+10.0 pt 更寬；預設 0 pt"
            ),
            (
                .traditionalChineseHongKong,
                ["版面", "選單列字型大小", "圖示上下位置", "數值上下位置", "與其他選單列圖示的間距"],
                [
                    "調整選單列文字大小",
                    "微調圖示的上下位置 Y 軸 + 0.0 pt",
                    "微調數值的上下位置 Y 軸 + 0.0 pt",
                    "調整 BalanceBar 與其他選單列圖示的間距 寬度 + 0.0 pt"
                ],
                "調整與其他選單列圖示的間距：-10.0 pt 更窄，+10.0 pt 更寬；預設 0 pt"
            ),
            (
                .japanese,
                ["レイアウト", "メニューバーのフォントサイズ", "アイコンの上下位置", "数値の上下位置", "他のメニューバーアイコンとの間隔"],
                [
                    "メニューバーの文字サイズを調整",
                    "アイコンの上下位置を微調整 Y 軸 + 0.0 pt",
                    "数値の上下位置を微調整 Y 軸 + 0.0 pt",
                    "BalanceBar と他のメニューバーアイコンとの間隔を調整 幅 + 0.0 pt"
                ],
                "他のメニューバーアイコンとの間隔を調整：-10.0 pt（狭く）～+10.0 pt（広く）、デフォルト 0 pt"
            ),
            (
                .english,
                ["Layout", "Menu Bar Font Size", "Icon vertical position", "Amount vertical position", "Spacing from other menu bar icons"],
                [
                    "Adjust menu bar text size",
                    "Fine-tune the icon's vertical position Y axis + 0.0 pt",
                    "Fine-tune the amount's vertical position Y axis + 0.0 pt",
                    "Adjust the gap between BalanceBar and other menu bar icons Width + 0.0 pt"
                ],
                "Adjust spacing from other menu bar icons: -10.0 pt narrower to +10.0 pt wider; default 0 pt"
            ),
            (
                .korean,
                ["레이아웃", "메뉴 막대 글꼴 크기", "아이콘 세로 위치", "수치 세로 위치", "다른 메뉴 막대 아이콘과의 간격"],
                [
                    "메뉴 막대 글자 크기 조정",
                    "아이콘 세로 위치 미세 조정 Y 축 + 0.0 pt",
                    "수치 세로 위치 미세 조정 Y 축 + 0.0 pt",
                    "BalanceBar와 다른 메뉴 막대 아이콘 사이의 간격 조정 너비 + 0.0 pt"
                ],
                "다른 메뉴 막대 아이콘과의 간격 조정: -10.0pt(더 좁게)에서 +10.0pt(더 넓게); 기본값 0pt"
            ),
            (
                .spanish,
                ["Diseño", "Tamaño de fuente de la barra de menús", "Posición vertical del icono", "Posición vertical del valor", "Espacio respecto a los demás iconos de la barra de menús"],
                [
                    "Ajusta el tamaño del texto de la barra de menús",
                    "Ajusta con precisión la posición vertical del icono Eje Y + 0.0 pt",
                    "Ajusta con precisión la posición vertical del valor Eje Y + 0.0 pt",
                    "Ajusta el espacio entre BalanceBar y los demás iconos de la barra de menús Ancho + 0.0 pt"
                ],
                "Ajusta el espacio respecto a los demás iconos: de -10,0 pt (más estrecho) a +10,0 pt (más ancho); valor predeterminado: 0 pt"
            ),
            (
                .german,
                ["Layout", "Schriftgröße der Menüleiste", "Vertikale Symbolposition", "Vertikale Position des Werts", "Abstand zu anderen Menüleistensymbolen"],
                [
                    "Passt die Textgröße der Menüleiste an",
                    "Vertikale Symbolposition fein einstellen Y-Achse + 0.0 pt",
                    "Vertikale Position des Werts fein einstellen Y-Achse + 0.0 pt",
                    "Abstand zwischen BalanceBar und anderen Menüleistensymbolen anpassen Breite + 0.0 pt"
                ],
                "Abstand zu anderen Menüleistensymbolen anpassen: -10,0 pt schmaler bis +10,0 pt breiter; Standard: 0 pt"
            ),
            (
                .french,
                ["Disposition", "Taille de la police de la barre des menus", "Position verticale de l’icône", "Position verticale de la valeur", "Espacement avec les autres icônes de la barre des menus"],
                [
                    "Ajuste la taille du texte de la barre des menus",
                    "Ajuste précisément la position verticale de l’icône Axe Y + 0.0 pt",
                    "Ajuste précisément la position verticale de la valeur Axe Y + 0.0 pt",
                    "Ajuste l’espacement entre BalanceBar et les autres icônes de la barre des menus Largeur + 0.0 pt"
                ],
                "Ajuste l’espacement avec les autres icônes : de -10,0 pt (plus étroit) à +10,0 pt (plus large) ; valeur par défaut : 0 pt"
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
            let normalizedLabelStrings = labelStrings.map(normalizeSettingsText)
            let expectedEndpointLabels: (minimum: String, maximum: String)
            switch language {
            case .simplifiedChinese:
                expectedEndpointLabels = ("窄", "宽")
            case .traditionalChineseTaiwan, .traditionalChineseHongKong:
                expectedEndpointLabels = ("窄", "寬")
            case .japanese:
                expectedEndpointLabels = ("狭い", "広い")
            case .english:
                expectedEndpointLabels = ("Narrow", "Wide")
            case .korean:
                expectedEndpointLabels = ("좁게", "넓게")
            case .spanish:
                expectedEndpointLabels = ("Estrecho", "Ancho")
            case .german:
                expectedEndpointLabels = ("Schmal", "Breit")
            case .french:
                expectedEndpointLabels = ("Étroit", "Large")
            case .portuguese:
                expectedEndpointLabels = ("Estreito", "Largo")
            case .russian:
                expectedEndpointLabels = ("Узкий", "Широкий")
            case .italian:
                expectedEndpointLabels = ("Stretto", "Largo")
            case .system:
                expectedEndpointLabels = ("窄", "宽")
            }
            let expectedOffsetEndpointLabels: (minimum: String, maximum: String)
            switch language {
            case .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .system:
                expectedOffsetEndpointLabels = ("下", "上")
            case .korean:
                expectedOffsetEndpointLabels = ("아래", "위")
            case .spanish:
                expectedOffsetEndpointLabels = ("Abajo", "Arriba")
            case .german:
                expectedOffsetEndpointLabels = ("Unten", "Oben")
            case .french:
                expectedOffsetEndpointLabels = ("Bas", "Haut")
            case .english:
                expectedOffsetEndpointLabels = ("Down", "Up")
            case .portuguese:
                expectedOffsetEndpointLabels = ("Para baixo", "Para cima")
            case .russian:
                expectedOffsetEndpointLabels = ("Вниз", "Вверх")
            case .italian:
                expectedOffsetEndpointLabels = ("Giù", "Su")
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
                    normalizedLabelStrings.contains(expectedSubtitle),
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
            (.traditionalChineseTaiwan, true),
            (.traditionalChineseTaiwan, false),
            (.traditionalChineseHongKong, true),
            (.traditionalChineseHongKong, false),
            (.japanese, true),
            (.japanese, false),
            (.english, true),
            (.english, false)
        ] {
            AppLanguage.selected = language
            let copy: (String, String, String, String) -> String = { zh, en, zhT, ja in
                switch language {
                case .simplifiedChinese: return zh
                case .traditionalChineseTaiwan, .traditionalChineseHongKong: return zhT
                case .japanese: return ja
                case .english, .system, .korean, .spanish, .german, .french, .portuguese, .russian, .italian: return en
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
            let expectedDashboardTitle = tr(
                .keyDashboardAdvancedPageOpenOpencodexDashboard,
                language: language
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
            let expectedManualDetail = tr(
                .keyDashboardAdvancedPageOnlyTrimmedDecimal165535IsAcceptedClearTheFieldToRestoreAutomaticDetection,
                language: language
            )
            guard let manualDetail = labels.first(where: { $0.stringValue == expectedManualDetail }) else {
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
        guard let accessibilityLabel = button.accessibilityLabel() else {
            return XCTFail("Expected a localized GitHub accessibility label")
        }
        let supportedAccessibilityLabels = [
            AppLanguage.simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .english,
            .korean,
            .spanish,
            .german,
            .french
        ].map { tr(.keyDashboardAboutPageGithubRepository, language: $0) }
        XCTAssertTrue(supportedAccessibilityLabels.contains(accessibilityLabel))

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

    private func normalizeSettingsText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func renderedTextLines(for field: NSTextField) -> [String] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = field.lineBreakMode
        if #available(macOS 10.15, *) {
            paragraphStyle.lineBreakStrategy = field.lineBreakStrategy
        }
        let storage = NSTextStorage(
            string: field.stringValue,
            attributes: [
                .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraphStyle
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: max(1, field.bounds.width), height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = field.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lines: [String] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var glyphRange = NSRange()
            layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &glyphRange,
                withoutAdditionalLayout: true
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            lines.append((field.stringValue as NSString).substring(with: characterRange))
            glyphIndex = NSMaxRange(glyphRange)
        }
        return lines
    }
}
