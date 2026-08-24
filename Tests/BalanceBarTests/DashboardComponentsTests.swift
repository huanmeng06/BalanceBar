import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardComponentsTests: XCTestCase {
    func testDashboardSectionsPreserveNavigationOrderAndMetadata() {
        let sections = DashboardSection.allCases

        XCTAssertEqual(sections.map(\.rawValue), Array(0..<5))
        XCTAssertEqual(sections.map(\.symbolName), [
            "gearshape.fill",
            "menubar.rectangle",
            "filemenu.and.selection",
            "slider.horizontal.3",
            "info.circle.fill"
        ])
        XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(DashboardSection(rawValue: 2), .menu)
        XCTAssertNil(DashboardSection(rawValue: 5))
    }

    func testSettingsSectionSeparatorsMatchRowsAndPreserveSelectionRules() throws {
        let rows = [
            DashboardSettingsComponents.makeSettingsRow("First"),
            DashboardSettingsComponents.makeSettingsRow("Second"),
            DashboardSettingsComponents.makeSettingsRow("Third")
        ]
        var rowsStack: NSStackView?
        var separators: [NSView] = []
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Layout",
            rows: rows,
            onLayoutCreated: { stack, _, createdSeparators in
                rowsStack = stack
                separators = createdSeparators
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = section
        window.layoutIfNeeded()

        let stack = try XCTUnwrap(rowsStack)
        XCTAssertEqual(separators.count, rows.count - 1)
        assertSettingsSeparatorWidths(
            separators,
            rows: rows,
            matching: stack
        )

        window.setContentSize(NSSize(width: 680, height: 280))
        window.layoutIfNeeded()
        assertSettingsSeparatorWidths(
            separators,
            rows: rows,
            matching: stack
        )

        let singleRow = DashboardSettingsComponents.makeSettingsRow("Single")
        var singleSeparators: [NSView] = []
        _ = DashboardSettingsComponents.makeSettingsSection(
            "Single row",
            rows: [singleRow],
            onLayoutCreated: { _, _, createdSeparators in
                singleSeparators = createdSeparators
            }
        )
        XCTAssertTrue(singleSeparators.isEmpty)

        let selectiveRows = [
            DashboardSettingsComponents.makeSettingsRow("Visible"),
            DashboardSettingsComponents.makeSettingsRow("Hidden"),
            DashboardSettingsComponents.makeSettingsRow("Last")
        ]
        selectiveRows[1].isHidden = true
        var selectiveStack: NSStackView?
        var selectiveSeparators: [NSView] = []
        let selectiveSection = DashboardSettingsComponents.makeSettingsSection(
            "Selective",
            rows: selectiveRows,
            separatorIndices: [0],
            onLayoutCreated: { stack, _, createdSeparators in
                selectiveStack = stack
                selectiveSeparators = createdSeparators
            }
        )
        window.contentView = selectiveSection
        window.layoutIfNeeded()

        let selectiveRowsStack = try XCTUnwrap(selectiveStack)
        XCTAssertEqual(selectiveSeparators.count, 1)
        assertSettingsSeparatorWidths(
            selectiveSeparators,
            rows: selectiveRows,
            matching: selectiveRowsStack
        )
    }

    func testSettingsRowsAdaptToLocalizedSubtitleHeightAcrossWindowWidths() throws {
        let fixtures: [(String, String)] = [
            ("简体中文", "这是用于验证窗口缩放后副标题完整换行并同步更新卡片高度的长说明文字示例。"),
            ("繁體中文", "這是用於驗證視窗縮放後副標題完整換行並同步更新卡片高度的長說明文字範例。"),
            ("日本語", "これはウィンドウ幅の変更後も副題が完全に折り返され、カードの高さが更新されることを確認する説明文です。"),
            ("English", "This subtitle verifies resized-window wrapping and keeps the full settings text visible.")
        ]

        for (language, longSubtitle) in fixtures {
            let subtitle = NSTextField(wrappingLabelWithString: longSubtitle)
            let control = NSSwitch()
            let longRow = DashboardSettingsComponents.makeSettingsRow(
                "Localized title",
                subtitle: longSubtitle,
                subtitleLabel: subtitle,
                control: control
            )
            let shortRow = DashboardSettingsComponents.makeSettingsRow("Short title")
            var rowsStack: NSStackView?
            var separators: [NSView] = []
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Localized settings",
                rows: [longRow, shortRow],
                onLayoutCreated: { stack, _, createdSeparators in
                    rowsStack = stack
                    separators = createdSeparators
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 516, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
                window.setContentSize(NSSize(width: width, height: 360))
                window.layoutIfNeeded()
                let stack = try XCTUnwrap(rowsStack)
                let card = try XCTUnwrap(stack.superview)
                return (longRow.frame.height, card.frame.height)
            }

            let narrow = try layout(at: 516)
            XCTAssertGreaterThan(narrow.rowHeight, 62, "(language) long subtitle should grow at narrow width")
            XCTAssertEqual(
                narrow.cardHeight,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: try XCTUnwrap(rowsStack),
                    separators: separators
                ),
                accuracy: 0.5,
                "(language) card height must follow visible row and separator heights"
            )
            XCTAssertEqual(shortRow.frame.height, 62, accuracy: 0.5, "(language) short row minimum height")

            let labels = try XCTUnwrap(longRow.subviews.compactMap { $0 as? NSStackView }.first)
            let subtitleFrame = subtitle.convert(subtitle.bounds, to: longRow)
            let labelsFrame = labels.convert(labels.bounds, to: longRow)
            XCTAssertTrue(longRow.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame), "(language) labels must stay in row")
            XCTAssertLessThanOrEqual(
                subtitle.cell!.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: subtitle.bounds.width, height: .greatestFiniteMagnitude)
                ).height,
                subtitleFrame.height + 0.5,
                "(language) subtitle must fit its frame"
            )
            XCTAssertEqual(control.frame.midY, longRow.bounds.midY, accuracy: 0.5, "(language) control must stay centered")
            XCTAssertEqual(separators.count, 1)
            XCTAssertEqual(separators[0].frame.width, rowsStack!.frame.width, accuracy: 0.5)

            let wide = try layout(at: 740)
            XCTAssertLessThan(wide.rowHeight, narrow.rowHeight, "(language) row should shrink after widening")
            XCTAssertLessThan(wide.cardHeight, narrow.cardHeight, "(language) card should shrink after widening")

            let narrowAgain = try layout(at: 516)
            XCTAssertEqual(narrowAgain.rowHeight, narrow.rowHeight, accuracy: 0.5, "(language) narrow layout must be reversible")
            XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5, "(language) card height must be reversible")

            subtitle.stringValue = "Short subtitle"
            subtitle.invalidateIntrinsicContentSize()
            longRow.needsLayout = true
            section.needsLayout = true
            window.layoutIfNeeded()
            XCTAssertEqual(longRow.frame.height, 62, accuracy: 0.5, "(language) content changes must shrink the row")
            XCTAssertEqual(shortRow.frame.height, 62, accuracy: 0.5, "(language) sibling minimum height must remain stable")
        }
    }

    func testNavigationRowAppliesSelectedAndInactiveStates() {
        let row = DashboardNavigationRowView()
        row.wantsLayer = true
        let icon = NSImageView()
        let title = NSTextField(labelWithString: "Menu")
        row.addSubview(icon)
        row.addSubview(title)
        row.iconView = icon
        row.titleLabel = title

        row.isSelected = true
        row.updateAppearance(animated: false)
        XCTAssertTrue(row.isSelected)
        XCTAssertTrue(icon.contentTintColor?.isEqual(NSColor.controlAccentColor) == true)
        XCTAssertTrue(title.textColor?.isEqual(NSColor.controlAccentColor) == true)

        row.isSelected = false
        row.updateAppearance(animated: false)
        XCTAssertFalse(row.isSelected)
        XCTAssertTrue(icon.contentTintColor?.isEqual(NSColor.secondaryLabelColor) == true)
        XCTAssertTrue(title.textColor?.isEqual(NSColor.secondaryLabelColor) == true)
    }

    func testQuotaProgressClampsValuesAndPreservesColorBoundaries() {
        XCTAssertEqual(QuotaProgressView(percentage: -1).percentage, 0)
        XCTAssertEqual(QuotaProgressView(percentage: 101).percentage, 100)

        XCTAssertTrue(QuotaProgressView.progressColor(for: 0).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 9.99).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 10).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 24.99).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 25).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50.01).isEqual(NSColor.systemGreen))
    }

    func testHoverLinkInvokesActivationCallbackOnMouseDown() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()
        var activationCount = 0
        link.onActivate = { activationCount += 1 }

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))

        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkActivatesOnlyInsideVisibleTextHitRect() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        for x in [
            link.visibleTextHitRect.minX + 1,
            link.visibleTextHitRect.midX,
            link.visibleTextHitRect.maxX - 1
        ] {
            link.mouseDown(with: makeMouseEvent(
                type: .leftMouseDown,
                location: NSPoint(x: x, y: link.visibleTextHitRect.midY)
            ))
        }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 3)
    }

    func testHoverLinkTruncationUsesOnlyVisibleRenderedText() {
        let link = HoverLinkTextField(text: "A very long provider name that must truncate")
        link.frame = NSRect(x: 0, y: 0, width: 90, height: 20)
        link.layout()

        XCTAssertGreaterThan(link.visibleTextHitRect.width, 0)
        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 6, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 0)
    }

    func testHoverLinkBlankAreaUsesArrowCursorAndDoesNotUnderline() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        let blankEvent = makeMouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        )
        link.cursorUpdate(with: blankEvent)
        link.mouseEntered(with: blankEvent)

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkRebuildsOneCursorTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertEqual(link.trackingAreas[0].rect, link.visibleTextHitRect)
        XCTAssertTrue(link.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(link.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.inVisibleRect))

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
    }

    func testHoverLinkRemovalClearsHoverStyleAndTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.updateTrackingAreas()

        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            return XCTFail("Expected to create a mouse event")
        }

        link.mouseEntered(with: event)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        link.removeFromSuperview()

        XCTAssertEqual(link.trackingAreas.count, 0)
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkCursorUpdateUsesPointingHandWithoutClick() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        link.cursorUpdate(with: makeMouseEvent(type: .mouseMoved, location: link.visibleTextHitRect.center))

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            fatalError("Expected to create a mouse event")
        }
        return event
    }

    private func assertSettingsSeparatorWidths(
        _ separators: [NSView],
        rows: [NSView],
        matching rowsStack: NSStackView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in rows {
            XCTAssertEqual(row.frame.width, rowsStack.frame.width, accuracy: 0.5, file: file, line: line)
        }
        for separator in separators {
            XCTAssertEqual(separator.frame.width, rowsStack.frame.width, accuracy: 0.5, file: file, line: line)
        }
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
