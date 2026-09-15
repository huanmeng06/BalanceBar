import XCTest
@testable import BalanceBar

/// Re-applies the background host policy as XCTest starts each case.
private final class BackgroundTestHostObserver: NSObject, XCTestObservation {
    func testBundleWillStart(_ testBundle: Bundle) {
        _ = backgroundTestHostInstalled
        AutomatedTestHost.becomeBackgroundHost()
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        AutomatedTestHost.becomeBackgroundHost()
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
