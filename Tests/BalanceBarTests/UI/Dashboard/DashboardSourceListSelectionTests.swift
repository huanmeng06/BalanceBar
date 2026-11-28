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
        XCTAssertTrue(source.contains("tintConfigurationForItem"))
        XCTAssertTrue(source.contains("NSTintConfiguration.default"))
        XCTAssertFalse(source.contains("NSTintConfiguration.monochrome"))
        XCTAssertTrue(source.contains("controlTextColor"))
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

    func testSectionRowsKeepAppKitEmphasisAndUpdateTitleColor() throws {
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

            let cell = try sectionCell(in: outline, row: row)
            rowView.isEmphasized = true
            XCTAssertTrue(rowView.isEmphasized)
            XCTAssertEqual(cell.textField?.textColor, .white)
            rowView.isEmphasized = false
            XCTAssertEqual(cell.textField?.textColor, .unemphasizedSelectedTextColor)
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertEqual(cell.accessibilityLabel(), section.title)
            XCTAssertFalse(cell.textField?.stringValue.isEmpty ?? true)
            XCTAssertNotNil(cell.textField?.textColor)
            XCTAssertNotNil(cell.imageView?.image)
            let node = try XCTUnwrap(sourceList.node(for: section))
            XCTAssertTrue(
                sourceList.outlineView(outline, tintConfigurationForItem: node)?
                    .isEqual(NSTintConfiguration.default) ?? false
            )
        }

        sourceList.applySelection(.menuBar)
        window.layoutIfNeeded()
        let unselectedGeneralRow = try XCTUnwrap(sourceList.row(for: .general))
        let unselectedGeneral = try sectionCell(in: outline, row: unselectedGeneralRow)
        XCTAssertTrue(
            unselectedGeneral.textField?.textColor?.isEqual(NSColor.controlTextColor) ?? false
        )
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
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: appearance))
        XCTAssertNil(sourceList.outlineView(outline, tintConfigurationForItem: appearance))
        XCTAssertNil(sourceList.outlineView(outline, tintConfigurationForItem: system))

        for group in [appearance, system] {
            let row = outline.row(forItem: group)
            XCTAssertGreaterThanOrEqual(row, 0)
            let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
            XCTAssertFalse(rowView is DashboardSourceListRowView)
            XCTAssertFalse(rowView.isAccessibilityElement())
            XCTAssertFalse(outline.isRowSelected(row))
        }
    }

    func testProviderPageClearsSelection() throws {
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
            XCTAssertEqual(rowView.identifier, DashboardSourceListRowView.identifier)
        }
    }

    func testKeyboardAndGroupClicksKeepNativeSelection() throws {
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
        try assertSelectedSectionUsesNativeRowView(.menuBar, in: sourceList)

        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let appearanceRow = outline.row(forItem: appearance)
        clickTrailingBlank(of: appearanceRow, in: outline)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        XCTAssertFalse(outline.isRowSelected(appearanceRow))
        XCTAssertEqual(pageShows, afterGeneral + 1)
        try assertSelectedSectionUsesNativeRowView(.menuBar, in: sourceList)
    }

    func testRebuildLanguageSwitchAndBadgeKeepNativeRowView() throws {
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
        try assertEverySectionUsesNativeRowView(in: first)
        try assertGeneralBadge(in: first, visible: true)

        controller.showSection(.menuBar)
        AppLanguage.selected = .english
        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let rebuilt = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertTrue(rebuilt.outlineView !== first.outlineView)
        XCTAssertEqual(rebuilt.selectedSection(), .menuBar)
        try assertEverySectionUsesNativeRowView(in: rebuilt)
        try assertGeneralBadge(in: rebuilt, visible: true)

        controller.setShowsUpdateAvailableBadge(false)
        try assertEverySectionUsesNativeRowView(in: rebuilt)
        try assertGeneralBadge(in: rebuilt, visible: false)
    }

    func testMouseSelectionDrawsBeforeNavigationAndKeepsSidebarFocus() async throws {
        var builds: [DashboardSection] = []
        let controller = DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { section in
                    builds.append(section)
                    return DashboardHostedPageViewController()
                },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        let list = try XCTUnwrap(controller.sourceListForTesting)
        let outline = list.outlineView
        XCTAssertTrue(window.makeFirstResponder(controller.pageSession.toolbarController.searchField))
        var completedPhases: [DashboardPageInstrumentation.Phase] = []
        DashboardPageInstrumentation.eventRecorder = { phase, boundary in
            if boundary == .end { completedPhases.append(phase) }
        }
        defer { DashboardPageInstrumentation.eventRecorder = nil }

        try mouseDown(on: .menuBar, in: list)
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertEqual(list.selectedSection(), .menuBar)
        XCTAssertEqual(controller.section, .general)
        XCTAssertEqual(builds, [.general])
        XCTAssertTrue(completedPhases.contains(.sidebarSelectionDisplay))
        XCTAssertFalse(completedPhases.contains(.totalSelectionToReady))

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertEqual(builds, [.general, .menuBar])
        XCTAssertTrue(completedPhases.contains(.totalSelectionToReady))

        try mouseDown(on: .advanced, in: list)
        try mouseDown(on: .general, in: list)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(controller.section, .general)
        XCTAssertEqual(builds, [.general, .menuBar])

        try mouseDown(on: .advanced, in: list)
        controller.showSection(.menuBar)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertEqual(list.selectedSection(), .menuBar)
        XCTAssertEqual(builds, [.general, .menuBar])
    }

    private func mouseDown(on section: DashboardSection, in list: DashboardSourceListController) throws {
        let outline = list.outlineView
        let row = try XCTUnwrap(list.row(for: section))
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: outline.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        outline.mouseDown(with: event)
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

    private func assertSelectedSectionUsesNativeRowView(
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
        XCTAssertTrue(rowView.isSelected)
    }

    private func assertEverySectionUsesNativeRowView(
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
            XCTAssertEqual(rowView.identifier, DashboardSourceListRowView.identifier)
        }
    }

    private func assertGeneralBadge(
        in sourceList: DashboardSourceListController,
        visible: Bool
    ) throws {
        let row = try XCTUnwrap(sourceList.row(for: .general))
        let cell = try sectionCell(in: sourceList.outlineView, row: row)
        XCTAssertEqual(cell.updateBadgeView.isHidden, !visible)
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
