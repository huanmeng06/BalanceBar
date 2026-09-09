import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class AutomatedTestHostTests: XCTestCase {
    func testHostIsDetectedWhenXCTestConfigurationIsPresent() {
        XCTAssertTrue(AutomatedTestHost.isRunning)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
    }

    func testBackgroundPresentationParksWindowOffScreenWithoutRegularPolicy() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 80, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        ApplicationWindowPresentation.present(window)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    func testDashboardOpenStaysOffScreenDuringAutomatedTests() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
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
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.ignoresMouseEvents)
    }
}
