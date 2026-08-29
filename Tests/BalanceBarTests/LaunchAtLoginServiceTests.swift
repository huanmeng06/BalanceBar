import ServiceManagement
import XCTest
@testable import BalanceBar

final class LaunchAtLoginServiceTests: XCTestCase {
    private enum TestError: Error {
        case operationFailed
    }

    private final class MockLaunchAtLoginService: LaunchAtLoginService {
        var currentStatus: LaunchAtLoginStatus
        var registerError: Error?
        var unregisterError: Error?
        var statusAfterRegisterError: LaunchAtLoginStatus?
        var statusAfterUnregisterError: LaunchAtLoginStatus?
        private(set) var statusReadCount = 0
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0

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
            currentStatus = .enabled
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
    }

    func testServiceManagementStatusesMapToSafePresentationStates() {
        XCTAssertEqual(LaunchAtLoginStatus(.enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LaunchAtLoginStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginStatus(.notFound), .unknown)
    }

    func testControllerRegistersAndReloadsActualEnabledState() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        let state = controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(state, LaunchAtLoginState(status: .enabled))
    }

    func testControllerUnregistersAndReloadsActualDisabledState() {
        let service = MockLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        let state = controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(state, LaunchAtLoginState(status: .notRegistered))
    }

    func testControllerReloadsActualStateAfterOperationError() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        service.statusAfterRegisterError = .enabled
        let controller = LaunchAtLoginController(service: service)

        let state = controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(state.status, .enabled)
        XCTAssertEqual(state.notice, .operationFailed)
    }

    func testOperationErrorKeepsApprovalGuidanceWhenServiceNeedsApproval() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.operationFailed
        service.statusAfterRegisterError = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        let state = controller.setEnabled(true)

        XCTAssertEqual(state.status, .requiresApproval)
        XCTAssertEqual(state.notice, .requiresApproval)
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
