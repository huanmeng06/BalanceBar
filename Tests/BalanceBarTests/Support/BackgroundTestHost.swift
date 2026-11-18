import XCTest
@testable import BalanceBar

/// Re-applies the background host policy as XCTest starts each case.
final class BackgroundTestHostObserver: NSObject, XCTestObservation {
    func testBundleWillStart(_ testBundle: Bundle) {
        AutomatedTestHost.becomeBackgroundHost()
    }

    private var languageAtStart: AppLanguage?

    func testCaseWillStart(_ testCase: XCTestCase) {
        AutomatedTestHost.becomeBackgroundHost()
        languageAtStart = AppLanguage.selected
    }

    /// A case that changes `AppLanguage.selected` without restoring it makes every later
    /// case run in that language. Name the culprit and put the language back.
    /// Compares the selection, so restoring an unset key as `.system` is not a leak.
    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let languageAtStart, AppLanguage.selected != languageAtStart else { return }
        print("BalanceBar test isolation: \(testCase.name) left appLanguage=\(AppLanguage.selected.rawValue), restoring \(languageAtStart.rawValue)")
        AppLanguage.selected = languageAtStart
    }
}

enum BackgroundTestHost {
    static let observer = BackgroundTestHostObserver()
    private(set) static var isInstalled = false

    static func install() {
        guard !isInstalled else {
            AutomatedTestHost.becomeBackgroundHost()
            return
        }
        isInstalled = true
        XCTestObservationCenter.shared.addTestObserver(observer)
        AutomatedTestHost.becomeBackgroundHost()
    }
}

/// The test bundle's `NSPrincipalClass` (set via `INFOPLIST_KEY_NSPrincipalClass`).
/// XCTest instantiates it when the bundle loads, before any case runs, which is the
/// only reliable place to register the observer: a Swift global is initialized lazily
/// on first access and would never run on its own.
@objc(BalanceBarTestPrincipal)
final class BalanceBarTestPrincipal: NSObject {
    override init() {
        super.init()
        BackgroundTestHost.install()
    }
}
