import AppKit
import XCTest
@testable import BalanceBar

@MainActor
private final class TrackingStatusLinksTableView: NSTableView {
    private(set) var reloadCount = 0
    private(set) var insertedRows: [(IndexSet, NSTableView.AnimationOptions)] = []
    private(set) var removedRows: [(IndexSet, NSTableView.AnimationOptions)] = []
    private(set) var movedRows: [(Int, Int)] = []

    override func reloadData() {
        reloadCount += 1
        super.reloadData()
    }

    override func insertRows(
        at rowIndexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        insertedRows.append((rowIndexes, animationOptions))
        super.insertRows(at: rowIndexes, withAnimation: animationOptions)
    }

    override func removeRows(
        at rowIndexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        removedRows.append((rowIndexes, animationOptions))
        super.removeRows(at: rowIndexes, withAnimation: animationOptions)
    }

    override func moveRow(at oldRow: Int, to newRow: Int) {
        movedRows.append((oldRow, newRow))
        super.moveRow(at: oldRow, to: newRow)
    }
}

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
        onAdd: @escaping (Int) -> Void = { _ in },
        onRemove: @escaping (Int) -> Void = { _ in },
        onReset: @escaping () -> Void = {},
        onMove: @escaping (Int, Int) -> Void = { _, _ in },
        onDuplicate: @escaping (Int) -> Void = { _ in },
        openURL: @escaping (URL) -> Bool = { _ in false },
        tableView: NSTableView? = nil,
        shouldReduceMotion: @escaping () -> Bool = { false }
    ) -> StatusLinksEditorHostingView {
        StatusLinksEditorHostingView(
            links: links,
            onChange: onChange,
            onAdd: onAdd,
            onRemove: onRemove,
            onReset: onReset,
            onMove: onMove,
            onDuplicate: onDuplicate,
            openURL: openURL,
            tableView: tableView ?? NSTableView(),
            shouldReduceMotion: shouldReduceMotion
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
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(tableContainer.borderColor, NSColor.separatorColor)
        let containerLayer = try XCTUnwrap(tableContainer.layer)
        XCTAssertEqual(
            containerLayer.borderWidth,
            StatusLinksEditorHostingView.tableBorderWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            containerLayer.cornerRadius,
            StatusLinksEditorHostingView.tableCornerRadius,
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
        XCTAssertTrue(table.gridStyleMask.isEmpty)
        XCTAssertEqual(table.style, .fullWidth)
        XCTAssertTrue(table.usesAlternatingRowBackgroundColors)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse((scrollView as? StatusLinksScrollView)?.allowsVerticalScrolling ?? true)
        XCTAssertEqual(editor.actionsControlForTesting.segmentCount, 2)
        XCTAssertFalse(editor.actionsControlForTesting.isEnabled(forSegment: 1))
        XCTAssertEqual(editor.actionsControlForTesting.alignment(forSegment: 0), .center)
        XCTAssertEqual(editor.actionsControlForTesting.alignment(forSegment: 1), .center)
        let moveControl = editor.moveControlForTesting
        XCTAssertEqual(moveControl.segmentCount, 2)
        XCTAssertEqual(moveControl.segmentStyle, .automatic)
        XCTAssertEqual(moveControl.trackingMode, .momentary)
        XCTAssertNotNil(moveControl.image(forSegment: 0))
        XCTAssertNotNil(moveControl.image(forSegment: 1))
        XCTAssertEqual(
            moveControl.frame.minX - editor.actionsControlForTesting.frame.maxX,
            8,
            accuracy: 1
        )
        XCTAssertFalse(moveControl.isEnabled(forSegment: 0))
        XCTAssertFalse(moveControl.isEnabled(forSegment: 1))
        let moreButton = editor.moreButtonForTesting
        XCTAssertEqual(moreButton.identifier?.rawValue, "statusLinks.more")
        XCTAssertEqual(moreButton.controlSize, editor.actionsControlForTesting.controlSize)
        XCTAssertEqual(moreButton.bezelStyle, .rounded)
        XCTAssertEqual(
            moreButton.frame.minX - moveControl.frame.maxX,
            8,
            accuracy: 1,
            "More should follow the move control with an 8 pt gap"
        )
        XCTAssertEqual(moreButton.frame.height, moveControl.frame.height, accuracy: 1)
        XCTAssertFalse(moreButton.isEnabled)
        XCTAssertEqual(moreButton.alphaValue, 1, accuracy: 0.001)
        let moreIconView = editor.moreIconViewForTesting
        XCTAssertTrue(moreIconView.superview === moreButton)
        XCTAssertTrue(moreIconView is StatusLinksPassthroughImageView)
        XCTAssertEqual(
            moreIconView.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorMoreActions)
        )
        XCTAssertEqual(moreIconView.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(
            moreIconView.hitTest(NSPoint(x: moreIconView.bounds.midX, y: moreIconView.bounds.midY)),
            "The icon overlay must not intercept More button clicks"
        )
        let moreMenu = editor.moreMenuForTesting
        XCTAssertEqual(moreMenu.items.count, 4)
        XCTAssertEqual(moreMenu.items[0].title, tr(.keyStatusLinksEditorOpenLink))
        XCTAssertEqual(moreMenu.items[1].title, tr(.keyStatusLinksEditorCopyURL))
        XCTAssertTrue(moreMenu.items[2].isSeparatorItem)
        XCTAssertEqual(moreMenu.items[3].title, tr(.keyStatusLinksEditorCopyItem))
        XCTAssertFalse(moreMenu.items[0].isEnabled)
        XCTAssertFalse(moreMenu.items[1].isEnabled)
        XCTAssertFalse(moreMenu.items[3].isEnabled)
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
            onAdd: { index in
                addCount += 1
                editor.updateLinks(
                    editor.links + [StatusLink(title: "", url: "")],
                    mutation: .insert(index),
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

    func testInsertMutationUsesExactIndexWithoutReloadAndSelectsNewRow() throws {
        var editor: StatusLinksEditorHostingView!
        let table = TrackingStatusLinksTableView()
        var insertedIndex: Int?
        editor = makeEditor(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example")
            ],
            onAdd: { index in
                insertedIndex = index
                var updatedLinks = editor.links
                updatedLinks.insert(StatusLink(title: "New", url: ""), at: index)
                editor.updateLinks(
                    updatedLinks,
                    mutation: .insert(index)
                )
            },
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.performActionForTesting(segment: 0)

        XCTAssertEqual(insertedIndex, 2)
        XCTAssertEqual(table.reloadCount, 0)
        XCTAssertEqual(table.insertedRows.count, 1)
        XCTAssertEqual(table.insertedRows[0].0, IndexSet(integer: 2))
        XCTAssertEqual(table.insertedRows[0].1, .effectGap)
        XCTAssertEqual(editor.rowCount, 3)
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 2)
    }

    func testRemoveMutationUsesExactIndexAndSelectsReplacementRow() throws {
        var editor: StatusLinksEditorHostingView!
        let table = TrackingStatusLinksTableView()
        var removedIndex: Int?
        editor = makeEditor(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example"),
                StatusLink(title: "Three", url: "https://three.example")
            ],
            onRemove: { index in
                removedIndex = index
                var updatedLinks = editor.links
                updatedLinks.remove(at: index)
                editor.updateLinks(updatedLinks, mutation: .remove(index))
            },
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }
        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        editor.performActionForTesting(segment: 1)

        XCTAssertEqual(removedIndex, 1)
        XCTAssertEqual(table.reloadCount, 0)
        XCTAssertEqual(table.removedRows.count, 1)
        XCTAssertEqual(table.removedRows[0].0, IndexSet(integer: 1))
        XCTAssertEqual(table.removedRows[0].1, .effectFade)
        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
    }

    func testRemoveMutationSelectsNewLastRowOrClearsOnlyRowSelection() throws {
        var lastEditor: StatusLinksEditorHostingView!
        let lastTable = TrackingStatusLinksTableView()
        lastEditor = makeEditor(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example")
            ],
            onRemove: { index in
                var updatedLinks = lastEditor.links
                updatedLinks.remove(at: index)
                lastEditor.updateLinks(updatedLinks, mutation: .remove(index))
            },
            tableView: lastTable
        )
        let lastWindow = makeWindow(for: lastEditor)
        defer { lastWindow.orderOut(nil) }
        lastEditor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )
        lastEditor.performActionForTesting(segment: 1)
        XCTAssertEqual(lastEditor.tableViewForTesting.selectedRow, 0)

        var onlyEditor: StatusLinksEditorHostingView!
        let onlyTable = TrackingStatusLinksTableView()
        onlyEditor = makeEditor(
            links: [StatusLink(title: "Only", url: "https://only.example")],
            onRemove: { index in
                var updatedLinks = onlyEditor.links
                updatedLinks.remove(at: index)
                onlyEditor.updateLinks(updatedLinks, mutation: .remove(index))
            },
            tableView: onlyTable
        )
        let onlyWindow = makeWindow(for: onlyEditor)
        defer { onlyWindow.orderOut(nil) }
        onlyEditor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        onlyEditor.performActionForTesting(segment: 1)
        XCTAssertEqual(onlyEditor.rowCount, 0)
        XCTAssertEqual(onlyEditor.tableViewForTesting.selectedRow, -1)
        XCTAssertEqual(onlyTable.removedRows[0].0, IndexSet(integer: 0))
    }

    func testEditorMoveControlsFollowSelectionAndMoveRows() throws {
        let initialLinks = [
            StatusLink(title: "One", url: "https://one.example"),
            StatusLink(title: "Two", url: "https://two.example"),
            StatusLink(title: "Three", url: "https://three.example")
        ]
        var editor: StatusLinksEditorHostingView!
        let table = TrackingStatusLinksTableView()
        var moves: [String] = []
        editor = makeEditor(
            links: initialLinks,
            onMove: { from, to in
                moves.append("\(from)->\(to)")
                var reordered = editor.links
                let movedLink = reordered.remove(at: from)
                reordered.insert(movedLink, at: to)
                editor.updateLinks(reordered, mutation: .move(from: from, to: to))
            },
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let moveControl = editor.moveControlForTesting
        func select(_ row: Int?) {
            if let row {
                editor.tableViewForTesting.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false
                )
            } else {
                editor.tableViewForTesting.deselectAll(nil)
            }
            editor.tableViewSelectionDidChange(Notification(name: NSNotification.Name("Selection")))
        }

        XCTAssertFalse(moveControl.isEnabled(forSegment: 0))
        XCTAssertFalse(moveControl.isEnabled(forSegment: 1))

        select(0)
        XCTAssertFalse(moveControl.isEnabled(forSegment: 0))
        XCTAssertTrue(moveControl.isEnabled(forSegment: 1))
        editor.performMoveActionForTesting(segment: 0)
        XCTAssertTrue(moves.isEmpty)

        editor.performMoveActionForTesting(segment: 1)
        XCTAssertEqual(moves, ["0->1"])
        XCTAssertEqual(table.reloadCount, 0)
        XCTAssertEqual(table.movedRows.map { "\($0.0)->\($0.1)" }, ["0->1"])
        XCTAssertEqual(editor.links.map(\.title), ["Two", "One", "Three"])
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        XCTAssertTrue(moveControl.isEnabled(forSegment: 0))
        XCTAssertTrue(moveControl.isEnabled(forSegment: 1))

        editor.performMoveActionForTesting(segment: 1)
        XCTAssertEqual(moves, ["0->1", "1->2"])
        XCTAssertEqual(
            table.movedRows.map { "\($0.0)->\($0.1)" },
            ["0->1", "1->2"]
        )
        XCTAssertEqual(editor.links.map(\.title), ["Two", "Three", "One"])
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 2)
        XCTAssertTrue(moveControl.isEnabled(forSegment: 0))
        XCTAssertFalse(moveControl.isEnabled(forSegment: 1))

        editor.performMoveActionForTesting(segment: 0)
        XCTAssertEqual(moves, ["0->1", "1->2", "2->1"])
        XCTAssertEqual(
            table.movedRows.map { "\($0.0)->\($0.1)" },
            ["0->1", "1->2", "2->1"]
        )
        XCTAssertEqual(editor.links.map(\.title), ["Two", "One", "Three"])
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        XCTAssertTrue(moveControl.isEnabled(forSegment: 0))
        XCTAssertTrue(moveControl.isEnabled(forSegment: 1))

        select(nil)
        XCTAssertFalse(moveControl.isEnabled(forSegment: 0))
        XCTAssertFalse(moveControl.isEnabled(forSegment: 1))

        editor.updateLinks([initialLinks[0]])
        select(0)
        XCTAssertFalse(moveControl.isEnabled(forSegment: 0))
        XCTAssertFalse(moveControl.isEnabled(forSegment: 1))
    }

    func testInvalidMutationFallsBackToReload() throws {
        let table = TrackingStatusLinksTableView()
        let editor = makeEditor(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example")
            ],
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.updateLinks(
            [StatusLink(title: "Only", url: "https://only.example")],
            mutation: .remove(99)
        )

        XCTAssertEqual(table.reloadCount, 1)
        XCTAssertTrue(table.insertedRows.isEmpty)
        XCTAssertTrue(table.removedRows.isEmpty)
        XCTAssertTrue(table.movedRows.isEmpty)
        XCTAssertEqual(editor.rowCount, 1)
    }

    func testReduceMotionDisablesNativeInsertAndRemoveAnimations() throws {
        var editor: StatusLinksEditorHostingView!
        let table = TrackingStatusLinksTableView()
        editor = makeEditor(
            links: [StatusLink(title: "One", url: "https://one.example")],
            onAdd: { index in
                var updatedLinks = editor.links
                updatedLinks.insert(StatusLink(title: "Two", url: "https://two.example"), at: index)
                editor.updateLinks(updatedLinks, mutation: .insert(index))
            },
            onRemove: { index in
                var updatedLinks = editor.links
                updatedLinks.remove(at: index)
                editor.updateLinks(updatedLinks, mutation: .remove(index))
            },
            tableView: table,
            shouldReduceMotion: { true }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.performActionForTesting(segment: 0)
        XCTAssertEqual(table.insertedRows.last?.1, [])
        editor.performActionForTesting(segment: 1)
        XCTAssertEqual(table.removedRows.last?.1, [])
    }

    func testIncrementalMutationsUpdateScrollbarAfterRowsChange() throws {
        var editor: StatusLinksEditorHostingView!
        let table = TrackingStatusLinksTableView()
        let initialLinks = (0..<5).map {
            StatusLink(title: "Link \($0)", url: "https://\($0).example")
        }
        editor = makeEditor(
            links: initialLinks,
            onAdd: { index in
                var updatedLinks = editor.links
                updatedLinks.insert(
                    StatusLink(title: "New", url: "https://new.example"),
                    at: index
                )
                editor.updateLinks(updatedLinks, mutation: .insert(index))
            },
            onRemove: { index in
                var updatedLinks = editor.links
                updatedLinks.remove(at: index)
                editor.updateLinks(updatedLinks, mutation: .remove(index))
            },
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        XCTAssertFalse(editor.scrollViewForTesting.hasVerticalScroller)
        let initialTableHeight = editor.tableViewForTesting.frame.height

        editor.performActionForTesting(segment: 0)
        XCTAssertEqual(
            editor.tableViewForTesting.frame.height,
            initialTableHeight,
            accuracy: 0.001,
            "The document frame should not jump before the row insertion settles"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        XCTAssertTrue(editor.scrollViewForTesting.hasVerticalScroller)

        editor.performActionForTesting(segment: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        XCTAssertFalse(editor.scrollViewForTesting.hasVerticalScroller)
    }

    func testTextFieldCommitUsesCurrentTableRowAfterMove() throws {
        var changes: [(Int, StatusLinkField, String)] = []
        let table = TrackingStatusLinksTableView()
        let editor = makeEditor(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example"),
                StatusLink(title: "Three", url: "https://three.example")
            ],
            onChange: { changes.append(($0, $1, $2)) },
            tableView: table
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let field = try XCTUnwrap(
            (editor.tableViewForTesting.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        var reordered = editor.links
        let movedLink = reordered.remove(at: 1)
        reordered.insert(movedLink, at: 2)
        editor.updateLinks(reordered, mutation: .move(from: 1, to: 2))

        field.stringValue = "Moved"
        editor.controlTextDidChange(
            Notification(name: NSNotification.Name("StatusLinksMovedFieldChange"), object: field)
        )

        XCTAssertEqual(changes.map { ($0.0, $0.1, $0.2) }.map { "\($0.0):\($0.1):\($0.2)" }, ["2:title:Moved"])
        XCTAssertEqual(editor.links[2].title, "Moved")
    }

    func testEditorMoreMenuTracksURLStateAndDuplicatesSelectedRow() throws {
        let initialLinks = [
            StatusLink(title: "Empty", url: ""),
            StatusLink(title: "Invalid", url: "ftp://example.com"),
            StatusLink(title: "Valid", url: "https://example.com/status")
        ]
        var editor: StatusLinksEditorHostingView!
        var duplicatedIndices: [Int] = []
        editor = makeEditor(
            links: initialLinks,
            onDuplicate: { index in
                duplicatedIndices.append(index)
                var updatedLinks = editor.links
                updatedLinks.insert(updatedLinks[index], at: index + 1)
                editor.updateLinks(updatedLinks, mutation: .insert(index + 1))
            }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        let menu = editor.moreMenuForTesting
        let openLink = menu.items[0]
        let copyURL = menu.items[1]
        let duplicate = menu.items[3]

        func select(_ row: Int?) {
            if let row {
                editor.tableViewForTesting.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false
                )
            } else {
                editor.tableViewForTesting.deselectAll(nil)
            }
            editor.tableViewSelectionDidChange(
                Notification(name: NSNotification.Name("StatusLinksMoreSelection"))
            )
        }

        XCTAssertFalse(editor.moreButtonForTesting.isEnabled)
        XCTAssertFalse(openLink.isEnabled)
        XCTAssertFalse(copyURL.isEnabled)
        XCTAssertFalse(duplicate.isEnabled)

        select(0)
        XCTAssertTrue(editor.moreButtonForTesting.isEnabled)
        XCTAssertFalse(openLink.isEnabled, "Empty URL cannot be opened")
        XCTAssertFalse(copyURL.isEnabled, "Empty URL cannot be copied")
        XCTAssertTrue(duplicate.isEnabled)

        select(1)
        XCTAssertTrue(editor.moreButtonForTesting.isEnabled)
        XCTAssertFalse(openLink.isEnabled, "Only http(s) URLs with a host can be opened")
        XCTAssertTrue(copyURL.isEnabled, "Any non-empty URL text can be copied")
        XCTAssertTrue(duplicate.isEnabled)

        let pasteboard = NSPasteboard.general
        let previousPasteboardString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousPasteboardString {
                pasteboard.setString(previousPasteboardString, forType: .string)
            }
        }
        editor.performMoreMenuActionForTesting(at: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "ftp://example.com")
        XCTAssertEqual(editor.links, initialLinks)

        select(2)
        editor.menuWillOpen(menu)
        XCTAssertTrue(openLink.isEnabled)
        XCTAssertTrue(copyURL.isEnabled)
        XCTAssertTrue(duplicate.isEnabled)

        select(1)
        editor.performMoreMenuActionForTesting(at: 3)
        XCTAssertEqual(duplicatedIndices, [1])
        XCTAssertEqual(editor.links.map(\.title), ["Empty", "Invalid", "Invalid", "Valid"])
        XCTAssertEqual(
            editor.links.map(\.url),
            ["", "ftp://example.com", "ftp://example.com", "https://example.com/status"]
        )
        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 2)
        XCTAssertFalse(openLink.isEnabled)
        XCTAssertTrue(copyURL.isEnabled)
        XCTAssertTrue(duplicate.isEnabled)
    }

    func testMoreOpenLinkSuccessShowsCheckmarkAndRestoresEllipsis() throws {
        let expectedURL = URL(string: "https://example.com/status")!
        var openedURL: URL?
        let editor = makeEditor(
            links: [StatusLink(title: "Status", url: expectedURL.absoluteString)],
            openURL: { url in
                openedURL = url
                return true
            }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        editor.tableViewSelectionDidChange(
            Notification(name: NSNotification.Name("StatusLinksOpenSelection"))
        )

        editor.performMoreMenuActionForTesting(at: 0)
        XCTAssertEqual(openedURL, expectedURL)
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorActionCompleted)
        )
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertTrue(editor.moreButtonForTesting.isEnabled)

        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorMoreActions)
        )
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)
    }

    func testMoreCopyURLSuccessShowsCheckmarkAndKeepsURLDataUnchanged() throws {
        let links = [StatusLink(title: "Status", url: "https://example.com/status")]
        let editor = makeEditor(links: links)
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        editor.tableViewSelectionDidChange(
            Notification(name: NSNotification.Name("StatusLinksCopySelection"))
        )

        let pasteboard = NSPasteboard.general
        let previousPasteboardString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousPasteboardString {
                pasteboard.setString(previousPasteboardString, forType: .string)
            }
        }

        editor.performMoreMenuActionForTesting(at: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), links[0].url)
        XCTAssertEqual(editor.links, links)
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorActionCompleted)
        )
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)
    }

    func testMoreOpenLinkFailureDoesNotShowSuccess() throws {
        let editor = makeEditor(
            links: [StatusLink(title: "Status", url: "https://example.com/status")],
            openURL: { _ in false }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        editor.tableViewSelectionDidChange(
            Notification(name: NSNotification.Name("StatusLinksOpenFailureSelection"))
        )
        editor.performMoreMenuActionForTesting(at: 0)

        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorMoreActions)
        )
    }

    func testMoreDuplicateDoesNotShowSuccessFeedback() throws {
        var editor: StatusLinksEditorHostingView!
        editor = makeEditor(
            links: [StatusLink(title: "Status", url: "https://example.com/status")],
            onDuplicate: { index in
                var updatedLinks = editor.links
                updatedLinks.insert(updatedLinks[index], at: index + 1)
                editor.updateLinks(updatedLinks, mutation: .insert(index + 1))
            }
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        editor.tableViewSelectionDidChange(
            Notification(name: NSNotification.Name("StatusLinksDuplicateSelection"))
        )
        editor.performMoreMenuActionForTesting(at: 3)

        XCTAssertEqual(editor.tableViewForTesting.selectedRow, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(editor.tableViewForTesting.editedRow, -1)
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorMoreActions)
        )
    }

    func testMoreSuccessFeedbackRestartsItsResetTimer() throws {
        let editor = makeEditor(
            links: [StatusLink(title: "Status", url: "https://example.com/status")]
        )
        let window = makeWindow(for: editor)
        defer { window.orderOut(nil) }

        editor.tableViewForTesting.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        editor.tableViewSelectionDidChange(
            Notification(name: NSNotification.Name("StatusLinksTimerSelection"))
        )

        editor.performMoreMenuActionForTesting(at: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1.08))
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorActionCompleted),
            "The checkmark should remain until the fade-out completes"
        )
        XCTAssertLessThan(
            editor.moreIconViewForTesting.alphaValue,
            1,
            "The first success feedback should be fading out"
        )
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        editor.performMoreMenuActionForTesting(at: 1)
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorActionCompleted),
            "The first reset must not end the second success state early"
        )
        XCTAssertEqual(
            editor.moreButtonForTesting.alphaValue,
            1,
            accuracy: 0.001,
            "An interrupted fade must not make the second feedback translucent"
        )
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)

        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertEqual(
            editor.moreIconViewForTesting.image?.accessibilityDescription,
            tr(.keyStatusLinksEditorMoreActions)
        )
        XCTAssertEqual(editor.moreButtonForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(editor.moreIconViewForTesting.alphaValue, 1, accuracy: 0.001)
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
