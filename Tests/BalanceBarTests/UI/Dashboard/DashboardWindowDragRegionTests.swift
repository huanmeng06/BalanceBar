import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowDragRegionTests: XCTestCase {
    func testDashboardWindowControllerRetiresCustomTitlebarDragAndZoom() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("struct DashboardWindowDragRegion"))
        XCTAssertFalse(source.contains("struct DashboardWindowZoomState"))
        XCTAssertFalse(source.contains("class DashboardTitlebarDragView"))
        XCTAssertFalse(source.contains("enum DashboardWindowDragPolicy"))
        XCTAssertFalse(source.contains("func toggleWindowZoom()"))
        XCTAssertFalse(source.contains("savedNormalFrame"))
        XCTAssertFalse(source.contains("DashboardWindowDragPolicy.install"))
        XCTAssertFalse(source.contains("standardWindowButton(.zoomButton)?.isEnabled = false"))
        XCTAssertTrue(source.contains("override var mouseDownCanMoveWindow: Bool { false }"))
        XCTAssertTrue(source.contains("isMovableByWindowBackground = false"))
        XCTAssertTrue(source.contains("private func makeSidebar(titlebarHeight: CGFloat) -> NSView {"))
    }

    func testWindowEnablesNativeZoomWithoutFullWindowDragOverlay() throws {
        let controller = DashboardWindowController(
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
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let contentView = try XCTUnwrap(window.contentView)
        let zoomButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))

        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertTrue(contentView is DashboardContentRootView)
        XCTAssertFalse(contentView.mouseDownCanMoveWindow)
        XCTAssertTrue(zoomButton.isEnabled)
        XCTAssertFalse(zoomButton.isHidden)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))

        let splitController = try XCTUnwrap(window.contentViewController as? DashboardSplitViewController)
        XCTAssertEqual(contentView.subviews, [splitController.contentSurface, splitController.splitView])
    }
}
