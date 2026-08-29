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

        func openSystemSettingsLoginItems() {
            openSystemSettingsLoginItemsCallCount += 1
        }
    }

    private final class MockGuidancePresenter: LaunchAtLoginGuidancePresenting {
        private(set) var guidance: LaunchAtLoginGuidance?
        private var completion: ((Bool) -> Void)?

        func present(
            _ guidance: LaunchAtLoginGuidance,
            for window: NSWindow,
            completion: @escaping (Bool) -> Void
        ) {
            self.guidance = guidance
            self.completion = completion
        }

        func complete(openSettings: Bool) {
            let completion = completion
            self.completion = nil
            completion?(openSettings)
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

    func testControllerRoutesOpeningSystemSettingsThroughInjectedService() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)
        controller.openSystemSettingsLoginItems()
        XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 1)
    }

    func testSpecialStatesPresentGuidanceWithoutRegistrationAndOpenSettingsOnlyAfterConfirmation() throws {
        for (status, expectedGuidance) in [
            (LaunchAtLoginStatus.requiresApproval, LaunchAtLoginGuidance.requiresApproval),
            (.notFound, .unavailable),
            (.unknown, .unavailable)
        ] {
            let service = MockLaunchAtLoginService(status: status)
            let presenter = MockGuidancePresenter()
            let appDelegate = AppDelegate(
                repository: CCSwitchRepository(
                    databaseURL: URL(fileURLWithPath: "/nonexistent/issue-262-guidance-\(status).db")
                ),
                launchAtLoginService: service,
                launchAtLoginGuidancePresenter: presenter
            )
            defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
            _ = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
            )

            appDelegate.handleLaunchAtLoginActionForTesting()

            XCTAssertEqual(presenter.guidance, expectedGuidance)
            XCTAssertEqual(service.registerCallCount, 0)
            XCTAssertEqual(service.unregisterCallCount, 0)
            XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)

            presenter.complete(openSettings: false)
            XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 0)

            appDelegate.handleLaunchAtLoginActionForTesting()
            presenter.complete(openSettings: true)
            XCTAssertEqual(service.openSystemSettingsLoginItemsCallCount, 1)
        }
    }

    func testDedicatedActionUsesActualNormalStateAndApplicationActivationReloadsExternalChanges() throws {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let presenter = MockGuidancePresenter()
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-262-activation.db")
            ),
            launchAtLoginService: service,
            launchAtLoginGuidancePresenter: presenter
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

        appDelegate.handleLaunchAtLoginActionForTesting()
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(launchSwitch.state, .on)

        service.currentStatus = .notRegistered
        appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(launchSwitch.state, .off)

        service.currentStatus = .enabled
        appDelegate.handleLaunchAtLoginActionForTesting()
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(launchSwitch.state, .off)
        XCTAssertNil(presenter.guidance)
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
