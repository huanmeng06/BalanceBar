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
            NSWindow.self,
            original: #selector(NSWindow.makeKeyAndOrderFront(_:)),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_makeKeyAndOrderFront(_:))
        )
        swizzle(
            NSWindow.self,
            original: #selector(NSWindow.makeKey),
            swizzled: #selector(NSWindow.balanceBar_automatedTest_makeKey)
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
    private static let offscreenOrigin = NSPoint(x: -10_000, y: -10_000)

    static func present(_ window: NSWindow) {
        if AutomatedTestHost.isRunning {
            presentInBackground(window)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func presentInBackground(_ window: NSWindow) {
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.formUnion([.transient, .ignoresCycle, .stationary])
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        // Connect the window to the window server for layout and Core Animation
        // without activating the test host or covering the user's frontmost app.
        // AppKit may clamp off-screen frames during orderFront, so park the
        // window after it is on the window server, then send it behind so it
        // cannot become the key window for input methods.
        window.orderFrontRegardless()
        window.setFrameOrigin(offscreenOrigin)
        window.orderBack(nil)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        AutomatedTestHost.becomeBackgroundHost()
    }
}

private extension NSApplication {
    @objc func balanceBar_automatedTest_activateIgnoringOtherApps(_ flag: Bool) {
        // Tests must not steal the user's frontmost app or input method.
    }

    @objc func balanceBar_automatedTest_activate() {
        // Tests must not steal the user's frontmost app or input method.
    }
}

private extension NSWindow {
    @objc func balanceBar_automatedTest_makeKeyAndOrderFront(_ sender: Any?) {
        ApplicationWindowPresentation.presentInBackground(self)
    }

    @objc func balanceBar_automatedTest_makeKey() {
        // Becoming key steals IME composition from the user's frontmost app.
    }
}
