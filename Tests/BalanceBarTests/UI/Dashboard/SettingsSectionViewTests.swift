import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class SettingsSectionViewTests: XCTestCase {
    func testNativeSectionUsesAutoLayoutHierarchyAndSkipsLegacyCardHeightLoop() throws {
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
    }

    func testSectionHeightFollowsArrangedRowsAndSeparatorsWithoutParentRemeasurement() throws {
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

        pin(section, to: host, window: window, width: 516)
        let narrowHeight = first.frame.height
            + second.frame.height
            + DashboardSettingsComponents.settingsSeparatorHeight
        XCTAssertEqual(section.cardView.frame.height, narrowHeight, accuracy: 0.5)
        XCTAssertEqual(section.cardView.frame.width, section.frame.width, accuracy: 0.5)
        XCTAssertEqual(first.frame.width, section.cardView.frame.width, accuracy: 0.5)
    }

    func testMixedLegacyAndNativeRowsKeepBaselineCardHeightWithoutLegacyCardView() throws {
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
        XCTAssertGreaterThanOrEqual(legacy.frame.height, DashboardSettingsComponents.standardRowHeight)
        XCTAssertGreaterThanOrEqual(native.frame.height, SettingsRowView.minimumHeight)
    }

    func testGeneralStartupSectionUsesNativeContainerAndLeavesOtherCardsOnLegacyFactory() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "SettingsSectionViewTests.Startup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

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
        XCTAssertNil(SettingsSectionView.enclosing(openButton))

        let refreshButton = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardGeneralAndRefreshPagesRefreshNow) }
        )
        XCTAssertNil(SettingsSectionView.enclosing(refreshButton))
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
        let wideCardHeight = section.cardView.frame.height
        pin(section, to: host, window: window, width: 516)
        XCTAssertGreaterThanOrEqual(
            section.cardView.frame.height,
            wideCardHeight - 0.5
        )
        XCTAssertEqual(section.cardView.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(row.detailLabel.preferredMaxLayoutWidth, 1)
    }

    private func makeTestWindow(width: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func pinningHost(for section: NSView, in window: NSWindow, width: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 360))
        window.contentView = host
        host.addSubview(section)
        pin(section, to: host, window: window, width: width)
        return host
    }

    private func pin(_ section: NSView, to host: NSView, window: NSWindow, width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 360))
        host.setFrameSize(NSSize(width: width, height: 360))
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.removeConstraints(host.constraints)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            section.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        section.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
