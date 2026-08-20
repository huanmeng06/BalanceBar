import AppKit
import XCTest
@testable import BalanceBar

private final class StatusLinksFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class StatusLinksTests: XCTestCase {
    func testEditorModelDeliversEditAddRemoveAndResetCallbacks() {
        var changes: [(Int, StatusLinkField, String)] = []
        var addCount = 0
        var removedIndices: [Int] = []
        var resetCount = 0
        let model = StatusLinksEditorModel(
            links: [
                StatusLink(title: "One", url: "https://one.example"),
                StatusLink(title: "Two", url: "https://two.example")
            ],
            onChange: { changes.append(($0, $1, $2)) },
            onAdd: { addCount += 1 },
            onRemove: { removedIndices.append($0) },
            onReset: { resetCount += 1 }
        )

        model.edit(index: 1, field: .title, value: "Updated")
        model.edit(index: 0, field: .url, value: "https://updated.example")
        model.edit(index: -1, field: .title, value: "Ignored")
        model.edit(index: 99, field: .url, value: "Ignored")
        model.add()
        model.remove(at: 1)
        model.remove(at: -1)
        model.remove(at: 99)
        model.reset()

        XCTAssertEqual(model.links[1].title, "Updated")
        XCTAssertEqual(model.links[0].url, "https://updated.example")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].0, 1)
        XCTAssertEqual(changes[0].1, .title)
        XCTAssertEqual(changes[0].2, "Updated")
        XCTAssertEqual(changes[1].0, 0)
        XCTAssertEqual(changes[1].1, .url)
        XCTAssertEqual(changes[1].2, "https://updated.example")
        XCTAssertEqual(addCount, 1)
        XCTAssertEqual(removedIndices, [1])
        XCTAssertEqual(resetCount, 1)
    }

    func testEditorModelGatesRapidAddsUntilRevealSettles() {
        var addCount = 0
        let model = StatusLinksEditorModel(
            links: [StatusLink(title: "One", url: "https://one.example")],
            onChange: { _, _, _ in },
            onAdd: { addCount += 1 },
            onRemove: { _ in },
            onReset: { }
        )

        model.add()
        model.add()
        model.add()

        XCTAssertEqual(addCount, 1)
        XCTAssertTrue(model.isAddInFlight)

        model.revealAddedRow([
            StatusLink(title: "One", url: "https://one.example"),
            StatusLink(title: "Two", url: "https://two.example")
        ])
        XCTAssertFalse(model.reservesAddedRowSlot)
        XCTAssertEqual(model.links.count, 2)

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(model.isAddInFlight)
        model.add()
        XCTAssertEqual(addCount, 2)
    }

    func testHostingViewTracksRowCountHeightAndIdempotentTeardown() {
        let initialLinks = [
            StatusLink(title: "One", url: "https://one.example"),
            StatusLink(title: "Two", url: "https://two.example")
        ]
        let editor = StatusLinksEditorHostingView(
            links: initialLinks,
            onChange: { _, _, _ in },
            onAdd: {},
            onRemove: { _ in },
            onReset: {}
        )

        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.layoutHeight, 182, accuracy: 0.001)
        XCTAssertFalse(editor.isTornDown)

        let shorterLinks = [StatusLink(title: "Only", url: "https://only.example")]
        var completionCount = 0
        editor.updateLinks(shorterLinks, animated: false) {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(editor.rowCount, 1)
        XCTAssertEqual(editor.layoutHeight, 147, accuracy: 0.001)

        editor.updateLinks([], animated: false)
        XCTAssertEqual(editor.rowCount, 0)
        XCTAssertEqual(editor.layoutHeight, 112, accuracy: 0.001)

        editor.teardown()
        editor.teardown()
        XCTAssertTrue(editor.isTornDown)
    }

    func testHostingViewCanBeTornDownAndReleasedAfterRepeatedRebuilds() {
        weak var releasedEditor: StatusLinksEditorHostingView?

        autoreleasepool {
            var editor: StatusLinksEditorHostingView? = StatusLinksEditorHostingView(
                links: [StatusLink(title: "One", url: "https://one.example")],
                onChange: { _, _, _ in },
                onAdd: {},
                onRemove: { _ in },
                onReset: {}
            )
            releasedEditor = editor
            editor?.updateLinks([], animated: false)
            editor?.teardown()
            editor?.teardown()
            editor = nil
        }

        XCTAssertNil(releasedEditor)
    }

    func testAddedRowReservesThenRevealsOneSlotWithoutRecreatingTheHostingView() {
        func waitForAnimation(_ condition: @escaping () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        let initialLinks = [StatusLink(title: "One", url: "https://one.example")]
        let addedLinks = initialLinks + [StatusLink(title: "Two", url: "https://two.example")]
        let editor = StatusLinksEditorHostingView(
            links: initialLinks,
            onChange: { _, _, _ in },
            onAdd: {},
            onRemove: { _ in },
            onReset: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
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
        window.layoutIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        let hostingView = editor.subviews.first

        editor.updateLinks(addedLinks, animated: true, revealAddedRowsAtCompletion: true)

        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.renderedRowCount, 1)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        waitForAnimation {
            editor.renderedRowCount == 2 && !editor.hasReservedAddedRowSlot
        }
        XCTAssertEqual(editor.renderedRowCount, 2)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        editor.updateLinks(initialLinks, animated: true)
        editor.setVisible(false, animated: true)
        editor.setVisible(true, animated: true)
        waitForAnimation {
            editor.rowCount == 1 && editor.renderedRowCount == 1 && editor.isVisible
        }

        XCTAssertEqual(editor.rowCount, 1)
        XCTAssertEqual(editor.renderedRowCount, 1)
        XCTAssertTrue(editor.isVisible)
        XCTAssertEqual(editor.subviews.count, 1)
        XCTAssertTrue(editor.subviews.first === hostingView)
    }

    func testRapidAddedRowUpdatesKeepOneReservedSlotAndIgnoreStaleCompletion() {
        func waitForAnimation(_ condition: @escaping () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        let first = [StatusLink(title: "One", url: "https://one.example")]
        let second = first + [StatusLink(title: "Two", url: "https://two.example")]
        let third = second + [StatusLink(title: "Three", url: "https://three.example")]
        let editor = StatusLinksEditorHostingView(
            links: first,
            onChange: { _, _, _ in },
            onAdd: { },
            onRemove: { _ in },
            onReset: { }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
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
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        let hostingView = editor.subviews.first
        editor.updateLinks(second, animated: true, revealAddedRowsAtCompletion: true)
        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.renderedRowCount, 1)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        // A second update supersedes the first completion. It must not reveal
        // an intermediate row or create a second expanding slot.
        editor.updateLinks(third, animated: true, revealAddedRowsAtCompletion: true)
        XCTAssertEqual(editor.rowCount, 3)
        XCTAssertEqual(editor.renderedRowCount, 1)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        waitForAnimation {
            editor.renderedRowCount == 3 && !editor.hasReservedAddedRowSlot
        }
        XCTAssertEqual(editor.renderedRowCount, 3)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.hostedContentIsWithinRevealBounds)
        XCTAssertEqual(editor.subviews.count, 1)
        XCTAssertTrue(editor.subviews.first === hostingView)
    }

    func testAddedRowKeepsCardEditorAndViewportAnchorsFixedDuringInsertion() {
        let initialLinks = [StatusLink(title: "One", url: "https://one.example")]
        let addedLinks = initialLinks + [StatusLink(title: "Two", url: "https://two.example")]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let page = StatusLinksFlippedView()
        let scrollView = NSScrollView()
        let documentView = StatusLinksFlippedView(frame: NSRect(x: 0, y: 0, width: 480, height: 900))
        let card = StatusLinksFlippedView()
        let rowsStack = NSStackView()
        let viewStatusRow = NSView()
        let editor = StatusLinksEditorHostingView(
            links: initialLinks,
            onChange: { _, _, _ in },
            onAdd: { },
            onRemove: { _ in },
            onReset: { }
        )

        page.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        viewStatusRow.translatesAutoresizingMaskIntoConstraints = false
        viewStatusRow.heightAnchor.constraint(equalToConstant: 62).isActive = true
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 0

        window.contentView = page
        page.addSubview(scrollView)
        scrollView.documentView = documentView
        documentView.addSubview(card)
        card.addSubview(rowsStack)
        rowsStack.addArrangedSubview(viewStatusRow)
        rowsStack.addArrangedSubview(editor)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: page.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            card.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 180),
            card.widthAnchor.constraint(equalToConstant: 440),
            card.heightAnchor.constraint(equalToConstant: 62 + editor.layoutHeight),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            viewStatusRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
            editor.widthAnchor.constraint(equalTo: rowsStack.widthAnchor)
        ])
        window.layoutIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }

        scrollView.contentView.bounds.origin.y = 100
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let controller = StatusLinksScrollAnchorController(
            dashboardProvider: { window },
            contentHostProvider: { page },
            sectionTitleProvider: { "Menu" },
            linksCountProvider: { addedLinks.count }
        )
        let position = controller.capture(captureLabel: "before add", operation: "add")
        let initialCardTop = card.convert(
            NSPoint(x: card.bounds.minX, y: card.bounds.minY),
            to: scrollView.contentView
        ).y
        let initialEditorTop = editor.convert(
            NSPoint(x: editor.bounds.minX, y: editor.bounds.maxY),
            to: scrollView.contentView
        ).y
        let initialViewportOffset = scrollView.contentView.bounds.origin.y

        XCTAssertTrue(controller.refreshEditorInPlace(
            links: addedLinks,
            scrollPosition: position,
            operation: "add"
        ))

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            let cardTop = card.convert(
                NSPoint(x: card.bounds.minX, y: card.bounds.minY),
                to: scrollView.contentView
            ).y
            let editorTop = editor.convert(
                NSPoint(x: editor.bounds.minX, y: editor.bounds.maxY),
                to: scrollView.contentView
            ).y
            XCTAssertEqual(cardTop, initialCardTop, accuracy: 0.5)
            XCTAssertEqual(editorTop, initialEditorTop, accuracy: 0.5)
            XCTAssertEqual(scrollView.contentView.bounds.origin.y, initialViewportOffset, accuracy: 0.5)
            XCTAssertEqual(editor.hostedContentTopInset, 0, accuracy: 0.5)
        }

        XCTAssertEqual(editor.rowCount, 2)
        XCTAssertEqual(editor.renderedRowCount, 2)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertEqual(card.frame.height, 62 + editor.layoutHeight, accuracy: 0.5)
        XCTAssertTrue(editor.hostedContentIsWithinRevealBounds)
    }

    func testScrollAnchorPreservesDistanceFromBottomAndRigidBounds() {
        let geometry = DashboardScrollGeometry(
            documentBounds: NSRect(x: 0, y: 20, width: 400, height: 500),
            viewportHeight: 120,
            isDocumentFlipped: true
        )

        XCTAssertEqual(geometry.maximumOffset, 380, accuracy: 0.001)
        XCTAssertEqual(
            StatusLinksScrollAnchor.visualOffsetPreservingDistanceFromBottom(
                80,
                geometry: geometry
            ),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusLinksScrollAnchor.visualOffsetPreservingDistanceFromBottom(
                -10,
                geometry: geometry
            ),
            380,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusLinksScrollAnchor.visualOffsetPreservingDistanceFromBottom(
                999,
                geometry: geometry
            ),
            0,
            accuracy: 0.001
        )

        let viewport = NSRect(x: 0, y: 10, width: 300, height: 100)
        XCTAssertTrue(StatusLinksScrollAnchor.isViewportYVisible(10, in: viewport))
        XCTAssertTrue(StatusLinksScrollAnchor.isViewportYVisible(101, in: viewport, tolerance: 1))
        XCTAssertFalse(StatusLinksScrollAnchor.isViewportYVisible(112, in: viewport, tolerance: 1))
    }

    func testActiveMaintenanceStopsWhenUserMovesDashboardBounds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let page = StatusLinksFlippedView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 280)
        )
        let scrollView = NSScrollView(frame: page.bounds)
        let clipView = DashboardClipView(frame: scrollView.bounds)
        let documentView = StatusLinksFlippedView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 900)
        )
        scrollView.contentView = clipView
        scrollView.documentView = documentView
        window.contentView = page
        page.addSubview(scrollView)
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        let controller = StatusLinksScrollAnchorController(
            dashboardProvider: { window },
            contentHostProvider: { page },
            sectionTitleProvider: { "Status Links" },
            linksCountProvider: { 0 }
        )
        let position = StatusLinksScrollPosition(
            operation: "remove",
            visibleDocumentOffset: 100,
            contentOriginY: clipView.bounds.origin.y,
            distanceFromBottom: 200,
            previousMaximumOffset: 620,
            bottomAnchorView: nil,
            bottomAnchorViewportY: nil
        )

        controller.startMaintenance(position, operation: "remove")
        XCTAssertTrue(controller.isMaintainingAnchor)

        let userOriginY = clipView.bounds.origin.y + 40
        clipView.setBoundsOrigin(
            NSPoint(x: clipView.bounds.minX, y: userOriginY)
        )
        XCTAssertFalse(controller.isMaintainingAnchor)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(clipView.bounds.origin.y, userOriginY, accuracy: 0.0001)

        controller.startMaintenance(position, operation: "remove")
        XCTAssertTrue(controller.isMaintainingAnchor)
        let secondUserOriginY = clipView.bounds.origin.y + 40
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: secondUserOriginY)
        )
        XCTAssertFalse(controller.isMaintainingAnchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(clipView.bounds.origin.y, secondUserOriginY, accuracy: 0.0001)
    }

    func testScrollAnchorControllerCancelsTransactionAndReleasesAfterTeardown() {
        weak var releasedController: StatusLinksScrollAnchorController?

        autoreleasepool {
            var controller: StatusLinksScrollAnchorController? =
                StatusLinksScrollAnchorController(
                    dashboardProvider: { nil },
                    contentHostProvider: { nil },
                    sectionTitleProvider: { "Menu" },
                    linksCountProvider: { 0 }
                )
            releasedController = controller
            XCTAssertFalse(controller?.isMaintainingAnchor == true)
            controller?.stop()
            XCTAssertFalse(controller?.isMaintainingAnchor == true)
            controller = nil
        }

        XCTAssertNil(releasedController)
    }
}
