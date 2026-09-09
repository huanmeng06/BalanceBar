import AppKit
import Foundation
import ObjectiveC

enum AutomatedTestHost {
    static var isRunning: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// Switch the XCTest host to an agent before any window is created, and
    /// keep it from becoming the active app if a later presentation tries.
    static func becomeBackgroundHost() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        installSwizzles()
        ApplicationWindowPresentation.parkVisibleWindows()
        if app.isActive {
            app.deactivate()
        }
    }

    private static var didSwizzle = false

    private static func installSwizzles() {
        guard !didSwizzle else { return }
        didSwizzle = true
        swizzle(
            NSApplication.self,
            original: #selector(NSApplication.activate(ignoringOtherApps:)),
            swizzled: #selector(NSApplication.balanceBar_automatedTest_activateIgnoringOtherApps(_:))
        )
        swizzle(
            NSApplication.self,
            original: NSSelectorFromString("activate"),
            swizzled: #selector(NSApplication.balanceBar_automatedTest_activate)
        )
        swizzle(
            NSApplication.self,
            original: #selector(NSApplication.setActivationPolicy(_:)),
            swizzled: #selector(NSApplication.balanceBar_automatedTest_setActivationPolicy(_:))
        )
        swizzle(
            NSWindow.self,
            original: #selector(NSWindow.makeKeyAndOrderFront(_:)),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_makeKeyAndOrderFront(_:))
        )
        swizzle(
            NSWindow.self,
            original: #selector(NSWindow.makeKey),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_makeKey)
        )
        swizzle(
            NSWindow.self,
            original: #selector(NSWindow.orderFront(_:)),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_orderFront(_:))
        )
        swizzle(
            NSWindow.self,
            original: #selector(NSWindow.orderFrontRegardless),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_orderFrontRegardless)
        )
    }

    private static func swizzle(_ cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let swizzledMethod = class_getInstanceMethod(cls, swizzled)
        else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

enum ApplicationWindowPresentation {
    fileprivate static let offscreenOrigin = NSPoint(x: -10_000, y: -10_000)
    fileprivate static let backgroundLevel = NSWindow.Level(
        rawValue: NSWindow.Level.normal.rawValue - 1_000
    )
    fileprivate static var isParking = false

    static func present(_ window: NSWindow) {
        if AutomatedTestHost.isRunning {
            presentInBackground(window)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func presentInBackground(_ window: NSWindow) {
        park(window)
    }

    static func prepare(_ window: NSWindow) {
        guard AutomatedTestHost.isRunning else { return }
        applyBackgroundAppearance(window)
        window.setFrameOrigin(offscreenOrigin)
    }

    static func parkVisibleWindows() {
        guard AutomatedTestHost.isRunning else { return }
        for window in NSApp.windows where window.level != .statusBar && window.isVisible {
            park(window)
        }
    }

    fileprivate static func park(_ window: NSWindow) {
        guard !isParking else { return }
        isParking = true
        defer { isParking = false }

        applyBackgroundAppearance(window)
        // Connect to the window server with same-app `orderFront` only when the
        // window is not already visible. `orderFrontRegardless` stacks above
        // every other application; calling it again from `testCaseWillStart`
        // would re-cover the user's frontmost window.
        if !window.isVisible {
            window.orderFront(nil)
        }
        window.setFrameOrigin(offscreenOrigin)
        window.level = backgroundLevel
        window.orderBack(nil)
        applyBackgroundAppearance(window)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        applyBackgroundAppearance(window)
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    fileprivate static func applyBackgroundAppearance(_ window: NSWindow) {
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.formUnion([.transient, .ignoresCycle, .stationary])
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.alphaValue = 0
        window.level = backgroundLevel
    }
}

private extension NSApplication {
    @objc func balanceBar_automatedTest_activateIgnoringOtherApps(_ flag: Bool) {
        // Tests must not steal the user's frontmost app or input method.
    }

    @objc func balanceBar_automatedTest_activate() {
        // Tests must not steal the user's frontmost app or input method.
    }

    @objc func balanceBar_automatedTest_setActivationPolicy(
        _ policy: NSApplication.ActivationPolicy
    ) -> Bool {
        // `.regular` puts the host in the menu bar and lets it become the
        // frontmost app. Keep the XCTest host as an accessory.
        let resolved = policy == .regular ? NSApplication.ActivationPolicy.accessory : policy
        return balanceBar_automatedTest_setActivationPolicy(resolved)
    }
}

private extension NSWindow {
    @objc func balanceBar_automatedTest_makeKeyAndOrderFront(_ sender: Any?) {
        ApplicationWindowPresentation.presentInBackground(self)
    }

    @objc func balanceBar_automatedTest_makeKey() {
        // Becoming key steals IME composition from the user's frontmost app.
    }

    @objc func balanceBar_automatedTest_orderFront(_ sender: Any?) {
        if ApplicationWindowPresentation.isParking {
            balanceBar_automatedTest_orderFront(sender)
            return
        }
        ApplicationWindowPresentation.presentInBackground(self)
    }

    @objc func balanceBar_automatedTest_orderFrontRegardless() {
        ApplicationWindowPresentation.presentInBackground(self)
    }
}
