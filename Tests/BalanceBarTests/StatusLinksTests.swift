import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class StatusLinksTests: XCTestCase {
    func testStatusLinkCodableAndEquatableContractIsUnchanged() throws {
        let links = [
            StatusLink(title: "Status", url: "https://status.example")
        ]

        let data = try JSONEncoder().encode(links)
        XCTAssertEqual(
            try JSONDecoder().decode([StatusLink].self, from: data),
            links
        )
    }

    func testEditorUsesNativeTableWithNameAndURLColumns() throws {
        let editor = StatusLinksEditorView(
            links: [StatusLink(title: "Status", url: "https://status.example")],
            onLinksChanged: { _ in },
            onReset: { [] }
        )
        let window = attach(editor)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let table = editor.tableViewForTesting
        let scrollView = editor.scrollViewForTesting
        XCTAssertEqual(editor.tableColumnCount, 2)
        XCTAssertEqual(
            editor.tableColumnIdentifiers,
            [StatusLinksEditorView.nameColumnIdentifier, StatusLinksEditorView.urlColumnIdentifier]
        )
        XCTAssertTrue(scrollView.documentView === table)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(table.style, .fullWidth)
        XCTAssertEqual(table.rowSizeStyle, .medium)
        XCTAssertEqual(table.selectionHighlightStyle, .regular)
        XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
        XCTAssertFalse(table.allowsColumnSelection)
        XCTAssertFalse(table.allowsColumnReordering)
        XCTAssertTrue(table.gridStyleMask.isEmpty)
        XCTAssertNotNil(table.headerView)
        XCTAssertEqual(table.tableColumns.map(\.title), [
            tr(.keyStatusLinksEditorName),
            tr(.keyStatusLinksEditorUrl)
        ])
        XCTAssertEqual(editor.listContainerForTesting.boxType, .primary)
        XCTAssertGreaterThan(editor.listContainerForTesting.contentViewMargins.width, 0)
        XCTAssertGreaterThan(editor.listContainerForTesting.contentViewMargins.height, 0)
        XCTAssertEqual(scrollView.borderType, .noBorder)
        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertLessThan(table.backgroundColor.alphaComponent, 1)
        XCTAssertFalse(editor.addButtonForTesting.isBordered)
        XCTAssertFalse(editor.removeButtonForTesting.isBordered)
        XCTAssertEqual(editor.horizontalSeparatorForTesting.boxType, .separator)
        XCTAssertEqual(editor.verticalSeparatorForTesting.boxType, .separator)
        let listContentView = try XCTUnwrap(editor.listContainerForTesting.contentView)
        XCTAssertTrue(scrollView.isDescendant(of: listContentView))
        XCTAssertTrue(editor.footerViewForTesting.isDescendant(of: listContentView))
        XCTAssertTrue(editor.horizontalSeparatorForTesting.isDescendant(of: listContentView))
        XCTAssertTrue(editor.footerViewForTesting.arrangedSubviews.contains { $0 === editor.addButtonForTesting })
        XCTAssertTrue(editor.footerViewForTesting.arrangedSubviews.contains { $0 === editor.verticalSeparatorForTesting })
        XCTAssertTrue(editor.footerViewForTesting.arrangedSubviews.contains { $0 === editor.removeButtonForTesting })
        XCTAssertFalse(listContentView.subviews.contains { $0 === editor.resetButtonForTesting })
        XCTAssertTrue(
            table.registeredDraggedTypes.contains(
                NSPasteboard.PasteboardType("com.huanmeng06.BalanceBar.status-link-row")
            )
        )
        XCTAssertEqual(table.numberOfRows, 1)

        let nameCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let urlCell = try XCTUnwrap(
            table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let nameField = try XCTUnwrap(nameCell.textField)
        let urlField = try XCTUnwrap(urlCell.textField)
        XCTAssertEqual(nameField.stringValue, "Status")
        XCTAssertEqual(urlField.stringValue, "https://status.example")
        XCTAssertTrue(nameField.isEditable)
        XCTAssertTrue(urlField.isEditable)
    }

    func testNativeSelectionStaysActiveAndOnlyEditingFieldGetsSystemSurface() throws {
        let editor = StatusLinksEditorView(
            links: [StatusLink(title: "Status", url: "https://status.example")],
            onLinksChanged: { _ in },
            onReset: { [] }
        )
        let window = attach(editor)
        defer {
            editor.endEditing()
            window.orderOut(nil)
            window.contentView = nil
        }

        let table = editor.tableViewForTesting
        let nameCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let urlCell = try XCTUnwrap(
            table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let nameField = try XCTUnwrap(nameCell.textField)
        let urlField = try XCTUnwrap(urlCell.textField)
        XCTAssertFalse(nameField.drawsBackground)
        XCTAssertFalse(urlField.drawsBackground)

        XCTAssertTrue(editor.editForTesting(column: 0, row: 0))

        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertTrue(table.rowView(atRow: 0, makeIfNecessary: false)?.isSelected == true)
        XCTAssertTrue(nameField.drawsBackground)
        XCTAssertFalse(urlField.drawsBackground)

        editor.endEditing()

        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertFalse(nameField.drawsBackground)
        XCTAssertFalse(urlField.drawsBackground)
    }

    func testFooterActionsStayCompactAndSemanticLeadingAtNormalAndMinimumWidths() throws {
        let probeEditor = StatusLinksEditorView(
            links: [StatusLink(title: "Status", url: "https://status.example")],
            onLinksChanged: { _ in },
            onReset: { [] }
        )
        let minimumEditorWidth = probeEditor.tableViewForTesting.tableColumns.reduce(CGFloat(0)) {
            $0 + $1.minWidth
        } + DashboardSettingsComponents.settingsRowHorizontalInset * 2

        for width in [minimumEditorWidth, minimumEditorWidth + 220] {
            let editor = StatusLinksEditorView(
                links: [StatusLink(title: "Status", url: "https://status.example")],
                onLinksChanged: { _ in },
                onReset: { [] }
            )
            editor.frame = NSRect(x: 0, y: 0, width: width, height: StatusLinksEditorView.fixedHeight)
            editor.needsLayout = true
            editor.layoutSubtreeIfNeeded()
            let listContentView = try XCTUnwrap(editor.listContainerForTesting.contentView)
            for hostedView in [
                editor.scrollViewForTesting,
                editor.footerViewForTesting,
                editor.horizontalSeparatorForTesting
            ] {
                let hostedFrame = hostedView.convert(hostedView.bounds, to: listContentView)
                XCTAssertTrue(
                    listContentView.bounds.insetBy(dx: -1, dy: -1).contains(hostedFrame),
                    "Native list content must remain inside the NSBox content view"
                )
            }
            let footer = editor.footerViewForTesting
            let add = editor.addButtonForTesting
            let separator = editor.verticalSeparatorForTesting
            let remove = editor.removeButtonForTesting
            let footerFrame = footer.convert(footer.bounds, to: editor)
            let addFrame = add.convert(add.bounds, to: editor)
            let separatorFrame = separator.convert(separator.bounds, to: editor)
            let removeFrame = remove.convert(remove.bounds, to: editor)
            let sortedButtonFrames = [addFrame, removeFrame].sorted { $0.minX < $1.minX }

            XCTAssertGreaterThan(addFrame.width, 0)
            XCTAssertGreaterThan(removeFrame.width, 0)
            XCTAssertLessThanOrEqual(
                addFrame.width,
                max(add.fittingSize.width * 2, add.fittingSize.width + 12),
                "Add must keep an intrinsic-sized hit area at width \(width)"
            )
            XCTAssertLessThanOrEqual(
                removeFrame.width,
                max(remove.fittingSize.width * 2, remove.fittingSize.width + 12),
                "Remove must keep an intrinsic-sized hit area at width \(width)"
            )
            XCTAssertLessThan(sortedButtonFrames[0].maxX, separatorFrame.minX)
            XCTAssertLessThan(separatorFrame.maxX, sortedButtonFrames[1].minX)

            let isRightToLeft = editor.userInterfaceLayoutDirection == .rightToLeft
            if isRightToLeft {
                XCTAssertGreaterThanOrEqual(footerFrame.minX, editor.bounds.midX)
                XCTAssertGreaterThan(footerFrame.minX - editor.bounds.minX, footerFrame.width)
            } else {
                XCTAssertLessThanOrEqual(
                    footerFrame.maxX,
                    editor.bounds.midX,
                    "Footer actions must remain semantic-leading at width \(width)"
                )
                XCTAssertGreaterThan(
                    editor.bounds.maxX - footerFrame.maxX,
                    footerFrame.width,
                    "Footer must retain empty trailing space at width \(width)"
                )
            }

            let trailingPoint = NSPoint(
                x: isRightToLeft ? editor.bounds.minX + 1 : editor.bounds.maxX - 1,
                y: addFrame.midY
            )
            XCTAssertFalse(
                addFrame.contains(trailingPoint),
                "Empty footer space must not be part of Add's hit area at width \(width)"
            )
        }
    }

    func testTextEditingPersistsOnlyWhenEditingEnds() throws {
        var changes: [[StatusLink]] = []
        let editor = StatusLinksEditorView(
            links: [StatusLink(title: "Before", url: "https://before.example")],
            onLinksChanged: { changes.append($0) },
            onReset: { [] }
        )
        let window = attach(editor)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let table = editor.tableViewForTesting
        XCTAssertTrue(editor.editForTesting(column: 0, row: 0))
        let cell = try XCTUnwrap(table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        let field = try XCTUnwrap((cell as? NSTableCellView)?.textField)
        let fieldEditor = try XCTUnwrap(window.fieldEditor(false, for: field))
        XCTAssertTrue(editor.isEditingNameForTesting)

        fieldEditor.string = "After"
        XCTAssertTrue(changes.isEmpty, "A keystroke must not persist the whole preferences array")

        editor.endEditing()
        XCTAssertEqual(changes, [[StatusLink(title: "After", url: "https://before.example")]])
        XCTAssertEqual(editor.links[0].title, "After")
    }

    func testCloseNotificationCommitsActiveNativeFieldEditor() throws {
        var changes: [[StatusLink]] = []
        let editor = StatusLinksEditorView(
            links: [StatusLink(title: "Before", url: "https://before.example")],
            onLinksChanged: { changes.append($0) },
            onReset: { [] }
        )
        let window = attach(editor)
        let cell = try XCTUnwrap(editor.tableViewForTesting.view(
            atColumn: 1,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertTrue(editor.editForTesting(column: 1, row: 0))
        let field = try XCTUnwrap((cell as? NSTableCellView)?.textField)
        let fieldEditor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
        fieldEditor.string = "https://after.example"
        editor.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))

        window.close()

        XCTAssertEqual(changes, [[StatusLink(title: "Before", url: "https://after.example")]])
        XCTAssertEqual(editor.links[0].url, "https://after.example")
        window.contentView = nil
    }

    func testAddRemoveResetAndNativeReorderUpdateOneArray() throws {
        var changes: [[StatusLink]] = []
        var resetCount = 0
        let defaults = [StatusLink(title: "Default", url: "https://default.example")]
        let editor = StatusLinksEditorView(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example")
            ],
            onLinksChanged: { changes.append($0) },
            onReset: {
                resetCount += 1
                return defaults
            }
        )
        let window = attach(editor)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        XCTAssertFalse(editor.removeButtonForTesting.isEnabled)
        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        XCTAssertTrue(editor.removeButtonForTesting.isEnabled)
        editor.removeButtonForTesting.performClick(nil)
        XCTAssertEqual(editor.links.map(\.title), ["Two"])

        editor.addButtonForTesting.performClick(nil)
        XCTAssertEqual(editor.links.count, 2)
        XCTAssertEqual(editor.links.last, StatusLink(title: "", url: ""))
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        XCTAssertTrue(editor.isEditingNameForTesting)
        let addedNameCell = try XCTUnwrap(
            editor.tableViewForTesting.view(
                atColumn: 0,
                row: 1,
                makeIfNecessary: false
            ) as? NSTableCellView
        )
        XCTAssertNotNil(addedNameCell.textField?.currentEditor())

        XCTAssertTrue(editor.reorderForTesting(from: 1, to: 0))
        XCTAssertEqual(editor.links.map(\.title), ["", "Two"])

        editor.resetButtonForTesting.performClick(nil)
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(editor.links, defaults)
        XCTAssertGreaterThanOrEqual(changes.count, 3)
    }

    func testFixedViewportScrollsRowsWithoutChangingEditorHeight() {
        let first = [StatusLink(title: "One", url: "https://one.example")]
        let editor = StatusLinksEditorView(
            links: first,
            onLinksChanged: { _ in },
            onReset: { [] }
        )
        let window = attach(editor)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let initialHeight = editor.layoutHeight
        editor.updateLinks((0..<20).map {
            StatusLink(title: "Link \($0)", url: "https://\($0).example")
        })
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(editor.layoutHeight, initialHeight, accuracy: 0.001)
        XCTAssertEqual(editor.currentHeight, StatusLinksEditorView.fixedHeight, accuracy: 0.001)
        XCTAssertGreaterThan(
            editor.tableViewForTesting.frame.height,
            editor.scrollViewForTesting.contentView.bounds.height
        )
        XCTAssertNotNil(editor.tableViewForTesting.headerView)
        XCTAssertEqual(editor.frame.height, StatusLinksEditorView.fixedHeight, accuracy: 1)
    }

    func testVisibilityKeepsOneEditorAndUsesItsFixedHeight() {
        let editor = StatusLinksEditorView(
            links: [],
            onLinksChanged: { _ in },
            onReset: { [] }
        )
        let window = attach(editor)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        editor.setVisible(false, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.isVisible)
        XCTAssertEqual(editor.currentHeight, 0, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, 0, accuracy: 0.001)

        editor.setVisible(true, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.isVisible)
        XCTAssertEqual(editor.currentHeight, StatusLinksEditorView.fixedHeight, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, StatusLinksEditorView.fixedHeight, accuracy: 1)
        XCTAssertTrue(editor.superview != nil)
    }

    func testTeardownIsIdempotentAndReleasesEditor() {
        weak var releasedEditor: StatusLinksEditorView?
        var window: NSWindow?
        autoreleasepool {
            var editor: StatusLinksEditorView? = StatusLinksEditorView(
                links: [],
                onLinksChanged: { _ in },
                onReset: { [] }
            )
            releasedEditor = editor
            window = attach(editor!)
            editor?.teardown()
            editor?.teardown()
            window?.contentView = nil
            editor = nil
        }
        window = nil

        XCTAssertNil(releasedEditor)
    }

    @discardableResult
    private func attach(_ editor: StatusLinksEditorView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        window.contentView = container
        editor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }
}
