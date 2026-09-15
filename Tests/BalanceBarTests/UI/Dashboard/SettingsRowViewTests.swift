import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class SettingsRowViewTests: XCTestCase {
    func testNativeRowUsesStackLayoutAndSkipsLegacyHeightCaches() throws {
        DashboardSettingsLayoutMetrics.reset()
        let control = NSSwitch()
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: "Start in the background without opening the dashboard.",
            accessoryView: control
        )

        XCTAssertTrue(row is NSStackView)
        XCTAssertEqual(row.orientation, .horizontal)
        XCTAssertEqual(row.alignment, .centerY)
        XCTAssertEqual(row.spacing, SettingsRowView.contentSpacing)
        XCTAssertEqual(row.titleLabel.font, .systemFont(ofSize: 14, weight: .semibold))
        XCTAssertEqual(row.detailLabel.font, .systemFont(ofSize: 12))
        XCTAssertEqual(row.detailLabel.textColor, .secondaryLabelColor)
        XCTAssertFalse(row.titleLabel.usesSingleLineMode)
        XCTAssertFalse(row.detailLabel.usesSingleLineMode)
        XCTAssertEqual(row.titleLabel.maximumNumberOfLines, 0)
        XCTAssertEqual(row.detailLabel.maximumNumberOfLines, 0)
        XCTAssertEqual(row.contentHuggingPriority(for: .vertical), .required)
        XCTAssertEqual(row.contentCompressionResistancePriority(for: .vertical), .required)
        XCTAssertEqual(row.contentHuggingPriority(for: .horizontal), .defaultLow)
        XCTAssertEqual(row.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
        XCTAssertEqual(control.contentHuggingPriority(for: .horizontal), .required)
        XCTAssertEqual(control.contentCompressionResistancePriority(for: .horizontal), .required)
        XCTAssertEqual(row.titleLabel.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
        XCTAssertEqual(row.detailLabel.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
        XCTAssertIdentical(row.accessoryView, control)

        let section = DashboardSettingsComponents.makeSettingsSection(
            "Native row",
            rows: [row]
        )
        let window = makeTestWindow(width: 640)
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.textLineMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.controlFittingMeasurements, 0)
    }

    func testLongDetailWrapsAndGrowsHeightAtNarrowWidthWithoutOverlappingControl() throws {
        let longDetail = "This native settings description must wrap onto additional lines when the dashboard content column is narrow so the switch stays visible beside the complete text."
        let control = NSSwitch()
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: longDetail,
            accessoryView: control
        )
        let peer = DashboardSettingsComponents.makeSettingsRow("Peer")
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Native wrapping",
            rows: [row, peer]
        )
        let window = makeTestWindow(width: 880)
        window.contentView = section
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 360))
            window.layoutIfNeeded()
            section.layoutSubtreeIfNeeded()
        }

        layout(at: 880)
        let wideHeight = row.frame.height
        let wideWrappingWidth = row.detailLabel.preferredMaxLayoutWidth
        XCTAssertGreaterThan(wideWrappingWidth, 1)
        XCTAssertGreaterThanOrEqual(wideHeight, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(peer.frame.height, DashboardSettingsComponents.standardRowHeight)
        assertLabelsDoNotOverlapControl(in: row, control: control, width: 880)

        layout(at: 516)
        let narrowHeight = row.frame.height
        XCTAssertGreaterThan(row.detailLabel.preferredMaxLayoutWidth, 1)
        XCTAssertLessThan(row.detailLabel.preferredMaxLayoutWidth, wideWrappingWidth)
        XCTAssertGreaterThanOrEqual(narrowHeight, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(
            narrowHeight,
            wideHeight - 0.5,
            "wrapping at the narrow content width must not shrink the native row"
        )
        let wrappedDetailHeight = row.detailLabel.cell?.cellSize(
            forBounds: NSRect(
                x: 0,
                y: 0,
                width: max(1, row.detailLabel.bounds.width),
                height: 10_000
            )
        ).height ?? 0
        XCTAssertGreaterThan(
            wrappedDetailHeight,
            16,
            "detail text wraps to more than a single clipped line at the narrow width"
        )
        assertLabelsDoNotOverlapControl(in: row, control: control, width: 516)
        XCTAssertFalse(row.titleLabel.stringValue.isEmpty)
        XCTAssertEqual(row.detailLabel.stringValue, longDetail)
    }

    func testGeneralSilentLaunchRowUsesNativeSettingsRowView() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let suiteName = "SettingsRowViewTests.SilentLaunch.\(UUID().uuidString)"
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
        let row = try XCTUnwrap(silentLaunchSwitch.superview as? SettingsRowView)
        XCTAssertEqual(
            row.titleLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesSilentLaunch)
        )
        XCTAssertEqual(
            row.detailLabel.stringValue,
            tr(.keyDashboardGeneralAndRefreshPagesSilentLaunchDescription)
        )
        XCTAssertIdentical(row.accessoryView, silentLaunchSwitch)

        let launchAtLoginSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
        )
        XCTAssertNil(launchAtLoginSwitch.superview as? SettingsRowView)
    }

    private func assertLabelsDoNotOverlapControl(
        in row: SettingsRowView,
        control: NSView,
        width: CGFloat
    ) {
        let labelsFrame = row.titleLabel.superview.map {
            $0.convert($0.bounds, to: row)
        } ?? row.titleLabel.convert(row.titleLabel.bounds, to: row)
        let controlFrame = control.convert(control.bounds, to: row)
        XCTAssertTrue(
            row.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame),
            "labels stay inside the native row at \(width)"
        )
        XCTAssertTrue(
            row.bounds.insetBy(dx: 0, dy: -0.5).contains(controlFrame),
            "control stays inside the native row at \(width)"
        )
        XCTAssertFalse(
            labelsFrame.intersects(controlFrame),
            "labels do not overlap the trailing control at \(width)"
        )
    }

    private func makeTestWindow(width: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
