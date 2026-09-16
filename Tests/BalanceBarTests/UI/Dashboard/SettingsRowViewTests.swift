import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class SettingsRowViewTests: XCTestCase {
    func testNativeRowUsesAutoLayoutHierarchyAndSkipsLegacyHeightCaches() throws {
        DashboardSettingsLayoutMetrics.reset()
        let control = NSSwitch()
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: "Start in the background without opening the dashboard.",
            accessoryView: control
        )

        XCTAssertFalse(row is NSStackView)
        XCTAssertEqual(row.contentStack.orientation, .horizontal)
        XCTAssertEqual(row.contentStack.alignment, .centerY)
        XCTAssertEqual(row.contentStack.spacing, SettingsRowView.contentSpacing)
        XCTAssertEqual(row.labelsStack.orientation, .vertical)
        XCTAssertEqual(row.labelsStack.spacing, SettingsRowView.labelSpacing)
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
        XCTAssertIdentical(control.superview, row.contentStack)
        XCTAssertIdentical(SettingsRowView.enclosing(control), row)

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
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) {
            pin(section, to: host, window: window, width: width)
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
        XCTAssertLessThan(
            row.detailLabel.preferredMaxLayoutWidth,
            wideWrappingWidth,
            "narrow layout must shrink wrapping width; row=\(row.frame) labels=\(row.labelsStack.bounds) preferred=\(row.detailLabel.preferredMaxLayoutWidth) host=\(host.bounds)"
        )
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

    func testLongTitleWrapsAndGrowsHeightAtNarrowWidthWithoutOverlappingControl() throws {
        let longTitle = "This native settings title must wrap onto additional lines when the dashboard content column is too narrow to keep it on one line beside the switch."
        let control = NSSwitch()
        let row = SettingsRowView(
            title: longTitle,
            detail: "Keep the detail visible while the title wraps.",
            accessoryView: control
        )
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Native title wrapping",
            rows: [row]
        )
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) {
            pin(section, to: host, window: window, width: width)
        }

        layout(at: 880)
        let wideHeight = row.frame.height
        let wideWrappingWidth = row.titleLabel.preferredMaxLayoutWidth
        XCTAssertGreaterThan(wideWrappingWidth, 1)
        assertLabelsDoNotOverlapControl(in: row, control: control, width: 880)

        layout(at: 516)
        XCTAssertGreaterThan(row.titleLabel.preferredMaxLayoutWidth, 1)
        XCTAssertLessThan(row.titleLabel.preferredMaxLayoutWidth, wideWrappingWidth)
        XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(
            row.frame.height,
            wideHeight - 0.5,
            "a wrapping title must not shrink the native row"
        )
        let wrappedTitleHeight = row.titleLabel.cell?.cellSize(
            forBounds: NSRect(
                x: 0,
                y: 0,
                width: max(1, row.titleLabel.bounds.width),
                height: 10_000
            )
        ).height ?? 0
        XCTAssertGreaterThan(
            wrappedTitleHeight,
            20,
            "title text wraps to more than a single clipped line at the narrow width"
        )
        assertLabelsDoNotOverlapControl(in: row, control: control, width: 516)
        XCTAssertEqual(row.titleLabel.stringValue, longTitle)
    }

    func testDualButtonRowWrappingSettlesAcrossWideNarrowWideResize() throws {
        let accessory = NSStackView(views: [
            NSButton(title: "Reload", target: nil, action: nil),
            NSButton(title: "Show in Finder", target: nil, action: nil)
        ])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.setHuggingPriority(.required, for: .horizontal)
        accessory.setClippingResistancePriority(.required, for: .horizontal)
        let row = SettingsRowView(
            title: "Debug Log",
            detail: "Records runtime status and errors so wrapping must follow the remaining label width beside the two trailing buttons.",
            accessoryView: accessory
        )
        let section = SettingsSectionView(title: "Diagnostics", contentViews: [row])
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        var wrappingByWidth: [CGFloat: CGFloat] = [:]
        var heightByWidth: [CGFloat: CGFloat] = [:]
        for width in [880, 640, 516, 720, 880, 516] as [CGFloat] {
            pin(section, to: host, window: window, width: width)
            let wrappingWidth = row.detailLabel.preferredMaxLayoutWidth
            XCTAssertGreaterThan(wrappingWidth, 1)
            section.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                row.detailLabel.preferredMaxLayoutWidth,
                wrappingWidth,
                accuracy: 0.5,
                "wrapping width must already be settled after layout; layout must not keep mutating it at \(width)"
            )
            XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
            assertLabelsDoNotOverlapControl(in: row, control: accessory, width: width)
            wrappingByWidth[width] = wrappingWidth
            heightByWidth[width] = row.frame.height
        }
        XCTAssertGreaterThan(
            wrappingByWidth[880] ?? 0,
            wrappingByWidth[516] ?? 0,
            "narrower rows must wrap against a smaller preferredMaxLayoutWidth"
        )
        XCTAssertGreaterThanOrEqual(
            heightByWidth[516] ?? 0,
            heightByWidth[880] ?? 0,
            "narrow width must not shrink the dual-button row below its wide height"
        )
    }

    func testWrappingHeightCommitsAfterLiveResizeEndsWithoutLayoutInvalidation() throws {
        let longDetail = "This native settings description must wrap onto additional lines when the dashboard content column is narrow so the switch stays visible beside the complete text."
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: longDetail,
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Startup", contentViews: [row])
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: section, in: window, width: 880)
        defer { window.orderOut(nil) }

        let wideHeight = row.frame.height
        let wideWrappingWidth = row.detailLabel.preferredMaxLayoutWidth
        XCTAssertGreaterThan(wideWrappingWidth, 1)

        window.setContentSize(NSSize(width: 516, height: 360))
        host.setFrameSize(NSSize(width: 516, height: 360))
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()
        XCTAssertLessThan(row.detailLabel.preferredMaxLayoutWidth, wideWrappingWidth)
        XCTAssertGreaterThan(row.detailLabel.preferredMaxLayoutWidth, 1)

        row.viewDidEndLiveResize()
        XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(
            row.frame.height,
            wideHeight - 0.5,
            "viewDidEndLiveResize must commit wrapping height after a narrow resize"
        )
    }

    func testRepeatedLayoutPassesDoNotChurnWrappingWidth() throws {
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: "Start in the background without opening the dashboard.",
            accessoryView: NSSwitch()
        )
        let section = SettingsSectionView(title: "Startup", contentViews: [row])
        let window = makeTestWindow(width: 640)
        _ = pinningHost(for: section, in: window, width: 640)
        defer { window.orderOut(nil) }

        let wrappingWidth = row.detailLabel.preferredMaxLayoutWidth
        XCTAssertGreaterThan(wrappingWidth, 1)
        for _ in 0..<24 {
            row.layoutSubtreeIfNeeded()
            section.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }
        XCTAssertEqual(
            row.detailLabel.preferredMaxLayoutWidth,
            wrappingWidth,
            accuracy: 0.5,
            "stable width must not keep mutating preferredMaxLayoutWidth across extra layout passes"
        )
        XCTAssertGreaterThanOrEqual(row.frame.height, SettingsRowView.minimumHeight)
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
        let row = try XCTUnwrap(SettingsRowView.enclosing(silentLaunchSwitch))
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
        XCTAssertNil(SettingsRowView.enclosing(launchAtLoginSwitch))

        let launchWithChatGPTSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == LaunchWithChatGPTController.toggleIdentifier }
        )
        XCTAssertNil(SettingsRowView.enclosing(launchWithChatGPTSwitch))
    }

    func testTitleToSubtitleVisualSpacingMatchesLegacyRowInTheSameCard() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let legacyControl = NSSwitch()
        let nativeControl = NSSwitch()
        let legacyRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
            subtitle: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription),
            control: legacyControl
        )
        let nativeRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunch),
            detail: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunchDescription),
            accessoryView: nativeControl
        )
        let section = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardGeneralAndRefreshPagesStartup),
            rows: [legacyRow, nativeRow]
        )
        let window = makeTestWindow(width: 880)
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()

        let legacyFields = descendants(of: legacyRow).compactMap { $0 as? NSTextField }
        let legacyTitle = try XCTUnwrap(
            legacyFields.first { $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin) }
        )
        let legacySubtitle = try XCTUnwrap(
            legacyFields.first { $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription) }
        )

        assertLabelUsesIntrinsicHeight(legacyTitle, name: "legacy title")
        assertLabelUsesIntrinsicHeight(legacySubtitle, name: "legacy subtitle")
        assertLabelUsesIntrinsicHeight(nativeRow.titleLabel, name: "native title")
        assertLabelUsesIntrinsicHeight(nativeRow.detailLabel, name: "native subtitle")

        let legacyVisual = visualTitleToSubtitleSpacing(title: legacyTitle, subtitle: legacySubtitle)
        let nativeVisual = visualTitleToSubtitleSpacing(
            title: nativeRow.titleLabel,
            subtitle: nativeRow.detailLabel
        )
        let legacyBaseline = titleToSubtitleBaselineSpacing(title: legacyTitle, subtitle: legacySubtitle)
        let nativeBaseline = titleToSubtitleBaselineSpacing(
            title: nativeRow.titleLabel,
            subtitle: nativeRow.detailLabel
        )

        XCTAssertGreaterThanOrEqual(legacyVisual, 0)
        XCTAssertEqual(
            nativeVisual,
            legacyVisual,
            accuracy: 1.0,
            "native drawn title-to-subtitle gap must match a same-card legacy row"
        )
        XCTAssertEqual(
            nativeBaseline,
            legacyBaseline,
            accuracy: 1.0,
            "native title-to-subtitle baseline gap must match a same-card legacy row"
        )
    }

    func testGeneralSilentLaunchVisualSpacingMatchesNeighboringLegacyRow() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "SettingsRowViewTests.SilentLaunchSpacing.\(UUID().uuidString)"
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
        let window = makeTestWindow(width: 880)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 760))
        window.contentView = host
        host.addSubview(page)
        page.setFrameSize(host.bounds.size)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        page.layoutSubtreeIfNeeded()
        descendants(of: page).compactMap { $0 as? SettingsRowView }.forEach {
            $0.refreshWrappingLayout()
        }
        page.layoutSubtreeIfNeeded()

        let silentLaunchSwitch = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == AppPreferences.silentLaunchKey }
        )
        let nativeRow = try XCTUnwrap(SettingsRowView.enclosing(silentLaunchSwitch))
        let launchAtLoginTitle = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin) }
        )
        let launchAtLoginSubtitle = try XCTUnwrap(
            descendants(of: page)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription) }
        )

        assertLabelUsesIntrinsicHeight(nativeRow.titleLabel, name: "Silent Launch title")
        assertLabelUsesIntrinsicHeight(nativeRow.detailLabel, name: "Silent Launch subtitle")
        assertLabelUsesIntrinsicHeight(launchAtLoginTitle, name: "登录时自动启动 title")
        assertLabelUsesIntrinsicHeight(launchAtLoginSubtitle, name: "登录时自动启动 subtitle")

        let legacyVisual = visualTitleToSubtitleSpacing(
            title: launchAtLoginTitle,
            subtitle: launchAtLoginSubtitle
        )
        let nativeVisual = visualTitleToSubtitleSpacing(
            title: nativeRow.titleLabel,
            subtitle: nativeRow.detailLabel
        )
        XCTAssertEqual(
            nativeVisual,
            legacyVisual,
            accuracy: 1.0,
            "Silent Launch drawn title-to-subtitle gap must match 登录时自动启动. "
            + "A stretched title field (frame taller than intrinsic height) is the "
            + "regression from f840971: frame edge gap stayed 2pt while glyphs sat farther apart."
        )

        let legacyBaseline = titleToSubtitleBaselineSpacing(
            title: launchAtLoginTitle,
            subtitle: launchAtLoginSubtitle
        )
        let nativeBaseline = titleToSubtitleBaselineSpacing(
            title: nativeRow.titleLabel,
            subtitle: nativeRow.detailLabel
        )
        XCTAssertEqual(
            nativeBaseline,
            legacyBaseline,
            accuracy: 1.0,
            "Silent Launch baseline gap must match 登录时自动启动 in the Startup card"
        )
    }

    private func assertLabelsDoNotOverlapControl(
        in row: SettingsRowView,
        control: NSView,
        width: CGFloat
    ) {
        let labelsFrame = row.labelsStack.convert(row.labelsStack.bounds, to: row)
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

    private func assertLabelUsesIntrinsicHeight(_ field: NSTextField, name: String) {
        let intrinsicHeight = field.intrinsicContentSize.height
        XCTAssertGreaterThan(intrinsicHeight, 0, "\(name) has a real intrinsic height")
        XCTAssertEqual(
            field.bounds.height,
            intrinsicHeight,
            accuracy: 1.0,
            "\(name) must not be stretched vertically; stretched title fields keep a 2pt frame gap while the drawn glyphs sit farther apart"
        )
    }

    /// Drawn-text gap assuming AppKit `NSTextField` paints from the top of the field.
    /// Using frame-edge distance alone missed the f840971 regression: the title
    /// field was stretched 17→23pt, frame gap stayed 2pt, visual gap became ~8pt.
    private func visualTitleToSubtitleSpacing(title: NSTextField, subtitle: NSTextField) -> CGFloat {
        let container = title.superview ?? title
        let titleFrame = title.convert(title.bounds, to: container)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: container)
        let titleTextHeight = max(title.intrinsicContentSize.height, 1)
        let titleTextMinY = titleFrame.maxY - titleTextHeight
        return titleTextMinY - subtitleFrame.maxY
    }

    private func titleToSubtitleBaselineSpacing(title: NSTextField, subtitle: NSTextField) -> CGFloat {
        let container = title.superview ?? title
        let titleFrame = title.convert(title.bounds, to: container)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: container)
        let titleBaselineY = titleFrame.maxY - title.firstBaselineOffsetFromTop
        let subtitleBaselineY = subtitleFrame.maxY - subtitle.firstBaselineOffsetFromTop
        return titleBaselineY - subtitleBaselineY
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
        refreshNativeRowWrapping(in: section)
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()
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
