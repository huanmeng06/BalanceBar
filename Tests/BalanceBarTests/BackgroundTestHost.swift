import AppKit
import ObjectiveC
import XCTest

/// Keeps the XCTest host from becoming a regular, frontmost app while tests run.
private final class BackgroundTestHostObserver: NSObject, XCTestObservation {
    func testBundleWillStart(_ testBundle: Bundle) {
        _ = backgroundTestHostInstalled
        BackgroundTestHost.install()
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        BackgroundTestHost.keepHostInBackground()
    }
}

private enum BackgroundTestHost {
    private static let observer = BackgroundTestHostObserver()
    private static var didInstall = false

    static func install() {
        guard !didInstall else {
            keepHostInBackground()
            return
        }
        didInstall = true
        XCTestObservationCenter.shared.addTestObserver(observer)
        swizzleActivation()
        keepHostInBackground()
    }

    static func keepHostInBackground() {
        _ = NSApp.setActivationPolicy(.accessory)
    }

    private static func swizzleActivation() {
        swizzle(
            NSApplication.self,
            original: #selector(NSApplication.activate(ignoringOtherApps:)),
            swizzled: #selector(NSApplication.balanceBar_testHost_activateIgnoringOtherApps(_:))
        )
        swizzle(
            NSApplication.self,
            original: NSSelectorFromString("activate"),
            swizzled: #selector(NSApplication.balanceBar_testHost_activate)
        )
    }

    private static func swizzle(_ cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let swizzledMethod = class_getInstanceMethod(cls, swizzled)
        else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

private extension NSApplication {
    @objc func balanceBar_testHost_activateIgnoringOtherApps(_ flag: Bool) {
        // Tests must not steal the user's frontmost app.
    }

    @objc func balanceBar_testHost_activate() {
        // Tests must not steal the user's frontmost app.
    }
}

private let backgroundTestHostInstalled: Void = BackgroundTestHost.install()
