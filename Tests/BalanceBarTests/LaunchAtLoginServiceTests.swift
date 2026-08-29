import ServiceManagement
import XCTest
@testable import BalanceBar

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    private enum TestError: Error {
        case operationFailed
    }

    private final class MockLaunchAtLoginService: LaunchAtLoginService {
        var currentStatus: LaunchAtLoginStatus
        var registerError: Error?
        var unregisterError: Error?
        var statusAfterRegister: LaunchAtLoginStatus?
        var statusAfterRegisterError: LaunchAtLoginStatus?
        var statusAfterUnregisterError: LaunchAtLoginStatus?
        private(set) var statusReadCount = 0
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0
        private(set) var openSystemSettingsLoginItemsCallCount = 0

        init(status: LaunchAtLoginStatus) {
            currentStatus = status
        }

        var status: LaunchAtLoginStatus {
            statusReadCount += 1
            return currentStatus
        }

        func register() throws {
            registerCallCount += 1
            if let registerError {
                if let statusAfterRegisterError {
                    currentStatus = statusAfterRegisterError
                }
                throw registerError
            }
            currentStatus = statusAfterRegister ?? .enabled
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let unregisterError {
                if let statusAfterUnregisterError {
                    currentStatus = statusAfterUnregisterError
                }
                throw unregisterError
            }
            currentStatus = .notRegistered
        }

        func openSystemSettingsLoginItems() {
            openSystemSettingsLoginItemsCallCount += 1
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testServiceManagementStatusesMapToSafePresentationStates() {
        XCTAssertEqual(LaunchAtLoginStatus(.enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LaunchAtLoginStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginStatus(.notFound), .notFound)
    }

    func testControllerRegistersAndReloadsActualEnabledState() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(outcome.state, LaunchAtLoginState(status: .enabled))
        XCTAssertNil(outcome.error)
    }

    func testControllerUnregistersAndReloadsActualDisabledState() {
        let service = MockLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(outcome.state, LaunchAtLoginState(status: .notRegistered))
        XCTAssertNil(outcome.error)
    }

    func testControllerRegistersFromNotFoundState() {
        let service = MockLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(outcome.state.status, .enabled)
    }

    func testControllerUnregistersFromRequiresApprovalState() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(outcome.state.status, .notRegistered)
    }

    func testControllerReloadsActualStateAfterOperationError() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        service.statusAfterRegisterError = .enabled
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(outcome.state.status, .enabled)
        XCTAssertEqual(outcome.state.notice, .none)
        XCTAssertNotNil(outcome.error)
    }

    func testOperationErrorKeepsApprovalGuidanceWhenServiceNeedsApproval() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        service.statusAfterRegisterError = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(true)

        XCTAssertEqual(outcome.state.status, .requiresApproval)
        XCTAssertEqual(outcome.state.notice, .requiresApproval)
        XCTAssertNotNil(outcome.error)
    }

    func testDisablingRequiresApprovalAfterUnregisterErrorUsesOperationFailure() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        service.unregisterError = TestError.operationFailed
        service.statusAfterUnregisterError = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(false)

        XCTAssertEqual(outcome.state.status, .requiresApproval)
        XCTAssertEqual(outcome.state.notice, .operationFailed)
        XCTAssertNotNil(outcome.error)
    }

    func testDisablingAlreadyUnregisteredAfterUnregisterErrorIsPresentedAsSuccess() {
        let service = MockLaunchAtLoginService(status: .enabled)
        service.unregisterError = TestError.operationFailed
        service.statusAfterUnregisterError = .notRegistered
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(false)

        XCTAssertEqual(outcome.state.status, .notRegistered)
        XCTAssertEqual(outcome.state.notice, .none)
        XCTAssertNotNil(outcome.error)
    }

    func testOperationErrorUsesOperationFailureNoticeWhenStatusCannotBeRead() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        service.statusAfterRegisterError = .notFound
        let controller = LaunchAtLoginController(service: service)

        let outcome = controller.setEnabled(true)

        XCTAssertEqual(outcome.state.status, .notFound)
        XCTAssertEqual(outcome.state.notice, .operationFailed)
        XCTAssertNotNil(outcome.error)
    }

    func testRequiresApprovalAndExternalChangesRemainVisibleThroughRealStateReads() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(
            controller.currentState(),
            LaunchAtLoginState(status: .requiresApproval)
        )

        service.currentStatus = .enabled
        XCTAssertEqual(controller.currentState(), LaunchAtLoginState(status: .enabled))

        service.currentStatus = .notRegistered
        XCTAssertEqual(controller.currentState(), LaunchAtLoginState(status: .notRegistered))
    }

    func testControllerRoutesOpeningSystemSettingsThroughInjectedService() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)
        controller.openSystemSettingsLoginItems()
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 1)
    }

    func testDedicatedActionUsesRequestedStateWithoutGuidanceAndApplicationActivationReloadsExternalChanges() throws {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-262-activation.db")
            ),
            launchAtLoginService: service
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )
        let launchSwitch = try XCTUnwrap(
            descendants(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
        )

        appDelegate.handleLaunchAtLoginActionForTesting(enabled: true)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)
        XCTAssertEqual(launchSwitch.state, .on)

        service.currentStatus = .notRegistered
        appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(launchSwitch.state, .off)

        service.currentStatus = .enabled
        appDelegate.handleLaunchAtLoginActionForTesting(enabled: false)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)
    }

    func testRegisterRequiresApprovalKeepsSwitchOnWithInlineSettingsAction() throws {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-262-approval.db")
            ),
            launchAtLoginService: service
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )
        let controls = descendants(of: try XCTUnwrap(window.contentView))
        let launchSwitch = try XCTUnwrap(
            controls.compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == LaunchAtLoginController.toggleIdentifier }
        )
        let openSettings = try XCTUnwrap(
            controls.compactMap { $0 as? NSButton }
                .first { $0.title == tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginOpenSettings) }
        )

        appDelegate.handleLaunchAtLoginActionForTesting(enabled: true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(launchSwitch.state, .on)
        XCTAssertTrue(openSettings.isHidden == false)
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)
        openSettings.performClick(nil)
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 1)
    }

    func testLoginItemStateDoesNotUseAppPreferencesOrMigrationKeys() {
        let suiteName = "LaunchAtLoginServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = AppPreferences(defaults: defaults)
        let controller = LaunchAtLoginController(
            service: MockLaunchAtLoginService(status: .notRegistered)
        )
        _ = controller.currentState()

        XCTAssertNil(defaults.object(forKey: LaunchAtLoginController.toggleIdentifier))
        XCTAssertFalse(
            PreferencesMigrationPlan.keys.contains(LaunchAtLoginController.toggleIdentifier)
        )
    }
}
