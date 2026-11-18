import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class AutomatedTestHostTests: XCTestCase {
    func testHostIsDetectedWhenXCTestConfigurationIsPresent() {
        XCTAssertTrue(AutomatedTestHost.isRunning)
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
    }

    /// The host shares the installed app's bundle identifier; tests must never read or
    /// write the user's real preferences through `UserDefaults.standard`.
    func testStandardDefaultsAreIsolatedFromInstalledAppDomain() throws {
        let key = "balanceBar.xctestHostIsolationProbe"
        let suiteName = AutomatedTestHost.isolatedDefaultsSuiteName
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("probe", forKey: key)
        XCTAssertEqual(isolated.string(forKey: key), "probe")
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertNil(CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString))
        XCTAssertNotNil(CFPreferencesCopyAppValue(key as CFString, suiteName as CFString))
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
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testOrderFrontRegardlessDoesNotLeaveOpaqueCoveringWindow() {
        _ = NSApplication.shared
        AutomatedTestHost.becomeBackgroundHost()
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        window.alphaValue = 1
        window.hasShadow = true
        window.orderFrontRegardless()

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.hasShadow)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(NSApp.isActive)
    }

    func testOrderFrontDoesNotLeaveOpaqueCoveringWindow() {
        _ = NSApplication.shared
        AutomatedTestHost.becomeBackgroundHost()
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 80, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        window.alphaValue = 1
        window.orderFront(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(NSApp.isActive)
    }

    func testReparkingVisibleWindowDoesNotForceItAboveOtherApps() {
        _ = NSApplication.shared
        AutomatedTestHost.becomeBackgroundHost()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 80, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        ApplicationWindowPresentation.present(window)
        window.alphaValue = 1
        window.level = .normal
        AutomatedTestHost.becomeBackgroundHost()

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    func testRegularActivationPolicyStaysAccessoryDuringTests() {
        AutomatedTestHost.becomeBackgroundHost()
        _ = NSApp.setActivationPolicy(.regular)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(NSApp.isActive)
    }

    func testBackgroundHostStaysAccessoryAndInactive() {
        AutomatedTestHost.becomeBackgroundHost()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(NSApp.isActive)
    }

    func testHostInfoPlistDoesNotActivateOnLaunch() {
        let uiElement = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber
        XCTAssertEqual(uiElement?.boolValue, true)
        let multipleInstancesProhibited = Bundle.main.object(
            forInfoDictionaryKey: "LSMultipleInstancesProhibited"
        ) as? NSNumber
        XCTAssertEqual(multipleInstancesProhibited?.boolValue, false)
    }

    func testDashboardOpenStaysOffScreenDuringAutomatedTests() throws {
        let controller = DashboardShellTestHarness(
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
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        controller.showSection(.menu)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        controller.rebuild()
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(NSApp.isActive)
    }
}

/// XCTest runs a class's cases in name order: case 1 leaves a language behind on purpose,
/// case 2 proves the bundle observer put it back before the next case started.
final class AutomatedTestHostLanguageRestoreTests: XCTestCase {
    private static var languageBeforeLeak: AppLanguage?

    func testObserverIsRegisteredByTestBundlePrincipal() {
        XCTAssertTrue(BackgroundTestHost.isInstalled)
        XCTAssertEqual(Bundle(for: Self.self).infoDictionary?["NSPrincipalClass"] as? String, "BalanceBarTestPrincipal")
    }

    func testRestore1_LeavesLanguageChanged() {
        Self.languageBeforeLeak = AppLanguage.selected
        let leaked: AppLanguage = AppLanguage.selected == .german ? .japanese : .german
        AppLanguage.selected = leaked
        XCTAssertEqual(AppLanguage.selected, leaked)
    }

    func testRestore2_NextCaseSeesOriginalLanguage() throws {
        guard let expected = Self.languageBeforeLeak else {
            throw XCTSkip("runs only after testRestore1_LeavesLanguageChanged")
        }
        XCTAssertEqual(AppLanguage.selected, expected)
    }
}
