import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardSourceListAppearanceTests: XCTestCase {
    func testSourceListRowAppearanceLeavesTypographyAndTintToAppKit() throws {
        let source = try sourceListSource()
        let sectionSource = try typeSource(named: "DashboardSourceListCellView", in: source)
        let groupSource = try typeSource(named: "DashboardSourceListGroupCellView", in: source)

        XCTAssertTrue(source.contains("style = .sourceList"))
        XCTAssertTrue(source.contains("rowSizeStyle = .default"))
        XCTAssertFalse(sectionSource.contains("systemFont(ofSize: 13, weight: .medium)"))
        XCTAssertFalse(sectionSource.contains("contentTintColor"))
        XCTAssertFalse(sectionSource.contains("symbolConfiguration"))
        XCTAssertTrue(sectionSource.contains("allowsVibrancy"))
        XCTAssertFalse(sectionSource.contains("secondaryLabelColor"))
        XCTAssertFalse(sectionSource.contains("unemphasizedSelectedTextColor"))
        XCTAssertFalse(groupSource.contains("weight: .medium"))
        XCTAssertFalse(groupSource.contains("systemFont(ofSize: 11, weight: .medium)"))
        XCTAssertTrue(groupSource.contains("smallSystemFontSize"))
        XCTAssertTrue(groupSource.contains("tertiaryLabelColor"))

        let forbidden = [
            "drawSelection",
            "NSColor(red:",
            "calibratedRed",
            "srgbRed",
            "#colorLiteral",
            "NSScrollPocket",
            "value(forKey:",
            "NSClassFromString",
            "if #available(macOS 27",
            "tintConfigurationWithFixedColor",
            "tintConfigurationWithPreferredColor",
            "controlAccentColor",
            "chipColor",
            "unemphasizedSelectedContentBackgroundColor",
            "NSTintConfiguration.monochrome"
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "source-list file must not contain \(token)")
        }
        if source.contains("tintConfigurationForItem") {
            XCTAssertTrue(source.contains("NSTintConfiguration.default"))
        }
    }

    func testSectionRowsKeepAppKitTintAndRemainReadableAcrossBackgroundStyles() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertEqual(outline.style, .sourceList)
        XCTAssertEqual(outline.rowSizeStyle, .default)
        XCTAssertEqual(sourceList.selectedSection(), .general)

        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try sectionCell(in: outline, row: row)
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertNotNil(cell.imageView?.image)
            XCTAssertFalse(
                cell.imageView?.contentTintColor?.isEqual(NSColor.labelColor) ?? false,
                "\(section) icon must not lock contentTintColor to labelColor"
            )
            XCTAssertTrue(
                cell.textField?.allowsVibrancy == true,
                "\(section) title must allow sidebar vibrancy for inactive foreground"
            )
            XCTAssertTrue(
                cell.textField?.textColor?.isEqual(NSColor.labelColor) ?? false,
                "\(section) title must keep semantic labelColor instead of a locked gray"
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

        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let groupRow = outline.row(forItem: appearance)
        let groupCell = try XCTUnwrap(
            outline.view(atColumn: 0, row: groupRow, makeIfNecessary: true)
                as? DashboardSourceListGroupCellView
        )
        XCTAssertEqual(groupCell.accessibilityLabel(), appearance.title)
        XCTAssertEqual(groupCell.textField?.isAccessibilityElement(), false)
        XCTAssertEqual(groupCell.textField?.textColor, NSColor.tertiaryLabelColor)
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

    private func sourceListSource() throws -> String {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardSourceListController.swift"
            ),
            encoding: .utf8
        )
    }

    private func typeSource(named name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "final class \(name)"))
        let remainder = source[start.upperBound...]
        let end = remainder.range(of: "\nfinal class ")?.lowerBound ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }

    private func sectionCell(in outline: NSOutlineView, row: Int) throws -> DashboardSourceListCellView {
        try XCTUnwrap(
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? DashboardSourceListCellView
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
            XCTAssertTrue(
                cell.textField?.allowsVibrancy == true,
                "\(section) title must keep sidebar vibrancy after rebuild"
            )
            XCTAssertTrue(
                cell.textField?.textColor?.isEqual(NSColor.labelColor) ?? false,
                "\(section) title must keep semantic labelColor after rebuild"
            )
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
