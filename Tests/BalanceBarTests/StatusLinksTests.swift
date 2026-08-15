import AppKit
import XCTest
@testable import BalanceBar

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
        XCTAssertTrue(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        RunLoop.current.run(until: Date().addingTimeInterval(0.30))
        XCTAssertEqual(editor.renderedRowCount, 2)
        XCTAssertFalse(editor.hasReservedAddedRowSlot)
        XCTAssertTrue(editor.subviews.first === hostingView)

        editor.updateLinks(initialLinks, animated: true)
        editor.setVisible(false, animated: true)
        editor.setVisible(true, animated: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.30))

        XCTAssertEqual(editor.rowCount, 1)
        XCTAssertEqual(editor.renderedRowCount, 1)
        XCTAssertTrue(editor.isVisible)
        XCTAssertEqual(editor.subviews.count, 1)
        XCTAssertTrue(editor.subviews.first === hostingView)
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

    func testScrollAnchorTimerSupportsRepeatedStartStopWithoutDuplicateMaintenance() {
        let timer = StatusLinksScrollAnchorTimer()
        var firstTickCount = 0
        var secondTickCount = 0

        timer.start(interval: 0.01) {
            firstTickCount += 1
        }
        XCTAssertTrue(timer.isRunning)

        timer.start(interval: 0.01) {
            secondTickCount += 1
        }
        XCTAssertTrue(timer.isRunning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        timer.stop()

        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(firstTickCount, 0)
        XCTAssertGreaterThan(secondTickCount, 0)

        timer.stop()
        XCTAssertFalse(timer.isRunning)
    }

    func testScrollAnchorControllerStopsTimerAndReleasesAfterTeardown() {
        let position = StatusLinksScrollPosition(
            operation: "remove",
            visibleDocumentOffset: 40,
            contentOriginY: 40,
            distanceFromBottom: 60,
            previousMaximumOffset: 120,
            bottomAnchorView: nil,
            bottomAnchorViewportY: nil
        )
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
            controller?.startMaintenance(position, operation: "remove")
            XCTAssertTrue(controller?.isMaintainingAnchor == true)
            controller?.startMaintenance(position, operation: "remove")
            XCTAssertTrue(controller?.isMaintainingAnchor == true)
            controller?.stop()
            XCTAssertFalse(controller?.isMaintainingAnchor == true)
            controller = nil
        }

        XCTAssertNil(releasedController)
    }
}
