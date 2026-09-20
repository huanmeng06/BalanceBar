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
        XCTAssertTrue(source.contains("override func hitTest(_ point: NSPoint) -> NSView?"))
        XCTAssertTrue(source.contains("isMovableByWindowBackground = false"))
        XCTAssertTrue(source.contains("private func makeSidebar("))
        XCTAssertTrue(
            source.contains("layoutPolicy: DashboardSidebarScrollLayoutPolicy = .current")
        )
        XCTAssertFalse(source.contains("sidebarInteractiveViews"))
        XCTAssertTrue(source.contains("contentLayoutRect"))
        XCTAssertFalse(source.contains("equalTo: contentLayoutGuide.topAnchor"))
        XCTAssertFalse(source.contains("onDoubleClick"))
        XCTAssertFalse(source.contains("root.layer?.cornerRadius"))
        XCTAssertFalse(source.contains("root.wantsLayer = true"))
        XCTAssertFalse(source.contains("cornerRadius = 16"))
        XCTAssertFalse(source.contains("private(set) var contentSurface"))
        XCTAssertTrue(source.contains("legacyContentSurface"))
        XCTAssertTrue(source.contains("installLegacyCompatibilitySurface"))
        XCTAssertTrue(source.contains("func makeDashboardGlassEffectView"))
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
        if #available(macOS 26.0, *) {
            XCTAssertEqual(contentView.subviews, [splitController.splitView])
            XCTAssertNil(splitController.legacyContentSurface)
            XCTAssertNil(splitController.legacyBackdrop)
            XCTAssertEqual(contentView.layer?.cornerRadius ?? 0, 0)
        } else {
            let surface = try XCTUnwrap(splitController.legacyContentSurface)
            XCTAssertEqual(
                contentView.subviews,
                [try XCTUnwrap(splitController.legacyBackdrop), surface, splitController.splitView]
            )
            XCTAssertFalse(surface.isHidden)
            XCTAssertEqual(contentView.layer?.cornerRadius ?? 0, 0)
        }
    }

    func testContentRootPassesTitlebarHitsThroughForNativeDoubleClick() throws {
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
        let contentView = try XCTUnwrap(window.contentView as? DashboardContentRootView)
        let frameView = try XCTUnwrap(contentView.superview)
        let layoutRect = window.contentLayoutRect
        let topInWindow = contentView.convert(
            NSPoint(x: contentView.bounds.midX, y: contentView.bounds.maxY),
            to: nil
        )
        XCTAssertGreaterThan(
            topInWindow.y - layoutRect.maxY,
            1,
            "Native titlebar/toolbar band is required for AppleActionOnDoubleClick"
        )

        let titlebarInSelf = contentView.convert(
            NSPoint(x: layoutRect.midX, y: (layoutRect.maxY + topInWindow.y) / 2),
            from: nil
        )
        let titlebarInSuperview = contentView.convert(titlebarInSelf, to: frameView)
        XCTAssertNil(
            contentView.hitTest(titlebarInSuperview),
            "Titlebar hits must reach NSThemeFrame so the system double-click action can run"
        )

        let contentInSelf = contentView.convert(
            NSPoint(x: layoutRect.midX, y: layoutRect.midY),
            from: nil
        )
        let contentInSuperview = contentView.convert(contentInSelf, to: frameView)
        XCTAssertNotNil(contentView.hitTest(contentInSuperview))
        XCTAssertFalse(contentView.mouseDownCanMoveWindow)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let buttonPoint = closeButton.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            to: frameView
        )
        XCTAssertNil(contentView.hitTest(buttonPoint))
    }
}
