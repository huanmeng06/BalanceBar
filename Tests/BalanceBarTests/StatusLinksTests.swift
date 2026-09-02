import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class StatusLinksTests: XCTestCase {
    private func makeWindow(
        for editor: StatusLinksEditorHostingView,
        width: CGFloat = 640,
        height: CGFloat = 320
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editor.topAnchor.constraint(equalTo: contentView.topAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeEditor(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void = { _, _, _ in },
        onAdd: @escaping () -> Void = {},
        onRemove: @escaping (Int) -> Void = { _ in },
        onReset: @escaping () -> Void = {}
    ) -> StatusLinksEditorHostingView {
        StatusLinksEditorHostingView(
            links: links,
            onChange: onChange,
            onAdd: onAdd,
            onRemove: onRemove,
            onReset: onReset
        )
    }

    func testEditorUsesOnlyNativeTableAndControls() throws {
        let links = [
            StatusLink(title: "One", url: "https://one.example"),
            StatusLink(title: "Two", url: "https://two.example")
        ]
        let editor = makeEditor(links: links)
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let table = editor.tableViewForTesting
        let tableContainer = editor.tableContainerForTesting
        let scrollView = editor.scrollViewForTesting
        XCTAssertTrue(scrollView.documentView === table)
        XCTAssertTrue(tableContainer.contentView === scrollView)
        XCTAssertEqual(tableContainer.boxType, .custom)
        XCTAssertEqual(
            tableContainer.cornerRadius,
            StatusLinksEditorHostingView.tableCornerRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(
            tableContainer.borderWidth,
            StatusLinksEditorHostingView.tableBorderWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(scrollView.borderType, .noBorder)
        XCTAssertTrue(scrollView.wantsLayer)
        let tableLayer = try XCTUnwrap(scrollView.layer)
        XCTAssertEqual(
            tableLayer.cornerRadius,
            StatusLinksEditorHostingView.tableCornerRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(tableLayer.cornerCurve, .continuous)
        XCTAssertTrue(tableLayer.masksToBounds)
        XCTAssertNil(table.headerView)
        XCTAssertEqual(table.tableColumns.count, 2)
        XCTAssertEqual(table.tableColumns.map(\.identifier), [
            NSUserInterfaceItemIdentifier("statusLinks.name.column"),
            NSUserInterfaceItemIdentifier("statusLinks.url.column")
        ])
        XCTAssertEqual(table.tableColumns[0].title, tr(.keyStatusLinksEditorName))
        XCTAssertEqual(table.tableColumns[1].title, tr(.keyStatusLinksEditorUrl))
        XCTAssertEqual(table.numberOfRows, links.count)
        XCTAssertEqual(table.gridStyleMask, .solidHorizontalGridLineMask)
        XCTAssertEqual(table.style, .fullWidth)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse((scrollView as? StatusLinksScrollView)?.allowsVerticalScrolling ?? true)
        XCTAssertEqual(editor.actionsControlForTesting.segmentCount, 2)
        XCTAssertFalse(editor.actionsControlForTesting.isEnabled(forSegment: 1))
        XCTAssertEqual(editor.actionsControlForTesting.alignment(forSegment: 0), .center)
        XCTAssertEqual(editor.actionsControlForTesting.alignment(forSegment: 1), .center)
        XCTAssertEqual(editor.resetButtonForTesting.identifier?.rawValue, "statusLinks.reset")
        XCTAssertFalse(editor.subviews.contains { $0 is NSTextField })
        XCTAssertEqual(
            editor.resetButtonForTesting.frame.midY,
            editor.actionsControlForTesting.frame.midY,
            accuracy: 1,
            "Restore Defaults should share the action row with +/-"
        )
        XCTAssertLessThan(
            editor.resetButtonForTesting.frame.maxY,
            tableContainer.frame.minY,
            "Restore Defaults should be below the table viewport"
        )

        XCTAssertGreaterThan(table.tableColumns[0].width, 0)
        XCTAssertGreaterThan(table.tableColumns[1].width, table.tableColumns[0].width)

        let nameCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let urlCell = try XCTUnwrap(
            table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let nameField = try XCTUnwrap(nameCell.textField)
        let urlField = try XCTUnwrap(urlCell.textField)
        XCTAssertEqual(nameField.identifier?.rawValue, "statusLinks.name.0")
        XCTAssertEqual(urlField.identifier?.rawValue, "statusLinks.url.0")
        XCTAssertEqual(nameField.stringValue, links[0].title)
        XCTAssertEqual(urlField.stringValue, links[0].url)
        XCTAssertTrue(nameField.isEditable)
        XCTAssertTrue(urlField.isEditable)
        XCTAssertFalse(nameField.isBordered)
        XCTAssertFalse(urlField.isBordered)
        XCTAssertFalse(nameField.drawsBackground)
        XCTAssertFalse(urlField.drawsBackground)
        let nameFieldHeight = try XCTUnwrap(
            nameField.constraints.first {
                $0.firstAttribute == .height && $0.priority == .required
            }
        )
        XCTAssertEqual(
            nameFieldHeight.constant,
            nameField.intrinsicContentSize.height,
            accuracy: 0.001,
            "The editable field should use its single-line height"
        )
        XCTAssertTrue(
            nameCell.constraints.contains {
                ($0.firstItem as? NSTextField) === nameField
                    && $0.firstAttribute == .centerY
                    && abs($0.constant) < 0.001
            },
            "The editable field should be vertically centered in its cell"
        )
        XCTAssertTrue(
            descendants(of: nameCell).filter { $0 is NSButton }.isEmpty,
            "Rows use editable text fields rather than per-row remove buttons"
        )
        XCTAssertTrue(
            descendants(of: urlCell).filter { $0 is NSButton }.isEmpty,
            "Rows use editable text fields rather than per-row remove buttons"
        )
        XCTAssertFalse(
            descendants(of: editor).contains {
                String(reflecting: type(of: $0)).contains("NSHostingView")
            },
            "The Status Links editor must not embed a SwiftUI hosting view"
        )

        table.layoutSubtreeIfNeeded()
        nameCell.layoutSubtreeIfNeeded()
        urlCell.layoutSubtreeIfNeeded()
        let nameFieldFrame = nameField.convert(nameField.bounds, to: table)
        let urlFieldFrame = urlField.convert(urlField.bounds, to: table)
        let tableBounds = table.bounds
        let leadingInset = nameFieldFrame.minX - tableBounds.minX
        let trailingInset = tableBounds.maxX - urlFieldFrame.maxX
        XCTAssertEqual(
            trailingInset,
            leadingInset,
            accuracy: 0.001,
            "The URL field's trailing inset should match the name field's leading inset"
        )

        let nativeTable = try XCTUnwrap(table as? StatusLinksTableView)
        nativeTable.drawGrid(inClipRect: table.bounds)
        let gridClipRect = try XCTUnwrap(nativeTable.lastGridClipRectForTesting)
        let lastRowRect = table.rect(ofRow: table.numberOfRows - 1)
        XCTAssertLessThanOrEqual(
            gridClipRect.maxY,
            lastRowRect.minY + 0.001,
            "Native grid drawing must stop before the last real row"
        )
    }

    func testEditorKeepsFixedHeightAndScrollsRowsInsideNativeTable() throws {
        let links = (0..<12).map {
            StatusLink(title: "Link \($0)", url: "https://\($0).example")
        }
        let editor = makeEditor(links: links)
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let initialHeight = editor.currentHeight
        XCTAssertEqual(initialHeight, StatusLinksEditorHostingView.fixedHeight, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, initialHeight, accuracy: 1)
        XCTAssertGreaterThan(editor.scrollViewForTesting.frame.height, 0)
        XCTAssertGreaterThan(
            editor.tableViewForTesting.frame.height,
            editor.scrollViewForTesting.contentView.bounds.height,
            "Long lists should scroll within the table viewport"
        )
        XCTAssertTrue(editor.scrollViewForTesting.hasVerticalScroller)
        XCTAssertTrue(
            (editor.scrollViewForTesting as? StatusLinksScrollView)?.allowsVerticalScrolling ?? false
        )

        editor.updateLinks(links + [StatusLink(title: "Link 12", url: "https://12.example")])
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(editor.rowCount, 13)
        XCTAssertEqual(editor.layoutHeight, initialHeight, accuracy: 0.001)
        XCTAssertEqual(editor.currentHeight, initialHeight, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, initialHeight, accuracy: 1)
        XCTAssertGreaterThan(
            editor.tableViewForTesting.frame.height,
            editor.scrollViewForTesting.contentView.bounds.height
        )
    }

    func testEmptyEditorDoesNotAllowVerticalDragging() throws {
        let editor = makeEditor(links: [])
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        XCTAssertFalse(editor.scrollViewForTesting.hasVerticalScroller)
        XCTAssertFalse(
            (editor.scrollViewForTesting as? StatusLinksScrollView)?.allowsVerticalScrolling ?? true
        )
        XCTAssertEqual(editor.scrollViewForTesting.verticalScrollElasticity, .none)

        let nativeTable = try XCTUnwrap(
            editor.tableViewForTesting as? StatusLinksTableView
        )
        nativeTable.drawGrid(inClipRect: nativeTable.bounds)
        XCTAssertNil(
            nativeTable.lastGridClipRectForTesting,
            "An empty native table must not draw grid lines"
        )
    }

    func testEditorCommitsNativeNameAndURLEdits() throws {
        var changes: [(Int, StatusLinkField, String)] = []
        let editor = makeEditor(
            links: [StatusLink(title: "One", url: "https://one.example")],
            onChange: { changes.append(($0, $1, $2)) }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let nameField = try XCTUnwrap(
            (editor.tableViewForTesting.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        nameField.stringValue = "Updated"
        editor.controlTextDidChange(
            Notification(name: NSNotification.Name("StatusLinksTestChange"), object: nameField)
        )

        let urlField = try XCTUnwrap(
            (editor.tableViewForTesting.view(atColumn: 1, row: 0, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        urlField.stringValue = "https://updated.example"
        editor.controlTextDidEndEditing(
            Notification(name: NSNotification.Name("StatusLinksTestEndEditing"), object: urlField)
        )

        XCTAssertEqual(editor.links[0].title, "Updated")
        XCTAssertEqual(editor.links[0].url, "https://updated.example")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].0, 0)
        XCTAssertEqual(changes[0].1, .title)
        XCTAssertEqual(changes[0].2, "Updated")
        XCTAssertEqual(changes[1].0, 0)
        XCTAssertEqual(changes[1].1, .url)
        XCTAssertEqual(changes[1].2, "https://updated.example")
    }

    func testEditorNativeActionsAddSelectsNewRowRemoveUsesSelectionAndResetCallsBack() throws {
        var editor: StatusLinksEditorHostingView!
        var addCount = 0
        var removedIndices: [Int] = []
        var resetCount = 0
        editor = makeEditor(
            links: [StatusLink(title: "One", url: "https://one.example")],
            onAdd: {
                addCount += 1
                editor.updateLinks(
                    editor.links + [StatusLink(title: "", url: "")],
                    selectLastRow: true
                )
            },
            onRemove: { removedIndices.append($0) },
            onReset: { resetCount += 1 }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.performActionForTesting(segment: 1)
        XCTAssertTrue(removedIndices.isEmpty, "Remove is disabled until a row is selected")

        editor.performActionForTesting(segment: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        XCTAssertEqual(addCount, 1)
        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        XCTAssertTrue(editor.actionsControlForTesting.isEnabled(forSegment: 1))

        editor.performActionForTesting(segment: 1)
        XCTAssertEqual(removedIndices, [1])

        editor.resetButtonForTesting.performClick(nil)
        XCTAssertEqual(resetCount, 1)
    }

    func testEditorPreservesAndClampsSelectionWhenLinksChange() throws {
        let links = [
            StatusLink(title: "One", url: "https://one.example"),
            StatusLink(title: "Two", url: "https://two.example"),
            StatusLink(title: "Three", url: "https://three.example")
        ]
        let editor = makeEditor(links: links)
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        editor.tableViewSelectionDidChange(Notification(name: NSNotification.Name("Selection")))
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 2)
        XCTAssertTrue(editor.actionsControlForTesting.isEnabled(forSegment: 1))

        editor.updateLinks(Array(links.prefix(2)))
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        XCTAssertTrue(editor.actionsControlForTesting.isEnabled(forSegment: 1))

        editor.updateLinks([])
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, -1)
        XCTAssertFalse(editor.actionsControlForTesting.isEnabled(forSegment: 1))
    }

    func testEditorVisibilityCollapsesOnlyItsFixedOuterRowAndTeardownIsIdempotent() {
        let editor = makeEditor(
            links: [StatusLink(title: "One", url: "https://one.example")]
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.setVisible(false, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.currentHeight, 0, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, 0, accuracy: 1)
        XCTAssertEqual(editor.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(editor.clipsToBounds)

        editor.setVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.currentHeight, StatusLinksEditorHostingView.fixedHeight, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, StatusLinksEditorHostingView.fixedHeight, accuracy: 1)
        XCTAssertEqual(editor.alphaValue, 1, accuracy: 0.001)

        editor.teardown()
        editor.teardown()
        XCTAssertTrue(editor.isTornDown)
        XCTAssertNil(editor.tableViewForTesting.delegate)
        XCTAssertNil(editor.tableViewForTesting.dataSource)
        XCTAssertNil(editor.actionsControlForTesting.target)
    }

    func testEditorCanBeReleasedAfterTeardown() {
        weak var releasedEditor: StatusLinksEditorHostingView?

        autoreleasepool {
            var editor: StatusLinksEditorHostingView? = makeEditor(
                links: [StatusLink(title: "One", url: "https://one.example")]
            )
            releasedEditor = editor
            editor?.teardown()
            editor = nil
        }

        XCTAssertNil(releasedEditor)
    }
}
