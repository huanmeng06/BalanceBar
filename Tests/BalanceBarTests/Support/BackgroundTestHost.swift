import XCTest
@testable import BalanceBar

/// Re-applies the background host policy as XCTest starts each case.
private final class BackgroundTestHostObserver: NSObject, XCTestObservation {
    func testBundleWillStart(_ testBundle: Bundle) {
        _ = backgroundTestHostInstalled
        AutomatedTestHost.becomeBackgroundHost()
    }

    private var languageAtStart: String?

    func testCaseWillStart(_ testCase: XCTestCase) {
        AutomatedTestHost.becomeBackgroundHost()
        languageAtStart = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
    }

    /// A case that changes `AppLanguage.selected` without restoring it makes every later
    /// case run in that language. Name the culprit and put the language back.
    func testCaseDidFinish(_ testCase: XCTestCase) {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: AppLanguage.preferenceKey)
        guard current != languageAtStart else { return }
        print("BalanceBar test isolation: \(testCase.name) left appLanguage=\(current ?? "nil"), restoring \(languageAtStart ?? "nil")")
        if let languageAtStart {
            defaults.set(languageAtStart, forKey: AppLanguage.preferenceKey)
        } else {
            defaults.removeObject(forKey: AppLanguage.preferenceKey)
        }
    }
}

private enum BackgroundTestHost {
    private static let observer = BackgroundTestHostObserver()
    private static var didInstall = false

    static func install() {
        guard !didInstall else {
            AutomatedTestHost.becomeBackgroundHost()
            return
        }
        didInstall = true
        XCTestObservationCenter.shared.addTestObserver(observer)
        AutomatedTestHost.becomeBackgroundHost()
    }
}

private let backgroundTestHostInstalled: Void = BackgroundTestHost.install()
