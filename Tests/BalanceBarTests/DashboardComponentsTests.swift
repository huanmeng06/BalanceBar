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

    func testSettingsMeasurementCachesIgnoreViewportRelayouts() throws {
        let rows = (0..<5).map { index in
            DashboardSettingsComponents.makeSettingsRow(
                "Stable row \(index)",
                subtitle: "The content and controls stay unchanged while only the scroll viewport origin moves.",
                control: NSSwitch()
            )
        }
        var rowsStack: NSStackView?
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Stable measurements",
            rows: rows,
            onLayoutCreated: { stack, _, _ in
                rowsStack = stack
            }
        )
        let page = DashboardSettingsComponents.makeSettingsPage([section])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        let stack = try XCTUnwrap(rowsStack)
        DashboardSettingsComponents.resetMeasurementCountersForTesting()

        for offset in [CGFloat(0), 24, 48, 72, 96, 120, 48, 0] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Re-run the document layout to model layout pressure around a
            // viewport-origin change without changing any row input.
            stack.needsLayout = true
            stack.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }

        let counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertEqual(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertEqual(counters.textLineMeasurements, 0)
        XCTAssertEqual(counters.cardHeightMeasurements, 0)
    }

    func testSettingsRenderingInstrumentationTracksViewportActivity() throws {
        let rows = (0..<12).map { index in
            DashboardSettingsComponents.makeSettingsRow(
                "Rendering probe \(index)",
                subtitle: "Scrolling changes the clip origin without changing any row content.",
                control: NSSwitch()
            )
        }
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Rendering",
            rows: rows
        )
        let page = DashboardSettingsComponents.makeSettingsPage([section])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let previousEnabled = DashboardSettingsComponents.renderingInstrumentationEnabledForTesting
        defer {
            DashboardSettingsComponents.renderingInstrumentationEnabledForTesting = previousEnabled
            DashboardSettingsComponents.resetRenderingCountersForTesting()
        }
        DashboardSettingsComponents.renderingInstrumentationEnabledForTesting = true
        DashboardSettingsComponents.resetRenderingCountersForTesting()
        window.contentView = page
        window.orderFrontRegardless()
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        for offset in [CGFloat(0), 24, 48, 0] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window.displayIfNeeded()
        }

        let counters = DashboardSettingsComponents.renderingCountersForTesting
        XCTAssertGreaterThan(counters.clipBoundsChanges, 0)
        // Headless xctest does not guarantee a backing-store display pass;
        // draw/updateLayer counters are intentionally validated by the local
        // Instruments run described in the Issue handoff.
    }

    func testSettingsWidthSweepReusesRegimeAndRecomputesAtBreakpoint() throws {
        let row = DashboardSettingsComponents.makeSettingsRow(
            "Stable width",
            subtitle: "A short stable summary stays on one line during this width sweep.",
            control: NSSwitch()
        )
        var rowsStack: NSStackView?
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Width regime",
            rows: [row],
            onLayoutCreated: { stack, _, _ in
                rowsStack = stack
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        let stack = try XCTUnwrap(rowsStack)
        let wideHeight = row.frame.height

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        for width in stride(from: CGFloat(760), through: 700, by: -2) {
            window.setContentSize(NSSize(width: width, height: 300))
            stack.needsLayout = true
            window.layoutIfNeeded()
        }
        var counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertLessThanOrEqual(counters.rowPreferredHeightMeasurements, 1)
        XCTAssertLessThanOrEqual(counters.textLineMeasurements, 4)
        XCTAssertLessThanOrEqual(counters.controlFittingMeasurements, 1)
        XCTAssertLessThanOrEqual(counters.cardHeightMeasurements, 1)
        XCTAssertEqual(row.frame.height, wideHeight, accuracy: 0.5)

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        window.setContentSize(NSSize(width: 280, height: 300))
        stack.needsLayout = true
        window.layoutIfNeeded()
        counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertGreaterThan(row.frame.height, wideHeight)
        XCTAssertGreaterThan(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertGreaterThan(counters.textLineMeasurements, 0)
        XCTAssertGreaterThan(counters.cardHeightMeasurements, 0)

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        window.setContentSize(NSSize(width: 760, height: 300))
        stack.needsLayout = true
        window.layoutIfNeeded()
        counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertEqual(row.frame.height, wideHeight, accuracy: 0.5)
        XCTAssertGreaterThan(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertGreaterThan(counters.cardHeightMeasurements, 0)
    }

    func testSettingsMeasurementCachesInvalidateForWidthTextAndVisibilityChanges() throws {
        let longSubtitle = "A deliberately long subtitle changes its natural line budget when the row width or text content changes."
        let subtitle = NSTextField(wrappingLabelWithString: longSubtitle)
        let row = DashboardSettingsComponents.makeSettingsRow(
            "Cache invalidation",
            subtitle: longSubtitle,
            subtitleLabel: subtitle,
            control: NSButton(title: "Action", target: nil, action: nil)
        )
        var rowsStack: NSStackView?
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Invalidation",
            rows: [row],
            onLayoutCreated: { stack, _, _ in
                rowsStack = stack
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()

        let stack = try XCTUnwrap(rowsStack)
        let initialHeight = row.frame.height

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        subtitle.stringValue = String(
            repeating: "The subtitle content is now substantially longer and must be measured again. ",
            count: 4
        )
        subtitle.invalidateIntrinsicContentSize()
        DashboardSettingsComponents.invalidateSettingsRowContent(containing: subtitle)
        row.needsLayout = true
        stack.needsLayout = true
        window.layoutIfNeeded()
        var counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertGreaterThan(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertGreaterThan(counters.textLineMeasurements, 0)
        XCTAssertGreaterThan(counters.cardHeightMeasurements, 0)
        XCTAssertGreaterThan(row.frame.height, initialHeight)

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        let control = try XCTUnwrap(row.subviews.first { $0 is NSButton } as? NSButton)
        control.title = "A longer action title changes the control fitting width."
        control.invalidateIntrinsicContentSize()
        DashboardSettingsComponents.invalidateSettingsRowControlMetrics(containing: control)
        row.needsLayout = true
        stack.needsLayout = true
        window.layoutIfNeeded()
        counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertGreaterThan(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertEqual(counters.cardHeightMeasurements, 0)

        DashboardSettingsComponents.resetMeasurementCountersForTesting()
        subtitle.isHidden = true
        DashboardSettingsComponents.invalidateSettingsRowContent(containing: subtitle)
        row.needsLayout = true
        stack.needsLayout = true
        window.layoutIfNeeded()
        counters = DashboardSettingsComponents.measurementCountersForTesting
        XCTAssertGreaterThan(counters.rowPreferredHeightMeasurements, 0)
        XCTAssertGreaterThan(counters.cardHeightMeasurements, 0)
    }

    func testSettingsRowsAdaptToLocalizedSubtitleHeightAcrossWindowWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        let fixtures: [(AppLanguage, String)] = [
            (.simplifiedChinese, "这是用于验证窗口缩放后副标题完整换行并同步更新卡片高度的长说明文字示例。"),
            (.traditionalChineseTaiwan, "這是用於驗證視窗縮放後副標題完整換行並同步更新卡片高度的長說明文字範例。"),
            (.traditionalChineseHongKong, "這是用於驗證視窗縮放後副標題完整換行並同步更新卡片高度的長說明文字範例。"),
            (.japanese, "これはウィンドウ幅の変更後も副題が完全に折り返され、カードの高さが更新されることを確認する説明文です。"),
            (.english, "This subtitle verifies resized-window wrapping and keeps the full settings text visible."),
            (.korean, "이 부제목은 창 너비를 바꾼 뒤에도 전체 설정 설명이 잘 줄바꿈되고 카드 높이가 갱신되는지 확인합니다."),
            (.spanish, "Este subtítulo comprueba que el texto completo de ajustes se ajuste al cambiar el ancho de la ventana."),
            (.german, "Dieser Untertitel prüft, dass der vollständige Einstellungstext bei geänderter Fensterbreite umbricht."),
            (.french, "Ce sous-titre vérifie que le texte complet des réglages s’adapte lorsque la largeur de la fenêtre change.")
        ]

        for (language, longSubtitle) in fixtures {
            AppLanguage.selected = language
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
            XCTAssertEqual(
                subtitle.lineBreakMode,
                language == .english || language == .spanish || language == .german || language == .french
                    ? .byWordWrapping
                    : .byCharWrapping,
                "(language) subtitle should use the script-appropriate wrapping mode"
            )
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

    func testLocalizedSettingsTitlesWrapLikeSubtitlesAcrossLanguages() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        let fixtures: [(AppLanguage, String)] = [
            (.english, "Animate the menu bar icon while a task runs"),
            (.korean, "작업 실행 중 메뉴 막대 아이콘 애니메이션"),
            (.spanish, "Anima el icono de la barra de menús mientras se ejecuta una tarea"),
            (.german, "Menüleistensymbol während einer Aufgabe animieren"),
            (.french, "Animer l’icône de la barre des menus pendant une tâche")
        ]

        for (language, longTitle) in fixtures {
            AppLanguage.selected = language
            let control = NSSwitch()
            let row = DashboardSettingsComponents.makeSettingsRow(
                longTitle,
                subtitle: "Short subtitle",
                control: control
            )
            var rowsStack: NSStackView?
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Localized titles",
                rows: [row],
                onLayoutCreated: { stack, _, _ in
                    rowsStack = stack
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func titleLabel() throws -> NSTextField {
                let labels = try XCTUnwrap(
                    row.subviews.compactMap { $0 as? NSStackView }.first
                )
                return try XCTUnwrap(labels.arrangedSubviews.first as? NSTextField)
            }

            func layout(at width: CGFloat) throws -> CGFloat {
                window.setContentSize(NSSize(width: width, height: 260))
                window.layoutIfNeeded()
                _ = try XCTUnwrap(rowsStack)
                return row.frame.height
            }

            let narrowHeight = try layout(at: 300)
            let title = try titleLabel()
            XCTAssertFalse(title.usesSingleLineMode, "title must be multiline for \(language)")
            XCTAssertEqual(
                title.lineBreakMode,
                DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: longTitle),
                "title wrapping mode for \(language)"
            )
            XCTAssertEqual(
                title.maximumNumberOfLines,
                DashboardSettingsComponents.settingsTitleMaximumNumberOfLines,
                "title line budget for \(language)"
            )
            XCTAssertTrue(title.cell?.wraps == true, "title cell wrapping for \(language)")
            XCTAssertFalse(title.cell?.isScrollable == true, "title cell must not scroll for \(language)")
            XCTAssertGreaterThan(narrowHeight, 62, "long title should grow its row for \(language)")
            XCTAssertLessThanOrEqual(
                title.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: title.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                title.bounds.height + 0.5,
                "title must fit its wrapped frame for \(language)"
            )
            let labels = try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
            let labelsFrame = labels.convert(labels.bounds, to: row)
            let controlFrame = control.convert(control.bounds, to: row)
            XCTAssertFalse(labelsFrame.intersects(controlFrame), "text and control must not overlap for \(language)")
            if controlFrame.maxY > labelsFrame.minY + 0.5 {
                XCTAssertEqual(control.frame.midY, row.bounds.midY, accuracy: 0.5)
            }

            let wideHeight = try layout(at: 740)
            XCTAssertLessThan(wideHeight, narrowHeight, "title row should shrink after widening for \(language)")
            let narrowAgainHeight = try layout(at: 300)
            XCTAssertEqual(narrowAgainHeight, narrowHeight, accuracy: 0.5)
        }
    }

    func testSettingsRowsKeepControlsAtFourNaturalTextLinesAndMoveAfterWithoutTruncatingLabels() throws {
        let shortButton = NSButton(title: "Action", target: nil, action: nil)
        let thresholdButton = NSButton(title: "Action", target: nil, action: nil)
        let overflowButton = NSButton(title: "Action", target: nil, action: nil)
        let shortRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line",
            control: shortButton
        )
        let thresholdRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line\nthird line",
            control: thresholdButton
        )
        let overflowRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line\nthird line\nfourth line",
            control: overflowButton
        )
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Line reflow",
            rows: [shortRow, thresholdRow, overflowRow]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()

        func labels(in row: NSView) throws -> NSStackView {
            try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
        }

        func assertUncappedText(in row: NSView) throws {
            let labels = try labels(in: row)
            let title = try XCTUnwrap(labels.arrangedSubviews.first as? NSTextField)
            let subtitle = try XCTUnwrap(labels.arrangedSubviews.dropFirst().first as? NSTextField)
            XCTAssertEqual(title.maximumNumberOfLines, 0)
            XCTAssertEqual(subtitle.maximumNumberOfLines, 0)
            XCTAssertLessThanOrEqual(
                title.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: title.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                title.bounds.height + 0.5
            )
            XCTAssertLessThanOrEqual(
                subtitle.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: subtitle.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                subtitle.bounds.height + 0.5
            )
        }

        let shortLabels = try labels(in: shortRow)
        let thresholdLabels = try labels(in: thresholdRow)
        let overflowLabels = try labels(in: overflowRow)
        let shortLabelsFrame = shortLabels.convert(shortLabels.bounds, to: shortRow)
        let thresholdLabelsFrame = thresholdLabels.convert(thresholdLabels.bounds, to: thresholdRow)
        let overflowLabelsFrame = overflowLabels.convert(overflowLabels.bounds, to: overflowRow)
        let shortButtonFrame = shortButton.convert(shortButton.bounds, to: shortRow)
        let thresholdButtonFrame = thresholdButton.convert(thresholdButton.bounds, to: thresholdRow)
        let overflowButtonFrame = overflowButton.convert(overflowButton.bounds, to: overflowRow)

        XCTAssertGreaterThanOrEqual(shortButtonFrame.minX, shortLabelsFrame.maxX + 19.5)
        XCTAssertEqual(shortButton.frame.midY, shortRow.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(thresholdButtonFrame.minX, thresholdLabelsFrame.maxX + 19.5)
        XCTAssertEqual(thresholdButton.frame.midY, thresholdRow.bounds.midY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(overflowButtonFrame.maxY, overflowLabelsFrame.minY + 0.5)
        XCTAssertGreaterThan(overflowRow.frame.height, thresholdRow.frame.height)
        try assertUncappedText(in: shortRow)
        try assertUncappedText(in: thresholdRow)
        try assertUncappedText(in: overflowRow)
    }

    func testSettingsRowsProtectTextBeforeOrdinaryControlsAcrossLanguages() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        XCTAssertEqual(DashboardSettingsComponents.settingsTextLineReflowThreshold, 4)
        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .english,
            .korean,
            .spanish,
            .german,
            .french
        ]

        for language in languages {
            AppLanguage.selected = language
            let title = [
                tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunning, language: language),
                tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks, language: language)
            ].joined(separator: " · ")
            let subtitle = [
                tr(.keyDashboardGeneralAndRefreshPagesRequestsTheCurrentProviderSBalanceWhileAnAgentIsRunning, language: language),
                tr(.keyDashboardGeneralAndRefreshPagesUpdateChannelDescription, language: language)
            ].joined(separator: " · ")

            for controlIndex in 0..<3 {
                let relay = DashboardPreferencePageRelay()
                let control: NSView
                switch controlIndex {
                case 0:
                    control = DashboardSettingsComponents.makeSwitch(
                        identifier: "lineBudgetSwitch",
                        isOn: true,
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.toggle(_:))
                    )
                case 1:
                    control = DashboardSettingsComponents.makePopUpButton(
                        identifier: "lineBudgetPopup",
                        items: [
                            DashboardSettingsComponents.PopUpItem(
                                title: [
                                    tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language),
                                    tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language)
                                ].joined(separator: " · "),
                                representedObject: "selected"
                            )
                        ],
                        selectedIndex: 0,
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.interval(_:))
                    )
                default:
                    let button = NSButton(
                        title: [
                            tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language),
                            tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language)
                        ].joined(separator: " · "),
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
                    )
                    button.bezelStyle = .rounded
                    control = button
                }

                let row = DashboardSettingsComponents.makeSettingsRow(
                    title,
                    subtitle: subtitle,
                    control: control
                )
                let section = DashboardSettingsComponents.makeSettingsSection(
                    "Line budget",
                    rows: [row]
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = section
                defer { window.orderOut(nil) }
                window.layoutIfNeeded()

                let labels = try XCTUnwrap(
                    row.subviews.first { $0 !== control } as? NSStackView,
                    "expected text stack for \(language), control \(controlIndex)"
                )
                let titleView = try XCTUnwrap(labels.arrangedSubviews.first)
                let titleLabel = try XCTUnwrap(
                    titleView as? NSTextField ??
                        (titleView as? NSStackView)?.arrangedSubviews.first as? NSTextField
                )
                let subtitleLabel = try XCTUnwrap(labels.arrangedSubviews.dropFirst().first as? NSTextField)
                let labelsFrame = labels.convert(labels.bounds, to: row)
                let controlFrame = control.convert(control.bounds, to: row)

                XCTAssertEqual(
                    titleLabel.maximumNumberOfLines,
                    DashboardSettingsComponents.settingsTitleMaximumNumberOfLines,
                    "title budget for \(language), control \(controlIndex)"
                )
                XCTAssertEqual(
                    subtitleLabel.maximumNumberOfLines,
                    DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines,
                    "subtitle budget for \(language), control \(controlIndex)"
                )
                XCTAssertLessThanOrEqual(
                    titleLabel.cell!.cellSize(
                        forBounds: NSRect(
                            x: 0,
                            y: 0,
                            width: titleLabel.bounds.width,
                            height: .greatestFiniteMagnitude
                        )
                    ).height,
                    titleLabel.bounds.height + 0.5,
                    "title must fit its measured frame for \(language), control \(controlIndex)"
                )
                XCTAssertLessThanOrEqual(
                    subtitleLabel.cell!.cellSize(
                        forBounds: NSRect(
                            x: 0,
                            y: 0,
                            width: subtitleLabel.bounds.width,
                            height: .greatestFiniteMagnitude
                        )
                    ).height,
                    subtitleLabel.bounds.height + 0.5,
                    "subtitle must fit its measured frame for \(language), control \(controlIndex)"
                )
                XCTAssertFalse(
                    labelsFrame.intersects(controlFrame),
                    "text and control must not overlap for \(language), control \(controlIndex)"
                )
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame),
                    "text must stay inside the row for \(language), control \(controlIndex)"
                )
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(controlFrame),
                    "control must stay inside the row for \(language), control \(controlIndex)"
                )
                XCTAssertLessThanOrEqual(
                    controlFrame.maxY,
                    labelsFrame.minY + 0.5,
                    "long control must use a dedicated row for \(language), control \(controlIndex)"
                )
            }
        }
    }

    func testCallerProvidedSubtitleLabelsStayMultilineForFutureRows() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english
        let longSubtitle = "This future settings entry has a deliberately long summary so a caller-created labelWithString label must wrap beside its control instead of truncating."
        let subtitle = NSTextField(labelWithString: longSubtitle)
        let row = DashboardSettingsComponents.makeSettingsRow(
            "Future entry",
            subtitle: longSubtitle,
            subtitleLabel: subtitle,
            control: NSSwitch()
        )
        var rowsStack: NSStackView?
        var separators: [NSView] = []
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Future settings",
            rows: [row],
            onLayoutCreated: { stack, _, createdSeparators in
                rowsStack = stack
                separators = createdSeparators
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 516, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 260))
            window.layoutIfNeeded()
            let stack = try XCTUnwrap(rowsStack)
            let card = try XCTUnwrap(stack.superview)
            return (row.frame.height, card.frame.height)
        }

        let narrow = try layout(at: 516)
        XCTAssertFalse(subtitle.usesSingleLineMode)
        XCTAssertEqual(subtitle.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(
            subtitle.maximumNumberOfLines,
            DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines
        )
        XCTAssertTrue(subtitle.cell?.wraps == true)
        XCTAssertGreaterThan(narrow.rowHeight, 62)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: row)
        XCTAssertLessThanOrEqual(
            subtitle.cell!.cellSize(
                forBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: subtitle.bounds.width,
                    height: .greatestFiniteMagnitude
                )
            ).height,
            subtitleFrame.height + 0.5
        )
        XCTAssertEqual(
            narrow.cardHeight,
            DashboardSettingsComponents.settingsCardHeight(
                rowsStack: try XCTUnwrap(rowsStack),
                separators: separators
            ),
            accuracy: 0.5
        )

        let wide = try layout(at: 740)
        XCTAssertLessThan(wide.rowHeight, narrow.rowHeight)
        XCTAssertLessThan(wide.cardHeight, narrow.cardHeight)

        subtitle.stringValue = "Short summary"
        subtitle.invalidateIntrinsicContentSize()
        row.needsLayout = true
        section.needsLayout = true
        let short = try layout(at: 516)
        XCTAssertEqual(short.rowHeight, 62, accuracy: 0.5)
        XCTAssertEqual(short.cardHeight, 62, accuracy: 0.5)
    }

    func testSemanticSubtitleGroupsUseScriptWrappingAndStayAtomicAcrossResizes() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "这是一段很长的本地化前缀，会在语义后缀之前换行：", "宽度 - 10.0 pt"),
            (.traditionalChineseTaiwan, "這是一段很長的本地化前綴，會在語義後綴之前換行：", "寬度 - 10.0 pt"),
            (.traditionalChineseHongKong, "這是一段很長的本地化前綴，會在語義後綴之前換行：", "寬度 - 10.0 pt"),
            (.japanese, "これは意味のある接尾辞の前で折り返す長いローカライズ済み接頭辞です：", "幅 - 10.0 pt"),
            (.english, "This localized prefix deliberately wraps before the semantic suffix: ", "Width - 10.0 pt"),
            (.french, "Ce préfixe localisé volontairement long se replie avant le suffixe sémantique : ", "Largeur - 10.0 pt")
        ]

        func normalized(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{2060}", with: "")
                .replacingOccurrences(of: "\n", with: "")
        }

        func renderedLines(for field: NSTextField) -> [String] {
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

        for (language, prefix, suffix) in cases {
            AppLanguage.selected = language
            let fullText = prefix + suffix
            let fullNSString = fullText as NSString
            let suffixRange = fullNSString.range(of: suffix)
            let atomicRange = NSRange(
                location: suffixRange.location + (suffix as NSString).range(of: " - 10.0 pt").location,
                length: (" - 10.0 pt" as NSString).length
            )
            let content = LocalizedSubtitle(
                text: fullText,
                semanticGroups: [suffixRange],
                atomicGroups: [atomicRange],
                lineBreakBeforeSemanticGroups: [suffixRange]
            )
            XCTAssertEqual(
                DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: content),
                .byWordWrapping,
                "script wrapping for \(language)"
            )

            let groupWidth = suffix.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let displayText = DashboardSettingsComponents.subtitleDisplayText(
                content,
                constrainedTo: groupWidth + 0.1,
                font: .systemFont(ofSize: 12)
            )
            XCTAssertTrue(
                displayText.contains("\u{00A0}"),
                "a fitting semantic group should use non-breaking layout spacing for \(language)"
            )
            XCTAssertTrue(
                displayText.contains("\n"),
                "the explicit semantic line break must remain independent of available width for \(language)"
            )
            XCTAssertTrue(
                displayText.split(separator: "\n").contains { normalized(String($0)) == normalized(suffix) },
                "the complete semantic suffix must be the second line for \(language)"
            )

            let label = DashboardSettingsComponents.makeSubtitleLabel(content)
            let control = NSSwitch()
            let row = DashboardSettingsComponents.makeSettingsRow(
                "Semantic subtitle",
                subtitleContent: content,
                subtitleLabel: label,
                control: control
            )
            var rowsStack: NSStackView?
            var separators: [NSView] = []
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Semantic fixture",
                rows: [row],
                onLayoutCreated: { stack, _, createdSeparators in
                    rowsStack = stack
                    separators = createdSeparators
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 260),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
                window.setContentSize(NSSize(width: width, height: 260))
                window.layoutIfNeeded()
                let stack = try XCTUnwrap(rowsStack)
                let card = try XCTUnwrap(stack.superview)
                return (row.frame.height, card.frame.height)
            }

            let narrow = try layout(at: 280)
            let normalizedSuffix = normalized(suffix)
            XCTAssertEqual(label.font?.pointSize ?? 0, 12, accuracy: 0.01, "subtitle font for \(language)")
            XCTAssertTrue(label.textColor?.isEqual(NSColor.secondaryLabelColor) == true, "subtitle color for \(language)")
            XCTAssertFalse(label.isBezeled, "subtitle must not add a visual container for \(language)")
            XCTAssertFalse(label.drawsBackground, "subtitle must not add a background for \(language)")
            XCTAssertFalse(label.wantsLayer, "subtitle must not add a layer wrapper for \(language)")
            XCTAssertTrue(label.superview is NSStackView, "subtitle remains a normal row label for \(language)")
            let lines = renderedLines(for: label).map { normalized($0) }
            let logicalRenderedText = normalized(label.stringValue)
            XCTAssertTrue(
                logicalRenderedText.contains(normalized(prefix.trimmingCharacters(in: .whitespacesAndNewlines))),
                "the description must remain in the first semantic block for \(language): \(lines)"
            )
            XCTAssertTrue(
                renderedLines(for: label).contains { normalized($0).contains(normalizedSuffix) },
                "semantic suffix must remain one line for \(language): \(renderedLines(for: label))"
            )
            let labels = try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
            let labelsFrame = labels.convert(labels.bounds, to: row)
            let controlFrame = control.convert(control.bounds, to: row)
            XCTAssertFalse(labelsFrame.intersects(controlFrame), "text and control must not overlap for \(language)")
            if controlFrame.maxY > labelsFrame.minY + 0.5 {
                XCTAssertEqual(
                    control.frame.midY,
                    row.bounds.midY,
                    accuracy: 0.5,
                    "slider/control stays centered for \(language)"
                )
            }
            XCTAssertEqual(
                narrow.cardHeight,
                DashboardSettingsComponents.settingsCardHeight(
                    rowsStack: try XCTUnwrap(rowsStack),
                    separators: separators
                ),
                accuracy: 0.5
            )

            let wide = try layout(at: 560)
            XCTAssertLessThan(wide.rowHeight, narrow.rowHeight, "row shrinks when widened for \(language)")
            XCTAssertLessThan(wide.cardHeight, narrow.cardHeight, "card shrinks when widened for \(language)")
            let narrowAgain = try layout(at: 280)
            XCTAssertEqual(narrowAgain.rowHeight, narrow.rowHeight, accuracy: 0.5)
            XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5)

            let updated = LocalizedSubtitle(
                text: prefix + suffix.replacingOccurrences(of: "10.0", with: "0.0"),
                semanticGroups: [NSRange(location: prefix.utf16.count, length: suffix.replacingOccurrences(of: "10.0", with: "0.0").utf16.count)],
                atomicGroups: [NSRange(location: prefix.utf16.count + (suffix.replacingOccurrences(of: "10.0", with: "0.0") as NSString).range(of: " - 0.0 pt").location, length: (" - 0.0 pt" as NSString).length)],
                lineBreakBeforeSemanticGroups: [NSRange(location: prefix.utf16.count, length: suffix.replacingOccurrences(of: "10.0", with: "0.0").utf16.count)]
            )
            DashboardSettingsComponents.updateSubtitleLabel(label, with: updated)
            row.needsLayout = true
            section.needsLayout = true
            _ = try layout(at: 280)
            XCTAssertTrue(normalized(label.stringValue).contains("0.0 pt"))
        }

        let longSuffix = "This semantic suffix is intentionally longer than one complete line before - 10.0 pt"
        let longText = "Prefix: " + longSuffix
        let longRange = (longText as NSString).range(of: longSuffix)
        let longAtomicRange = NSRange(
            location: longRange.location + (longSuffix as NSString).range(of: " - 10.0 pt").location,
            length: (" - 10.0 pt" as NSString).length
        )
        let longContent = LocalizedSubtitle(
            text: longText,
            semanticGroups: [longRange],
            atomicGroups: [longAtomicRange],
            lineBreakBeforeSemanticGroups: [longRange]
        )
        let longDisplay = DashboardSettingsComponents.subtitleDisplayText(
            longContent,
            constrainedTo: 90,
            font: .systemFont(ofSize: 12)
        )
        XCTAssertTrue(
            normalized(longDisplay).contains("- 10.0 pt"),
            "an oversized semantic group must retain its atomic numeric suffix"
        )
        XCTAssertTrue(
            longDisplay.contains("\n"),
            "an oversized suffix may wrap normally only after the complete suffix starts on line two"
        )
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

    func testLunaReserveCardShowsLocalizedStatusRemainingResetAndCollapsesWithoutProgress() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let card = LunaReserveCardView()
        card.update(
            quota: LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        )
        let fields: (String) -> NSTextField? = { identifier in
            func find(in view: NSView) -> NSTextField? {
                for child in view.subviews {
                    if child.identifier?.rawValue == identifier, let field = child as? NSTextField {
                        return field
                    }
                    if let field = find(in: child) { return field }
                }
                return nil
            }
            return find(in: card)
        }

        XCTAssertEqual(fields("lunaReserveTitle")?.stringValue, tr(.keyLunaReserveTitle))
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusAvailable))
        XCTAssertEqual(
            fields("lunaReserveRemaining")?.stringValue,
            tr(.keyLunaReserveRemainingValue, arguments: ["45"])
        )
        XCTAssertEqual(
            fields("lunaReserveReset")?.stringValue,
            tr(.keyLunaReserveResetValue, arguments: ["1h30m"])
        )

        card.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(descendantViews(of: card, as: QuotaProgressView.self).count, 1)
        let progressHost = try XCTUnwrap(
            descendantViews(of: card, as: NSView.self).first {
                $0.identifier?.rawValue == "lunaReserveProgressHost"
            }
        )
        XCTAssertFalse(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 6, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .unavailable,
                remaining: nil,
                reset: nil
            )
        )
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusUnavailable))
        XCTAssertEqual(fields("lunaReserveRemaining")?.stringValue, tr(.keyLunaReserveRemainingUnavailable))
        XCTAssertEqual(fields("lunaReserveReset")?.stringValue, tr(.keyLunaReserveResetUnavailable))
        XCTAssertTrue(descendantViews(of: card, as: QuotaProgressView.self).isEmpty)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 0, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .loading,
                remaining: nil,
                reset: nil
            )
        )
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusLoading))
        XCTAssertEqual(fields("lunaReserveRemaining")?.stringValue, tr(.keyLunaReserveRemainingUnavailable))
        XCTAssertEqual(fields("lunaReserveReset")?.stringValue, tr(.keyLunaReserveResetUnavailable))
        XCTAssertTrue(descendantViews(of: card, as: QuotaProgressView.self).isEmpty)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 0, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        )
        card.layoutSubtreeIfNeeded()
        XCTAssertFalse(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 6, accuracy: 0.5)
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
        XCTAssertTrue(link.trackingAreas[0].options.contains(.activeInKeyWindow))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.inVisibleRect))

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
    }

    func testMenuHostForwardsCoordinatesThroughVisibleGlyphHitTest() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 40, y: 30, width: 220, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 0, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(host)
        host.track(link)
        host.updateTrackingAreas()

        XCTAssertEqual(link.interactionMode, .menuHosted)
        XCTAssertEqual(link.trackingAreas.count, 0)
        XCTAssertEqual(host.trackingAreas.count, 1)
        XCTAssertTrue(host.trackingAreas[0].options.contains(.mouseMoved))
        XCTAssertFalse(host.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(host.trackingAreas[0].options.contains(.activeAlways))

        let cursorBefore = NSCursor.current

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))

        let blankPoint = host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 12, y: link.visibleTextHitRect.midY),
            from: link
        )
        host.forwardHover(atHostPoint: blankPoint)
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testMenuHostHoverRemainsStableAcrossRepeatedMovementAndBoundaryCrossings() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 2, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        host.track(link)
        host.updateTrackingAreas()

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        let blankPoint = host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 12, y: link.visibleTextHitRect.midY),
            from: link
        )
        for _ in 0..<30 {
            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: glyphPoint))
            XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: blankPoint))
            XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: glyphPoint))
            XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        }
    }

    func testMenuHostTrackingRefreshAndTeardownAreStable() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = host.bounds
        host.addSubview(link)
        link.layout()
        host.track(link)

        host.updateTrackingAreas()
        host.updateTrackingAreas()
        XCTAssertEqual(host.trackingAreas.count, 1)

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        host.removeFromSuperview()
        XCTAssertEqual(host.trackingAreas.count, 0)
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testMenuHostedLinkSurvivesFivePopupReopens() {
        let menu = NSMenu(title: "Issue 265 reopen")
        let item = NSMenuItem()
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 2, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        host.track(link)
        item.view = host
        menu.addItem(item)

        defer { menu.removeAllItems() }
        for openNumber in 1...5 {
            var attached = false
            var underlined = false
            var trackingAreaCount = 0
            var retainedLink = false
            var probeAttempts = 0
            let probe = Timer(timeInterval: 0.02, repeats: true) { timer in
                probeAttempts += 1
                guard host.window != nil else {
                    if probeAttempts >= 50 {
                        timer.invalidate()
                        menu.cancelTracking()
                    }
                    return
                }
                attached = true
                let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
                host.mouseMoved(with: self.makeMouseEvent(
                    type: .mouseMoved,
                    location: host.convert(glyphPoint, to: nil)
                ))
                underlined = link.attributedStringValue.attribute(
                    .underlineStyle,
                    at: 0,
                    effectiveRange: nil
                ) != nil
                trackingAreaCount = host.trackingAreas.count
                retainedLink = host.trackedLink === link
                timer.invalidate()
                menu.cancelTracking()
            }
            RunLoop.main.add(probe, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: .zero, in: nil)

            XCTAssertTrue(attached, "menu open \(openNumber) did not attach the host")
            XCTAssertTrue(retainedLink)
            XCTAssertEqual(trackingAreaCount, 1)
            XCTAssertTrue(underlined, "menu open \(openNumber) did not forward the visible glyph")
            link.clearHoverState()
        }

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        host.forwardHover(atHostPoint: host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 8, y: link.visibleTextHitRect.midY),
            from: link
        ))
        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: NSPoint(
            x: link.visibleTextHitRect.maxX + 8,
            y: link.visibleTextHitRect.midY
        )))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(activationCount, 0)

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))
        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkGeometryRefreshInstallsTrackingWhenAttachedToWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let link = HoverLinkTextField(text: "Provider")
        window.contentView?.addSubview(link)
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()

        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertEqual(link.trackingAreas[0].rect, link.visibleTextHitRect)
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

    private func descendantViews<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            ([child].compactMap { $0 as? T }) + descendantViews(of: child, as: type)
        }
    }

    private func firstDescendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        descendantViews(of: root, as: type).first
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
