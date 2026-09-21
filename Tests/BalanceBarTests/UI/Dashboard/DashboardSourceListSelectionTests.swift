import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardSourceListSelectionTests: XCTestCase {
    func testSourceListKeepsNativeSelectionOwnershipWithoutCustomDrawing() throws {
        let source = try sourceListSource()
        XCTAssertTrue(source.contains("style = .sourceList"))
        XCTAssertTrue(source.contains("rowViewForItem"))
        XCTAssertTrue(source.contains("final class DashboardSourceListRowView: NSTableRowView"))
        XCTAssertTrue(source.contains("override var isEmphasized"))
        XCTAssertFalse(source.contains("drawSelection"))
        XCTAssertFalse(source.contains("selectionHighlightStyle = .none"))
        XCTAssertFalse(source.contains("unemphasizedSelectedContentBackgroundColor"))

        let forbidden = [
            "NSColor(red:",
            "calibratedRed",
            "srgbRed",
            "#colorLiteral",
            "NSScrollPocket",
            "value(forKey:",
            "NSClassFromString"
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "source-list file must not contain \(token)")
        }
    }

    func testSectionRowsUseUnemphasizedRowViewAndKeepAppKitSelection() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertEqual(outline.style, .sourceList)
        XCTAssertNotEqual(outline.selectionHighlightStyle, .none)
        XCTAssertEqual(sourceList.selectedSection(), .general)

        for section in DashboardSection.allCases {
            sourceList.applySelection(section)
            window.layoutIfNeeded()
            window.displayIfNeeded()

            let row = try XCTUnwrap(sourceList.row(for: section))
            let rowView = try XCTUnwrap(
                outline.rowView(atRow: row, makeIfNecessary: true) as? DashboardSourceListRowView
            )
            XCTAssertTrue(outline.isRowSelected(row))
            XCTAssertTrue(rowView.isSelected)
            XCTAssertEqual(rowView.identifier, DashboardSourceListRowView.identifier)

            rowView.isEmphasized = true
            window.layoutIfNeeded()
            XCTAssertFalse(rowView.isEmphasized)

            let cell = try sectionCell(in: outline, row: row)
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertEqual(cell.accessibilityLabel(), section.title)
            XCTAssertFalse(cell.textField?.stringValue.isEmpty ?? true)
            XCTAssertNotNil(cell.textField?.textColor)
            XCTAssertTrue(cell.textField?.allowsVibrancy == true)
            XCTAssertTrue(cell.textField?.textColor?.isEqual(NSColor.labelColor) ?? false)
            XCTAssertNotNil(cell.imageView?.image)
        }
    }

    func testGroupRowsDoNotUseSectionSelectionRowView() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let system = try XCTUnwrap(sourceList.roots.first { $0.group == .system })
        XCTAssertTrue(sourceList.outlineView(outline, isGroupItem: appearance))
        XCTAssertTrue(sourceList.outlineView(outline, isGroupItem: system))
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: appearance))
        XCTAssertNil(sourceList.outlineView(outline, rowViewForItem: appearance))
        XCTAssertNil(sourceList.outlineView(outline, rowViewForItem: system))

        for group in [appearance, system] {
            let row = outline.row(forItem: group)
            XCTAssertGreaterThanOrEqual(row, 0)
            let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
            XCTAssertFalse(rowView is DashboardSourceListRowView)
            XCTAssertFalse(outline.isRowSelected(row))
        }
    }

    func testProviderPageClearsSelectionWithoutLeavingEmphasizedRows() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = makeController(providerChoices: choices)
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        controller.showProvider("other")
        window.layoutIfNeeded()
        XCTAssertNil(sourceList.selectedSection())
        XCTAssertEqual(sourceList.outlineView.selectedRow, -1)
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let rowView = try XCTUnwrap(
                sourceList.outlineView.rowView(atRow: row, makeIfNecessary: true) as? DashboardSourceListRowView
            )
            XCTAssertFalse(sourceList.outlineView.isRowSelected(row))
            XCTAssertFalse(rowView.isSelected)
            rowView.isEmphasized = true
            XCTAssertFalse(rowView.isEmphasized)
        }
    }

    func testKeyboardAndGroupClicksKeepUnemphasizedRowViewStrategy() throws {
        var pageShows = 0
        let controller = makeController(didShowPage: { pageShows += 1 })
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertTrue(window.makeFirstResponder(outline))
        sourceList.applySelection(.general)
        let afterGeneral = pageShows

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        try assertSelectedSectionUsesPinnedRowView(.menuBar, in: sourceList)

        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let appearanceRow = outline.row(forItem: appearance)
        clickTrailingBlank(of: appearanceRow, in: outline)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        XCTAssertFalse(outline.isRowSelected(appearanceRow))
        XCTAssertEqual(pageShows, afterGeneral + 1)
        try assertSelectedSectionUsesPinnedRowView(.menuBar, in: sourceList)
    }

    func testRebuildLanguageSwitchAndBadgeKeepUnemphasizedRowView() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let controller = makeController()
        defer { controller.teardown() }
        controller.setShowsUpdateAvailableBadge(true)
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let first = try XCTUnwrap(controller.sourceListForTesting)
        try assertEverySectionUsesPinnedRowView(in: first)
        try assertGeneralBadge(in: first, visible: true)

        controller.showSection(.menuBar)
        AppLanguage.selected = .english
        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let rebuilt = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertTrue(rebuilt.outlineView !== first.outlineView)
        XCTAssertEqual(rebuilt.selectedSection(), .menuBar)
        try assertEverySectionUsesPinnedRowView(in: rebuilt)
        try assertGeneralBadge(in: rebuilt, visible: true)

        controller.setShowsUpdateAvailableBadge(false)
        try assertEverySectionUsesPinnedRowView(in: rebuilt)
        try assertGeneralBadge(in: rebuilt, visible: false)
    }

    private func makeController(
        providerChoices: [ProviderChoice] = [],
        didShowPage: @escaping () -> Void = {}
    ) -> DashboardShellTestHarness {
        DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { providerChoices },
                prepareForPageReplacement: {},
                didShowPage: didShowPage,
                didClose: {},
                didResize: {}
            )
        )
    }

    private func sourceListSource() throws -> String {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardSourceListController.swift"
            ),
            encoding: .utf8
        )
    }

    private func sectionCell(in outline: NSOutlineView, row: Int) throws -> DashboardSourceListCellView {
        try XCTUnwrap(
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? DashboardSourceListCellView
        )
    }

    private func assertSelectedSectionUsesPinnedRowView(
        _ section: DashboardSection,
        in sourceList: DashboardSourceListController
    ) throws {
        let outline = sourceList.outlineView
        let row = try XCTUnwrap(sourceList.row(for: section))
        let rowView = try XCTUnwrap(
            outline.rowView(atRow: row, makeIfNecessary: true) as? DashboardSourceListRowView
        )
        XCTAssertEqual(sourceList.selectedSection(), section)
        XCTAssertTrue(outline.isRowSelected(row))
        rowView.isEmphasized = true
        XCTAssertFalse(rowView.isEmphasized)
    }

    private func assertEverySectionUsesPinnedRowView(
        in sourceList: DashboardSourceListController
    ) throws {
        XCTAssertEqual(sourceList.outlineView.style, .sourceList)
        XCTAssertNotEqual(sourceList.outlineView.selectionHighlightStyle, .none)
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let rowView = try XCTUnwrap(
                sourceList.outlineView.rowView(atRow: row, makeIfNecessary: true)
                    as? DashboardSourceListRowView
            )
            rowView.isEmphasized = true
            XCTAssertFalse(rowView.isEmphasized)
        }
    }

    private func assertGeneralBadge(
        in sourceList: DashboardSourceListController,
        visible: Bool
    ) throws {
        let row = try XCTUnwrap(sourceList.row(for: .general))
        let cell = try sectionCell(in: sourceList.outlineView, row: row)
        XCTAssertEqual(cell.updateBadgeView.isHidden, !visible)
        let rowView = try XCTUnwrap(
            sourceList.outlineView.rowView(atRow: row, makeIfNecessary: true)
                as? DashboardSourceListRowView
        )
        XCTAssertFalse(rowView.isEmphasized)
    }

    private func clickTrailingBlank(of row: Int, in outline: NSOutlineView) {
        let rowRect = outline.rect(ofRow: row)
        let local = NSPoint(x: max(rowRect.maxX - 8, rowRect.midX), y: rowRect.midY)
        let locationInWindow = outline.convert(local, to: nil)
        let windowNumber = outline.window?.windowNumber ?? 0
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        if let down {
            outline.mouseDown(with: down)
        }
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )
        if let up {
            outline.mouseUp(with: up)
        }
    }
}
