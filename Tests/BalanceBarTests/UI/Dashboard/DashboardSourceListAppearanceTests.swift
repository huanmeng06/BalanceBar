import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardSourceListAppearanceTests: XCTestCase {
    func testSidebarIconCacheSeparatesAppearanceScaleAndPalette() throws {
        let renderer = DashboardSidebarIconRenderer()
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        func icon(_ appearance: NSAppearance, _ scale: CGFloat, modern: Bool = true) -> NSImage {
            renderer.image(for: .menuBar, appearance: appearance, scale: scale, usesDarkIcons: modern)
        }
        let one = icon(light, 1)
        let two = icon(light, 2)
        let modernDark = icon(dark, 2)
        XCTAssertIdentical(one, icon(light, 1))
        XCTAssertIdentical(two, icon(light, 2))
        XCTAssertIdentical(modernDark, icon(dark, 2))
        XCTAssertNotIdentical(one, two)
        XCTAssertNotIdentical(two, modernDark)
        XCTAssertNotIdentical(modernDark, icon(dark, 2, modern: false))
        XCTAssertEqual(one.representations.first?.pixelsWide, 24)
        XCTAssertEqual(two.representations.first?.pixelsWide, 48)
        XCTAssertEqual(two.size, NSSize(width: 24, height: 24))
        XCTAssertFalse(two.isTemplate)
        let image = try XCTUnwrap(two.representations.first as? NSBitmapImageRep)
        let darkImage = try XCTUnwrap(modernDark.representations.first as? NSBitmapImageRep)
        for (x, y) in [(8, 24), (39, 24), (24, 8), (24, 39)] {
            let edge = try XCTUnwrap(image.colorAt(x: x, y: y))
            XCTAssertGreaterThan(edge.alphaComponent, 0.95, "Tile is clipped at \(x), \(y)")
        }
        XCTAssertNotEqual(image.colorAt(x: 8, y: 24), darkImage.colorAt(x: 8, y: 24))
        XCTAssertNotEqual(image.colorAt(x: 8, y: 10), image.colorAt(x: 8, y: 36))
    }

    func testSectionRowsUseFixedAlignedIconsAcrossBackgroundStyles() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertEqual(outline.style, .sourceList)
        XCTAssertEqual(outline.rowHeight, 30)
        var iconOrigins: [CGFloat] = []
        XCTAssertEqual(sourceList.selectedSection(), .general)

        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try sectionCell(in: outline, row: row)
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertNotNil(cell.imageView?.image)
            let chip = try XCTUnwrap(cell.imageView)
            XCTAssertEqual(chip.frame.size, NSSize(width: 24, height: 24))
            iconOrigins.append(chip.convert(chip.bounds, to: outline).minX)
            try assertTitleColor(of: cell, selected: outline.isRowSelected(row), section: section)
            let node = try XCTUnwrap(sourceList.node(for: section))
            let tint = sourceList.outlineView(outline, tintConfigurationForItem: node)
            XCTAssertTrue(
                tint?.isEqual(NSTintConfiguration.default) ?? false,
                "\(section) must keep native source-list tint"
            )
            assertRowReadable(cell)

            let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
            rowView.isEmphasized = true
            window.layoutIfNeeded()
            assertRowReadable(cell)
            rowView.isEmphasized = false
            window.layoutIfNeeded()
            assertRowReadable(cell)
        }
        let firstOrigin = try XCTUnwrap(iconOrigins.first)
        for origin in iconOrigins {
            XCTAssertEqual(origin, firstOrigin, accuracy: 0.5)
        }
    }

    func testSectionAndGroupCellsDoNotDuplicateTitleInAccessibilityTree() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try sectionCell(in: outline, row: row)
            XCTAssertEqual(cell.accessibilityLabel(), section.title)
            XCTAssertEqual(cell.imageView?.isAccessibilityElement(), false)
            XCTAssertEqual(cell.textField?.isAccessibilityElement(), false)
            XCTAssertTrue(cell.updateBadgeView.isHidden)
        }

        controller.setShowsUpdateAvailableBadge(true)
        let generalRow = try XCTUnwrap(sourceList.row(for: .general))
        let generalCell = try sectionCell(in: outline, row: generalRow)
        XCTAssertFalse(generalCell.updateBadgeView.isHidden)
        XCTAssertEqual(generalCell.accessibilityLabel(), DashboardSection.general.title)
        XCTAssertEqual(generalCell.imageView?.isAccessibilityElement(), false)
        XCTAssertEqual(generalCell.textField?.isAccessibilityElement(), false)
        XCTAssertNotEqual(generalCell.updateBadgeView.accessibilityLabel(), DashboardSection.general.title)

        for group in sourceList.roots.filter(\.isGroup) {
            let groupRow = outline.row(forItem: group)
            let spacer = try XCTUnwrap(outline.rowView(atRow: groupRow, makeIfNecessary: true))
            XCTAssertFalse(spacer.isAccessibilityElement())
            XCTAssertNil(outline.view(atColumn: 0, row: groupRow, makeIfNecessary: true))
            let gap = outline.rect(ofRow: groupRow + 1).minY - outline.rect(ofRow: groupRow - 1).maxY
            XCTAssertGreaterThanOrEqual(gap, 8)
            XCTAssertLessThanOrEqual(gap, 10)
        }
    }

    func testRebuildLanguageSwitchAndBadgeKeepAppKitAppearanceOwnership() throws {
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
        try assertOwnershipPreserved(in: first, showsGeneralBadge: true)

        controller.showSection(.menuBar)
        AppLanguage.selected = .english
        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let englishList = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertTrue(englishList.outlineView !== first.outlineView)
        XCTAssertEqual(englishList.selectedSection(), .menuBar)
        try assertOwnershipPreserved(in: englishList, showsGeneralBadge: true)
        try assertSectionTitlesMatchCurrentLanguage(in: englishList)

        AppLanguage.selected = .simplifiedChinese
        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let chineseList = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertEqual(chineseList.selectedSection(), .menuBar)
        try assertOwnershipPreserved(in: chineseList, showsGeneralBadge: true)
        try assertSectionTitlesMatchCurrentLanguage(in: chineseList)

        controller.setShowsUpdateAvailableBadge(false)
        let generalRow = try XCTUnwrap(chineseList.row(for: .general))
        let generalCell = try sectionCell(in: chineseList.outlineView, row: generalRow)
        XCTAssertTrue(generalCell.updateBadgeView.isHidden)
        try assertOwnershipPreserved(in: chineseList, showsGeneralBadge: false)
    }

    private func makeController() -> DashboardShellTestHarness {
        DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
    }

    private func sectionCell(in outline: NSOutlineView, row: Int) throws -> DashboardSourceListCellView {
        try XCTUnwrap(
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? DashboardSourceListCellView
        )
    }

    private func assertTitleColor(
        of cell: DashboardSourceListCellView,
        selected: Bool,
        section: DashboardSection
    ) throws {
        XCTAssertNotNil(cell.textField?.textColor, "\(section) title must remain readable")
        if selected {
            return
        }
        XCTAssertTrue(
            cell.textField?.textColor?.isEqual(NSColor.controlTextColor) ?? false,
            "\(section) unselected title must use controlTextColor"
        )
    }

    private func assertRowReadable(_ cell: DashboardSourceListCellView) {
        for style: NSView.BackgroundStyle in [.normal, .emphasized] {
            cell.backgroundStyle = style
            cell.layoutSubtreeIfNeeded()
            XCTAssertFalse(cell.textField?.stringValue.isEmpty ?? true)
            XCTAssertNotNil(cell.textField?.textColor)
            XCTAssertNotNil(cell.imageView?.image)
        }
    }

    private func assertOwnershipPreserved(
        in sourceList: DashboardSourceListController,
        showsGeneralBadge: Bool
    ) throws {
        XCTAssertEqual(sourceList.outlineView.style, .sourceList)
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try sectionCell(in: sourceList.outlineView, row: row)
            XCTAssertFalse(
                cell.imageView?.contentTintColor?.isEqual(NSColor.labelColor) ?? false,
                "\(section) icon must not lock contentTintColor to labelColor after rebuild"
            )
            try assertTitleColor(
                of: cell,
                selected: sourceList.outlineView.isRowSelected(row),
                section: section
            )
            let node = try XCTUnwrap(sourceList.node(for: section))
            let tint = sourceList.outlineView(sourceList.outlineView, tintConfigurationForItem: node)
            XCTAssertTrue(tint?.isEqual(NSTintConfiguration.default) ?? false)
            XCTAssertEqual(cell.imageView?.isAccessibilityElement(), false)
            XCTAssertEqual(cell.textField?.isAccessibilityElement(), false)
            if section == .general {
                XCTAssertEqual(cell.updateBadgeView.isHidden, !showsGeneralBadge)
                if showsGeneralBadge {
                    cell.layoutSubtreeIfNeeded()
                    let titleLabel = try XCTUnwrap(cell.textField)
                    XCTAssertGreaterThan(cell.updateBadgeView.frame.minX, titleLabel.frame.maxX)
                    XCTAssertLessThanOrEqual(cell.updateBadgeView.frame.maxX, cell.bounds.maxX)
                }
            }
        }
    }

    private func assertSectionTitlesMatchCurrentLanguage(
        in sourceList: DashboardSourceListController
    ) throws {
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try sectionCell(in: sourceList.outlineView, row: row)
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertEqual(cell.accessibilityLabel(), section.title)
        }
    }
}
