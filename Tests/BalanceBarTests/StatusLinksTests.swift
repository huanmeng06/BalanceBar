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
        XCTAssertTrue(
            table.registeredDraggedTypes.contains(
                NSPasteboard.PasteboardType("com.huanmeng06.BalanceBar.status-link-row")
            )
        )
        XCTAssertEqual(table.numberOfRows, 1)

        let nameCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
        )
        let urlCell = try XCTUnwrap(
            table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField
        )
        XCTAssertEqual(nameCell.stringValue, "Status")
        XCTAssertEqual(urlCell.stringValue, "https://status.example")
        XCTAssertTrue(nameCell.isEditable)
        XCTAssertTrue(urlCell.isEditable)
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
        table.editColumn(0, row: 0, with: nil, select: true)
        let cell = try XCTUnwrap(table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        let fieldEditor = try XCTUnwrap(window.fieldEditor(false, for: cell))
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
        editor.tableViewForTesting.editColumn(1, row: 0, with: nil, select: true)
        let fieldEditor = try XCTUnwrap(window.fieldEditor(false, for: cell))
        fieldEditor.string = "https://after.example"

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

        editor.setVisible(true, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.isVisible)
        XCTAssertEqual(editor.currentHeight, StatusLinksEditorView.fixedHeight, accuracy: 0.001)
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
