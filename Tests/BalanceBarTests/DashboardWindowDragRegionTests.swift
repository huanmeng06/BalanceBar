import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowDragRegionTests: XCTestCase {
    func testRegionIncludesOnlyTheTopTitlebarBand() {
        let region = DashboardWindowDragRegion(
            bounds: NSRect(x: 0, y: 0, width: 880, height: 620),
            titlebarHeight: 52,
            excludedRects: []
        )

        XCTAssertEqual(region.frame, NSRect(x: 0, y: 568, width: 880, height: 52))
        XCTAssertTrue(region.contains(NSPoint(x: 440, y: 600)))
        XCTAssertFalse(region.contains(NSPoint(x: 100, y: 500)), "Sidebar content must not move the window")
        XCTAssertFalse(region.contains(NSPoint(x: 500, y: 420)), "Card gaps must not move the window")
        XCTAssertFalse(region.contains(NSPoint(x: 700, y: 180)), "Scroll and log backgrounds must not move the window")
    }

    func testRegionExcludesStandardWindowButtons() {
        let excludedRects = [
            NSRect(x: 19, y: 587, width: 14, height: 14),
            NSRect(x: 42, y: 587, width: 14, height: 14),
            NSRect(x: 65, y: 587, width: 14, height: 14)
        ]
        let region = DashboardWindowDragRegion(
            bounds: NSRect(x: 0, y: 0, width: 880, height: 620),
            titlebarHeight: 52,
            excludedRects: excludedRects
        )

        for rect in excludedRects {
            XCTAssertFalse(region.contains(NSPoint(x: rect.midX, y: rect.midY)))
        }
        XCTAssertTrue(region.contains(NSPoint(x: 100, y: 594)))
    }

    func testRegionTracksResizedWindowBounds() {
        let region = DashboardWindowDragRegion(
            bounds: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            titlebarHeight: 52,
            excludedRects: []
        )

        XCTAssertEqual(region.frame, NSRect(x: 0, y: 748, width: 1_200, height: 52))
        XCTAssertTrue(region.contains(NSPoint(x: 1_190, y: 790)))
        XCTAssertFalse(region.contains(NSPoint(x: 1_190, y: 700)))
        XCTAssertFalse(region.contains(NSPoint(x: 1_210, y: 790)))
    }

    func testInstalledPolicyDisablesBackgroundDraggingAndPreservesNativeControls() {
        let (window, root, dragView) = makeWindow()
        guard let frameView = root.superview else {
            return XCTFail("Expected AppKit window frame view")
        }

        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertFalse(root.mouseDownCanMoveWindow)
        XCTAssertTrue(dragView.mouseDownCanMoveWindow)

        let topPointInFrameView = root.convert(
            NSPoint(x: root.bounds.midX, y: root.bounds.maxY - 8),
            to: frameView
        )
        let topPoint = frameView.convert(topPointInFrameView, to: frameView.superview)
        let topHitView = frameView.hitTest(topPoint)
        XCTAssertTrue(
            topHitView === dragView,
            "Expected titlebar drag view; got \(String(describing: topHitView)), "
                + "window=\(window.frame), contentLayout=\(window.contentLayoutRect), "
                + "rootFrame=\(root.frame), rootBounds=\(root.bounds), "
                + "dragFrame=\(dragView.frame), dragBounds=\(dragView.bounds), "
                + "frameFrame=\(frameView.frame), frameBounds=\(frameView.bounds), "
                + "rootPoint=\(NSPoint(x: root.bounds.midX, y: root.bounds.maxY - 8)), "
                + "framePoint=\(topPointInFrameView), hitTestPoint=\(topPoint)"
        )

        let sidebarPointInFrameView = root.convert(
            NSPoint(x: 100, y: root.bounds.midY),
            to: frameView
        )
        let cardGapPointInFrameView = root.convert(
            NSPoint(x: 500, y: root.bounds.midY),
            to: frameView
        )
        let sidebarPoint = frameView.convert(sidebarPointInFrameView, to: frameView.superview)
        let cardGapPoint = frameView.convert(cardGapPointInFrameView, to: frameView.superview)
        XCTAssertTrue(frameView.hitTest(sidebarPoint) === root)
        XCTAssertTrue(frameView.hitTest(cardGapPoint) === root)

        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else {
                return XCTFail("Missing standard window button \(type.rawValue)")
            }
            let buttonPointInFrameView = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                to: frameView
            )
            let buttonPoint = frameView.convert(buttonPointInFrameView, to: frameView.superview)
            XCTAssertTrue(frameView.hitTest(buttonPoint) === button)
        }
    }

    func testInstalledPolicyUpdatesItsHitRegionAfterResize() {
        let (window, root, dragView) = makeWindow()
        window.setFrame(NSRect(x: 0, y: 0, width: 1_120, height: 720), display: false)
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        guard let frameView = root.superview else {
            return XCTFail("Expected AppKit window frame view")
        }
        let resizeEdgePointInFrameView = root.convert(
            NSPoint(x: root.bounds.maxX - 10, y: root.bounds.maxY - 8),
            to: frameView
        )
        let resizedTopPointInFrameView = root.convert(
            NSPoint(x: root.bounds.maxX - 40, y: root.bounds.maxY - 8),
            to: frameView
        )
        let resizedContentPointInFrameView = root.convert(
            NSPoint(x: root.bounds.maxX - 40, y: root.bounds.midY),
            to: frameView
        )
        let resizeEdgePoint = frameView.convert(resizeEdgePointInFrameView, to: frameView.superview)
        let resizedTopPoint = frameView.convert(resizedTopPointInFrameView, to: frameView.superview)
        let resizedContentPoint = frameView.convert(resizedContentPointInFrameView, to: frameView.superview)
        XCTAssertFalse(frameView.hitTest(resizeEdgePoint) === dragView)
        let resizedTopHitView = frameView.hitTest(resizedTopPoint)
        XCTAssertTrue(
            resizedTopHitView === dragView,
            "Expected resized titlebar drag view; got \(String(describing: resizedTopHitView)), "
                + "window=\(window.frame), contentLayout=\(window.contentLayoutRect), "
                + "rootFrame=\(root.frame), rootBounds=\(root.bounds), "
                + "dragFrame=\(dragView.frame), dragBounds=\(dragView.bounds), "
                + "frameFrame=\(frameView.frame), frameBounds=\(frameView.bounds), "
                + "framePoint=\(resizedTopPointInFrameView), hitTestPoint=\(resizedTopPoint)"
        )
        XCTAssertTrue(frameView.hitTest(resizedContentPoint) === root)
    }

    private func makeWindow() -> (
        window: NSWindow,
        root: DashboardContentRootView,
        dragView: DashboardTitlebarDragView
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "DashboardWindowDragRegionTests")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let root = DashboardContentRootView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        let dragView = DashboardWindowDragPolicy.install(in: window, contentRoot: root)
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        return (window, root, dragView)
    }
}
