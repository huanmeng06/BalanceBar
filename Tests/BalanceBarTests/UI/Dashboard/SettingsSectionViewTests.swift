import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class SettingsSectionViewTests: XCTestCase {
    func testNativeSectionUsesAutoLayoutHierarchyAndSkipsLegacyCardHeightLoop() throws {
        DashboardSettingsLayoutMetrics.reset()
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: "Start in the background without opening the dashboard.",
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Startup", contentViews: [row])

        XCTAssertEqual(section.cardView.orientation, .vertical)
        XCTAssertEqual(section.cardView.spacing, 0)
        XCTAssertEqual(section.contentStack.orientation, .vertical)
        XCTAssertEqual(section.contentStack.spacing, SettingsSectionView.headingToCardSpacing)
        XCTAssertEqual(section.headingLabel.font, SettingsSectionView.headingFont)
        XCTAssertEqual(section.headingLabel.stringValue, "Startup")
        XCTAssertEqual(section.cardView.layer?.cornerRadius, SettingsSectionView.cornerRadius)
        XCTAssertEqual(section.contentHuggingPriority(for: .vertical), .required)
        XCTAssertEqual(section.contentCompressionResistancePriority(for: .vertical), .required)
        XCTAssertEqual(section.cardView.contentHuggingPriority(for: .vertical), .required)
        XCTAssertIdentical(section.rowsStack, section.cardView)
        XCTAssertEqual(section.contentViews.count, 1)
        XCTAssertTrue(section.separators.isEmpty)
        XCTAssertFalse(
            section.cardView.constraints.contains { constraint in
                constraint.firstAttribute == .height
                    && constraint.secondItem == nil
                    && constraint.relation == .equal
            }
        )

        let window = makeTestWindow(width: 640)
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(section.cardView.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.textLineMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.controlFittingMeasurements, 0)
    }

    func testSectionHeightFollowsArrangedRowsAndSeparatorsWithoutParentRemeasurement() throws {
        DashboardSettingsLayoutMetrics.reset()
        let first = SettingsRowView(title: "First", accessoryView: NSSwitch())
        let second = SettingsRowView(
            title: "Second",
            detail: "A second native row keeps its own intrinsic height.",
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Native", contentViews: [first, second])
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        XCTAssertEqual(section.separators.count, 1)
        let expectedHeight = first.frame.height
            + second.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(section.cardView.frame.height, expectedHeight, accuracy: 0.5)
        XCTAssertGreaterThan(section.frame.height, section.cardView.frame.height)
        XCTAssertEqual(
            section.headingLabel.frame.minY - section.cardView.frame.maxY,
            SettingsSectionView.headingToCardSpacing,
            accuracy: 1.0
        )
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)

        pin(section, to: host, window: window, width: 516)
        let narrowHeight = first.frame.height
            + second.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(section.cardView.frame.height, narrowHeight, accuracy: 0.5)
        XCTAssertEqual(section.cardView.frame.width, section.frame.width, accuracy: 0.5)
        XCTAssertEqual(first.frame.width, section.cardView.frame.width, accuracy: 0.5)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
    }

    func testMixedLegacyAndNativeRowsKeepBaselineCardHeightWithoutLegacyCardView() throws {
        DashboardSettingsLayoutMetrics.reset()
        let legacy = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
            subtitle: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription),
            control: NSSwitch()
        )
        let native = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunch),
            detail: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunchDescription),
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesStartup),
            contentViews: [legacy, native]
        )
        let window = makeTestWindow(width: 880)
        _ = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        let expected = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: section.rowsStack,
            separators: section.separators
        )
        XCTAssertEqual(section.cardView.frame.height, expected, accuracy: 1.0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertGreaterThanOrEqual(legacy.frame.height, DashboardSettingsComponents.standardRowHeight)
        XCTAssertGreaterThanOrEqual(native.frame.height, SettingsRowView.minimumHeight)
    }

    func testGeneralPageUsesNativeSectionsForSystemRefreshStartupAndApplication() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "SettingsSectionViewTests.GeneralNative.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DashboardSettingsLayoutMetrics.reset()
        let page = DashboardGeneralPage().make(.init(
            preferences: AppPreferences(defaults: defaults),
            currentProviderName: "OpenAI",
            relay: DashboardPreferencePageRelay(),
            updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
            launchAtLoginState: LaunchAtLoginState(status: .notRegistered),
            launchWithChatGPTState: LaunchWithChatGPTState(status: .notRegistered)
        ))
        let silentLaunchSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == AppPreferences.silentLaunchKey }
        )
        let startup = try XCTUnwrap(SettingsSectionView.enclosing(silentLaunchSwitch))
        XCTAssertEqual(
            startup.headingLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesStartup)
        )
        XCTAssertEqual(startup.contentViews.count, 3)
        XCTAssertNotNil(SettingsRowView.enclosing(silentLaunchSwitch))

        let openButton = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardGeneralAndRefreshPagesOpenCcSwitch) }
        )
        let system = try XCTUnwrap(SettingsSectionView.enclosing(openButton))
        XCTAssertEqual(
            system.headingLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesSystem)
        )
        XCTAssertNotNil(SettingsRowView.enclosing(openButton))

        let refreshButton = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardGeneralAndRefreshPagesRefreshNow) }
        )
        let refresh = try XCTUnwrap(SettingsSectionView.enclosing(refreshButton))
        XCTAssertEqual(
            refresh.headingLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesRefresh)
        )
        XCTAssertNotNil(SettingsRowView.enclosing(refreshButton))

        let languagePopup = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == AppLanguage.preferenceKey }
        )
        let application = try XCTUnwrap(SettingsSectionView.enclosing(languagePopup))
        XCTAssertEqual(
            application.headingLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesApplication)
        )
        XCTAssertNotNil(SettingsRowView.enclosing(languagePopup))
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.textLineMeasurements, 0)
    }

    func testAdvancedDiagnosticsSectionUsesNativeContainerAndSkipsLegacyMeasurement() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        DashboardSettingsLayoutMetrics.reset()
        let logViewer = NSView()
        logViewer.translatesAutoresizingMaskIntoConstraints = false
        logViewer.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let page = DashboardAdvancedPage().make(.init(
            relay: DashboardPreferencePageRelay(),
            logViewer: logViewer
        ))
        let reloadButton = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardAdvancedPageReload) }
        )
        let diagnostics = try XCTUnwrap(SettingsSectionView.enclosing(reloadButton))
        XCTAssertEqual(
            diagnostics.headingLabel.stringValue,
            tr(.keyDashboardAdvancedPageDiagnostics)
        )
        XCTAssertEqual(diagnostics.contentViews.count, 2)
        let logHost = diagnostics.contentViews[1]
        XCTAssertEqual(
            logHost.identifier,
            DashboardAdvancedPage.logViewerHostIdentifier
        )
        XCTAssertTrue(logViewer.isDescendant(of: logHost))
        XCTAssertNotNil(SettingsRowView.enclosing(reloadButton))
        XCTAssertIdentical(SettingsSectionView.enclosing(logViewer), diagnostics)
        XCTAssertEqual(diagnostics.separators.count, 1)

        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: page, in: window, width: 880)
        defer { window.orderOut(nil) }

        let debugLogRow = try XCTUnwrap(SettingsRowView.enclosing(reloadButton))
        XCTAssertGreaterThanOrEqual(debugLogRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(
            logHost.frame.height,
            DashboardAdvancedPage.logViewerHeight,
            accuracy: 0.5
        )
        let expectedHeight = debugLogRow.frame.height
            + logHost.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(diagnostics.cardView.frame.height, expectedHeight, accuracy: 0.5)
        XCTAssertFalse(
            diagnostics.cardView.constraints.contains { constraint in
                constraint.firstAttribute == .height
                    && constraint.secondItem == nil
                    && constraint.relation == .equal
            }
        )
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.textLineMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.controlFittingMeasurements, 0)

        pin(page, to: host, window: window, width: 516)
        XCTAssertGreaterThanOrEqual(debugLogRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(
            logHost.frame.height,
            DashboardAdvancedPage.logViewerHeight,
            accuracy: 0.5
        )
        let narrowHeight = debugLogRow.frame.height
            + logHost.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(diagnostics.cardView.frame.height, narrowHeight, accuracy: 0.5)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
    }

    func testAdvancedRealLogViewerStaysCompactInsideTallPageHost() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let logsPage = DashboardLogsPage()
        let logViewer = logsPage.makeViewer()
        let longLog = (0..<120).map { index in
            "[12:00:00] [INFO] [test] line \(index) " + String(repeating: "x", count: 48)
        }.joined(separator: "\n")
        let textView = try XCTUnwrap(
            descendants(of: logViewer).compactMap { $0 as? NSTextView }.first
        )
        textView.textStorage?.setAttributedString(DashboardLogsPage.styledLog(longLog))
        if let textContainer = textView.textContainer,
           let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            textView.setFrameSize(NSSize(
                width: max(480, ceil(used.width + (inset.width * 2) + 12)),
                height: max(800, ceil(used.height + (inset.height * 2)))
            ))
        }

        let page = DashboardAdvancedPage().make(.init(
            relay: DashboardPreferencePageRelay(),
            logViewer: logViewer
        ))
        let window = makeTestWindow(width: 640)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 760))
        window.contentView = host
        host.addSubview(page)
        pin(page, to: host, window: window, width: 640)
        window.setContentSize(NSSize(width: 640, height: 760))
        host.setFrameSize(NSSize(width: 640, height: 760))
        window.layoutIfNeeded()
        page.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let reloadButton = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardAdvancedPageReload) }
        )
        let diagnostics = try XCTUnwrap(SettingsSectionView.enclosing(reloadButton))
        let logHost = try XCTUnwrap(
            descendants(of: diagnostics).first {
                $0.identifier == DashboardAdvancedPage.logViewerHostIdentifier
            }
        )
        let debugLogRow = try XCTUnwrap(SettingsRowView.enclosing(reloadButton))

        XCTAssertEqual(
            logHost.frame.height,
            DashboardAdvancedPage.logViewerHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(logViewer.frame.height, logHost.frame.height, accuracy: 0.5)
        let expectedCardHeight = debugLogRow.frame.height
            + logHost.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(
            diagnostics.cardView.frame.height,
            expectedCardHeight,
            accuracy: 1.0,
            "card=\(diagnostics.cardView.frame.height) row=\(debugLogRow.frame.height) host=\(logHost.frame.height)"
        )
        XCTAssertLessThan(
            debugLogRow.frame.height,
            120,
            "debug log row should stay compact; row=\(debugLogRow.frame.height) w=\(debugLogRow.frame.width) wrap=\(debugLogRow.detailLabel.preferredMaxLayoutWidth) titleH=\(debugLogRow.titleLabel.frame.height) detailH=\(debugLogRow.detailLabel.frame.height) accessoryFit=\(debugLogRow.accessoryView?.fittingSize.width ?? -1) accessoryBounds=\(debugLogRow.accessoryView?.bounds.width ?? -1)"
        )
        XCTAssertLessThan(
            diagnostics.cardView.frame.height,
            400,
            "Diagnostics card must stay a compact card, not expand to the log document or page; card=\(diagnostics.cardView.frame.height) row=\(debugLogRow.frame.height) host=\(logHost.frame.height) page=\(host.bounds.height)"
        )
        XCTAssertGreaterThan(
            host.bounds.height,
            diagnostics.cardView.frame.height + 80,
            "the tall page host must have leftover space below the compact Diagnostics card"
        )
        XCTAssertGreaterThan(
            textView.frame.height,
            logHost.frame.height,
            "extra log text remains in the document and scrolls inside the 190pt viewer"
        )
    }

    func testLongNativeRowGrowsSectionHeightAtNarrowWidth() throws {
        let longDetail = "This native settings description must wrap onto additional lines when the dashboard content column is narrow so the section height follows the row instead of a cached card measurement."
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: longDetail,
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Startup", contentViews: [row])
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        DashboardSettingsLayoutMetrics.reset()
        let wideCardHeight = section.cardView.frame.height
        pin(section, to: host, window: window, width: 516)
        XCTAssertGreaterThanOrEqual(
            section.cardView.frame.height,
            wideCardHeight - 0.5
        )
        XCTAssertEqual(section.cardView.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(row.detailLabel.preferredMaxLayoutWidth, 1)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
    }

    func testHiddenRowsCollapseAndRestoreSectionIntrinsicHeight() throws {
        DashboardSettingsLayoutMetrics.reset()
        let master = SettingsRowView(title: "Master", accessoryView: NSSwitch())
        let dependent = SettingsRowView(
            title: "Dependent",
            detail: "This row hides with the master switch.",
            accessoryView: NSSwitch()
        )
        let extra = SettingsRowView(title: "Extra", accessoryView: NSSwitch())
        let section = SettingsSectionView(
            title: "Progress",
            contentViews: [master, dependent, extra]
        )
        XCTAssertTrue(section.cardView.detachesHiddenViews)
        XCTAssertTrue(section.contentStack.detachesHiddenViews)

        let window = makeTestWindow(width: 516, height: 640)
        let page = DashboardSettingsComponents.makeSettingsPageContent([section])
        let host = pinningHost(for: page, in: window, width: 516, height: 640)
        defer { window.orderOut(nil) }

        XCTAssertEqual(section.contentViews.filter { !$0.isHidden }.count, 3)
        let expandedCard = section.cardView.frame.height
        let expandedSection = section.frame.height
        let expandedIntrinsic = section.intrinsicContentSize.height
        XCTAssertGreaterThan(expandedCard, SettingsRowView.minimumHeight + 8)
        XCTAssertGreaterThan(expandedSection, expandedCard)
        XCTAssertEqual(expandedIntrinsic, expandedSection, accuracy: 1.0)
        XCTAssertEqual(
            section.cardView.frame.height,
            visibleArrangedHeight(in: section.cardView),
            accuracy: 1.0
        )

        dependent.isHidden = true
        extra.isHidden = true
        section.separators.forEach { $0.isHidden = true }
        section.cardView.invalidateHostedSettingsRowHeight()
        pin(page, to: host, window: window, width: 516, height: 640)

        XCTAssertEqual(section.contentViews.filter { !$0.isHidden }.count, 1)
        XCTAssertLessThan(section.cardView.frame.height + 8, expandedCard)
        XCTAssertLessThan(section.frame.height + 8, expandedSection)
        XCTAssertLessThan(section.intrinsicContentSize.height + 8, expandedIntrinsic)
        XCTAssertEqual(section.cardView.frame.height, master.frame.height, accuracy: 1.0)
        XCTAssertEqual(
            section.cardView.frame.height,
            visibleArrangedHeight(in: section.cardView),
            accuracy: 1.0
        )
        XCTAssertTrue(dependent.isHidden)
        XCTAssertTrue(extra.isHidden)

        dependent.isHidden = false
        extra.isHidden = false
        section.separators.forEach { $0.isHidden = false }
        section.cardView.invalidateHostedSettingsRowHeight()
        pin(page, to: host, window: window, width: 516, height: 640)

        XCTAssertEqual(section.contentViews.filter { !$0.isHidden }.count, 3)
        XCTAssertEqual(section.cardView.frame.height, expandedCard, accuracy: 1.0)
        XCTAssertEqual(section.frame.height, expandedSection, accuracy: 1.0)
        XCTAssertEqual(section.intrinsicContentSize.height, expandedIntrinsic, accuracy: 1.0)
        XCTAssertTrue(dependent.superview === section.cardView)
        XCTAssertTrue(extra.superview === section.cardView)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
    }

    func testSectionHeightRestoresAfterNarrowThenWideResize() throws {
        DashboardSettingsLayoutMetrics.reset()
        let longDetail = "This native settings description must wrap onto additional lines when the dashboard content column is narrow so the section intrinsic height follows Auto Layout instead of a parent-measured card height, then restore when the column is wide again."
        let row = SettingsRowView(
            title: "Keep Open",
            detail: longDetail,
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Behavior", contentViews: [row])
        let window = makeTestWindow(width: 880, height: 640)
        let page = DashboardSettingsComponents.makeSettingsPageContent([section])
        let host = pinningHost(for: page, in: window, width: 880, height: 640)
        defer { window.orderOut(nil) }

        let wideCard = section.cardView.frame.height
        let wideSection = section.frame.height
        let wideIntrinsic = section.intrinsicContentSize.height
        XCTAssertEqual(wideIntrinsic, wideSection, accuracy: 1.0)

        pin(page, to: host, window: window, width: 516, height: 640)
        XCTAssertGreaterThan(section.cardView.frame.height, wideCard - 0.5)
        XCTAssertGreaterThan(section.frame.height, wideSection - 0.5)
        XCTAssertGreaterThan(section.intrinsicContentSize.height, wideIntrinsic - 0.5)
        XCTAssertEqual(section.cardView.frame.height, row.frame.height, accuracy: 1.0)

        pin(page, to: host, window: window, width: 880, height: 640)
        XCTAssertEqual(section.cardView.frame.height, wideCard, accuracy: 1.0)
        XCTAssertEqual(section.frame.height, wideSection, accuracy: 1.0)
        XCTAssertEqual(section.intrinsicContentSize.height, wideIntrinsic, accuracy: 1.0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
    }

    func testRowInvalidationPropagatesToSectionIntrinsicContentSize() throws {
        DashboardSettingsLayoutMetrics.reset()
        let row = SettingsRowView(
            title: "Status Links",
            detail: "Short.",
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Links", contentViews: [row])
        let window = makeTestWindow(width: 516, height: 640)
        let page = DashboardSettingsComponents.makeSettingsPageContent([section])
        let host = pinningHost(for: page, in: window, width: 516, height: 640)
        defer { window.orderOut(nil) }

        let shortCard = section.cardView.frame.height
        let shortSection = section.intrinsicContentSize.height
        XCTAssertGreaterThan(shortSection, 0)

        row.detailLabel.stringValue = "This subtitle must wrap across several lines at the dashboard content width so invalidating the hosted row height bubbles to the section intrinsic size instead of a parent remeasurement loop."
        row.detailLabel.preferredMaxLayoutWidth = 0
        row.detailLabel.invalidateIntrinsicContentSize()
        row.invalidateIntrinsicContentSize()
        row.needsLayout = true
        section.cardView.invalidateHostedSettingsRowHeight()
        XCTAssertTrue(section.needsLayout)
        pin(page, to: host, window: window, width: 516, height: 640)

        XCTAssertGreaterThan(section.cardView.frame.height, shortCard + 8)
        XCTAssertGreaterThan(section.intrinsicContentSize.height, shortSection + 8)
        XCTAssertEqual(section.cardView.frame.height, row.frame.height, accuracy: 1.0)
        XCTAssertEqual(
            section.intrinsicContentSize.height,
            section.frame.height,
            accuracy: 1.0
        )
        XCTAssertFalse(
            section.cardView.constraints.contains { constraint in
                constraint.firstAttribute == .height
                    && constraint.secondItem == nil
                    && constraint.relation == .equal
                    && constraint.constant > 1
                    && constraint.identifier == "settingsCardHeight"
            }
        )
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.controlFittingMeasurements, 0)
    }

    private func makeTestWindow(width: CGFloat, height: CGFloat = 360) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func pinningHost(
        for section: NSView,
        in window: NSWindow,
        width: CGFloat,
        height: CGFloat = 360
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = host
        host.addSubview(section)
        pin(section, to: host, window: window, width: width, height: height)
        return host
    }

    private func pin(
        _ section: NSView,
        to host: NSView,
        window: NSWindow,
        width: CGFloat,
        height: CGFloat = 360
    ) {
        window.setContentSize(NSSize(width: width, height: height))
        host.setFrameSize(NSSize(width: width, height: height))
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.removeConstraints(host.constraints)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            section.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        var previousHeight: CGFloat = -1
        for _ in 0..<6 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            section.layoutSubtreeIfNeeded()
            refreshNativeRowWrapping(in: section)
            let fitted = section.fittingSize.height
            if abs(fitted - previousHeight) < 0.5 {
                break
            }
            previousHeight = fitted
        }
    }

    private func visibleArrangedHeight(in stack: NSStackView) -> CGFloat {
        let visible = stack.arrangedSubviews.filter { !$0.isHidden && $0.superview === stack }
        guard let minY = visible.map(\.frame.minY).min(),
              let maxY = visible.map(\.frame.maxY).max() else {
            return 0
        }
        return maxY - minY
    }

    private func refreshNativeRowWrapping(in view: NSView) {
        if let row = view as? SettingsRowView {
            row.refreshWrappingLayout()
        }
        view.subviews.forEach { refreshNativeRowWrapping(in: $0) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
