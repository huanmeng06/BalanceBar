import AppKit
import Foundation

enum AutomatedTestHost {
    static var isRunning: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
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
        // window after it is on the window server.
        window.orderFrontRegardless()
        window.setFrameOrigin(offscreenOrigin)
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }
}
