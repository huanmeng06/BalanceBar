import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardSidebarChromeBaselineTests: XCTestCase {
    func testStoreKeepsWindowedAndFullscreenBaselinesIndependentOfTitlebarAccessory() {
        var store = DashboardSidebarChromeBaseline.Store()
        let windowedNone: CGFloat = 52
        let accessory: CGFloat = 36
        let fullscreenNone: CGFloat = 28

        let windowedInset = store.resolvedSourceListTopInset(
            isFullScreen: false,
            liveChromeHeight: windowedNone,
            titlebarAccessoryHeight: 0
        )
        XCTAssertEqual(
            windowedInset,
            DashboardSidebarChromeBaseline.sourceListTopInset(stableChromeHeight: windowedNone)
        )
        XCTAssertEqual(store.windowedStableChromeHeightForTesting, windowedNone)

        let windowedWithAccessory = store.resolvedSourceListTopInset(
            isFullScreen: false,
            liveChromeHeight: windowedNone + accessory,
            titlebarAccessoryHeight: accessory
        )
        XCTAssertEqual(windowedWithAccessory, windowedInset)
        XCTAssertEqual(store.windowedStableChromeHeightForTesting, windowedNone)

        let fullscreenInset = store.resolvedSourceListTopInset(
            isFullScreen: true,
            liveChromeHeight: fullscreenNone,
            titlebarAccessoryHeight: 0
        )
        XCTAssertEqual(
            fullscreenInset,
            DashboardSidebarChromeBaseline.sourceListTopInset(stableChromeHeight: fullscreenNone)
        )
        XCTAssertEqual(store.fullscreenStableChromeHeightForTesting, fullscreenNone)
        XCTAssertNotEqual(fullscreenInset, windowedInset)

        let fullscreenWithAccessory = store.resolvedSourceListTopInset(
            isFullScreen: true,
            liveChromeHeight: fullscreenNone + accessory,
            titlebarAccessoryHeight: accessory
        )
        XCTAssertEqual(fullscreenWithAccessory, fullscreenInset)
        XCTAssertEqual(store.fullscreenStableChromeHeightForTesting, fullscreenNone)

        let restoredWindowed = store.resolvedSourceListTopInset(
            isFullScreen: false,
            liveChromeHeight: windowedNone + accessory,
            titlebarAccessoryHeight: accessory
        )
        XCTAssertEqual(restoredWindowed, windowedInset)
        XCTAssertEqual(store.windowedStableChromeHeightForTesting, windowedNone)
    }

    func testFirstFullscreenCaptureWithAccessoryStillExcludesAccessoryHeight() {
        var store = DashboardSidebarChromeBaseline.Store()
        let fullscreenNone: CGFloat = 30
        let accessory: CGFloat = 36

        let withAccessory = store.resolvedSourceListTopInset(
            isFullScreen: true,
            liveChromeHeight: fullscreenNone + accessory,
            titlebarAccessoryHeight: accessory
        )
        XCTAssertEqual(
            withAccessory,
            DashboardSidebarChromeBaseline.sourceListTopInset(stableChromeHeight: fullscreenNone)
        )

        let withoutAccessory = store.resolvedSourceListTopInset(
            isFullScreen: true,
            liveChromeHeight: fullscreenNone,
            titlebarAccessoryHeight: 0
        )
        XCTAssertEqual(withoutAccessory, withAccessory)
    }

    func testContentSplitAccessoryDoesNotChangeStableChromeHeight() {
        let live: CGFloat = 52
        XCTAssertEqual(
            DashboardSidebarChromeBaseline.stableChromeHeight(
                liveChromeHeight: live,
                titlebarAccessoryHeight: 0
            ),
            live
        )
    }

    func testLiveWindowMeasurementSubtractsTitlebarAccessoryFromStableChrome() throws {
        let harness = DashboardAccessoryHarnessController()
        defer { harness.teardown() }
        harness.present()
        let controller = try XCTUnwrap(harness.windowControllerForTesting)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let none = DashboardSidebarChromeBaseline.measurement(in: window)
        XCTAssertFalse(none.isFullScreen)
        XCTAssertEqual(none.titlebarAccessoryHeight, 0, accuracy: 0.5)
        XCTAssertEqual(none.stableChromeHeight, none.liveChromeHeight, accuracy: 0.5)

        controller.showSection(.menuBar)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let titlebar = DashboardSidebarChromeBaseline.measurement(in: window)
        XCTAssertGreaterThan(titlebar.titlebarAccessoryHeight, 0)
        XCTAssertGreaterThan(titlebar.liveChromeHeight, none.liveChromeHeight)
        XCTAssertEqual(
            titlebar.stableChromeHeight,
            none.stableChromeHeight,
            accuracy: 2,
            "Temporary titlebar accessory must not change the accessory-free chrome: none=\(none) titlebar=\(titlebar)"
        )
        XCTAssertLessThan(
            abs(titlebar.stableChromeHeight - none.stableChromeHeight),
            abs(titlebar.liveChromeHeight - none.stableChromeHeight)
        )

        controller.showSection(.menu)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let split = DashboardSidebarChromeBaseline.measurement(in: window)
        XCTAssertEqual(split.titlebarAccessoryHeight, 0, accuracy: 0.5)
        XCTAssertEqual(
            split.stableChromeHeight,
            none.stableChromeHeight,
            accuracy: 1,
            "Content split accessory must not change the sidebar chrome baseline: none=\(none) split=\(split)"
        )
        XCTAssertEqual(split.liveChromeHeight, none.liveChromeHeight, accuracy: 1)

        var store = DashboardSidebarChromeBaseline.Store()
        let windowedInset = store.resolvedSourceListTopInset(
            isFullScreen: false,
            liveChromeHeight: none.liveChromeHeight,
            titlebarAccessoryHeight: none.titlebarAccessoryHeight
        )
        XCTAssertEqual(
            store.resolvedSourceListTopInset(
                isFullScreen: false,
                liveChromeHeight: titlebar.liveChromeHeight,
                titlebarAccessoryHeight: titlebar.titlebarAccessoryHeight
            ),
            windowedInset
        )

        let fullscreenNoneChrome: CGFloat = none.liveChromeHeight == 28 ? 52 : 28
        let fullscreenInset = store.resolvedSourceListTopInset(
            isFullScreen: true,
            liveChromeHeight: fullscreenNoneChrome,
            titlebarAccessoryHeight: 0
        )
        XCTAssertEqual(
            store.resolvedSourceListTopInset(
                isFullScreen: true,
                liveChromeHeight: fullscreenNoneChrome + titlebar.titlebarAccessoryHeight,
                titlebarAccessoryHeight: titlebar.titlebarAccessoryHeight
            ),
            fullscreenInset
        )
        XCTAssertNotEqual(fullscreenInset, windowedInset)
        XCTAssertEqual(
            store.resolvedSourceListTopInset(
                isFullScreen: false,
                liveChromeHeight: titlebar.liveChromeHeight,
                titlebarAccessoryHeight: titlebar.titlebarAccessoryHeight
            ),
            windowedInset
        )
    }

    func testBaselineHelperStaysOnPublicGeometryAndLeavesAccessoryHostAlone() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardSidebarChromeBaseline.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("titlebarAccessoryViewControllers"))
        XCTAssertTrue(source.contains("contentLayoutRect"))
        XCTAssertTrue(source.contains("sourceListPadding"))
        XCTAssertFalse(source.contains("DashboardAccessoryHost"))
        XCTAssertFalse(source.contains("DashboardSourceList"))
        XCTAssertFalse(source.contains("outlineView"))
        XCTAssertFalse(source.contains("hitTest"))
        XCTAssertFalse(source.contains("contentLayoutGuide"))
        XCTAssertFalse(source.contains("setValue("))
        XCTAssertFalse(source.contains("forKey:"))
        XCTAssertFalse(source.contains("NSClassFromString"))
        XCTAssertFalse(source.contains("value(forKey"))
        XCTAssertFalse(source.contains("perform(NSSelectorFromString"))
    }
}
