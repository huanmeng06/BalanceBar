import ServiceManagement
import AppKit
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

    }

    private final class MockLaunchWithChatGPTService: LaunchWithChatGPTService {
        var currentStatus: LaunchWithChatGPTStatus
        var registerError: Error?
        var unregisterError: Error?
        var statusAfterRegister: LaunchWithChatGPTStatus?
        var statusAfterRegisterError: LaunchWithChatGPTStatus?
        var statusAfterUnregisterError: LaunchWithChatGPTStatus?
        private(set) var statusReadCount = 0
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0
        private(set) var openSystemSettingsLoginItemsCallCount = 0

        init(status: LaunchWithChatGPTStatus) {
            currentStatus = status
        }

        var status: LaunchWithChatGPTStatus {
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

    private final class MockChatGPTLaunchAgentWorkspace: ChatGPTLaunchAgentWorkspace {
        let notificationCenter = NotificationCenter()
        let balanceBarBundleIdentifier = "com.huanmeng06.BalanceBar.app"
        var runningBundleIdentifiers = Set<String>()
        var runningApplicationCheckBundleIdentifiers = [String]()
        var onIsApplicationRunning: ((String) -> Void)?
        var openCallCount = 0
        var openedURL: URL?
        var openedActivates: Bool?
        var openedAddsToRecentItems: Bool?
        private var completion: ((Error?) -> Void)?

        var balanceBarIsRunning: Bool {
            get { runningBundleIdentifiers.contains(balanceBarBundleIdentifier) }
            set {
                if newValue {
                    runningBundleIdentifiers.insert(balanceBarBundleIdentifier)
                } else {
                    runningBundleIdentifiers.remove(balanceBarBundleIdentifier)
                }
            }
        }

        func isApplicationRunning(bundleIdentifier: String) -> Bool {
            runningApplicationCheckBundleIdentifiers.append(bundleIdentifier)
            onIsApplicationRunning?(bundleIdentifier)
            return runningBundleIdentifiers.contains(bundleIdentifier)
        }

        func openApplication(
            at url: URL,
            activates: Bool,
            addsToRecentItems: Bool,
            completion: @escaping (Error?) -> Void
        ) {
            openCallCount += 1
            openedURL = url
            openedActivates = activates
            openedAddsToRecentItems = addsToRecentItems
            self.completion = completion
        }

        func finishOpen(with error: Error? = nil) {
            let completion = completion
            self.completion = nil
            completion?(error)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeChatGPTLaunchAgentRuntime(
        workspace: MockChatGPTLaunchAgentWorkspace
    ) -> ChatGPTLaunchAgentRuntime {
        ChatGPTLaunchAgentRuntime(
            workspace: workspace,
            balanceBarBundleURL: URL(fileURLWithPath: "/Applications/BalanceBar.app"),
            balanceBarBundleIdentifier: workspace.balanceBarBundleIdentifier
        )
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
        XCTAssertEqual(launchSwitch.state, .on)

        service.currentStatus = .notRegistered
        appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(launchSwitch.state, .off)

        service.currentStatus = .enabled
        appDelegate.handleLaunchAtLoginActionForTesting(enabled: false)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(launchSwitch.state, .off)
    }

    func testRegisterRequiresApprovalKeepsSwitchOnWithoutSettingsAction() throws {
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
        let launchAtLoginRow = try XCTUnwrap(launchSwitch.superview)

        appDelegate.handleLaunchAtLoginActionForTesting(enabled: true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(launchSwitch.state, .on)
        XCTAssertTrue(
            descendants(of: launchAtLoginRow).compactMap { $0 as? NSButton }.isEmpty
        )
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

    func testChatGPTServiceStatusesHaveTruthfulDefaultPresentation() {
        XCTAssertEqual(
            LaunchWithChatGPTState(status: .enabled),
            LaunchWithChatGPTState(status: .enabled, notice: LaunchWithChatGPTNotice.none)
        )
        XCTAssertEqual(
            LaunchWithChatGPTState(status: .requiresApproval).notice,
            .requiresApproval
        )
        XCTAssertEqual(
            LaunchWithChatGPTState(status: .notFound).notice,
            .unavailable
        )
        XCTAssertEqual(
            LaunchWithChatGPTState(status: .unknown).notice,
            .unavailable
        )
    }

    func testChatGPTControllerRegistersUnregistersAndReadsObservedStatus() {
        let service = MockLaunchWithChatGPTService(status: .notRegistered)
        let controller = LaunchWithChatGPTController(service: service)

        let enabled = controller.setEnabled(true)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(enabled.state, LaunchWithChatGPTState(status: .enabled))
        XCTAssertNil(enabled.error)

        let disabled = controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(disabled.state, LaunchWithChatGPTState(status: .notRegistered))
        XCTAssertNil(disabled.error)
    }

    func testChatGPTControllerKeepsApprovalAndFailureGuidance() {
        let approvalService = MockLaunchWithChatGPTService(status: .notRegistered)
        approvalService.statusAfterRegister = .requiresApproval
        let approvalController = LaunchWithChatGPTController(service: approvalService)
        let approval = approvalController.setEnabled(true)
        XCTAssertEqual(approval.state.notice, .requiresApproval)
        XCTAssertNil(approval.error)

        let failureService = MockLaunchWithChatGPTService(status: .notRegistered)
        failureService.registerError = TestError.operationFailed
        failureService.statusAfterRegisterError = .notFound
        let failureController = LaunchWithChatGPTController(service: failureService)
        let failure = failureController.setEnabled(true)
        XCTAssertEqual(failure.state.status, .notFound)
        XCTAssertEqual(failure.state.notice, .operationFailed)
        XCTAssertNotNil(failure.error)
    }

    func testChatGPTLaunchIdentityAndDecisionOnlyMatchSupportedLaunchEdges() {
        XCTAssertEqual(
            ChatGPTApplicationIdentity.bundleIdentifiers,
            ["com.openai.codex", "com.openai.chat"]
        )
        XCTAssertTrue(ChatGPTApplicationIdentity.matches(bundleIdentifier: "com.openai.codex"))
        XCTAssertTrue(ChatGPTApplicationIdentity.matches(bundleIdentifier: "com.openai.chat"))
        XCTAssertFalse(ChatGPTApplicationIdentity.matches(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(ChatGPTApplicationIdentity.matches(bundleIdentifier: nil))
        XCTAssertTrue(
            ChatGPTLaunchDecision.shouldLaunchBalanceBar(
                launchedBundleIdentifier: "com.openai.chat",
                balanceBarIsRunning: false
            )
        )
        XCTAssertFalse(
            ChatGPTLaunchDecision.shouldLaunchBalanceBar(
                launchedBundleIdentifier: "com.openai.chat",
                balanceBarIsRunning: true
            )
        )
        XCTAssertFalse(
            ChatGPTLaunchDecision.shouldLaunchBalanceBar(
                launchedBundleIdentifier: "com.apple.TextEdit",
                balanceBarIsRunning: false
            )
        )
    }

    func testChatGPTLaunchAgentRegistersObserverBeforeInitialReconciliation() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)
        var wasListeningDuringReconciliation = false
        workspace.onIsApplicationRunning = { _ in
            wasListeningDuringReconciliation = runtime.isListening
        }

        runtime.start()
        XCTAssertTrue(runtime.isListening)
        XCTAssertTrue(wasListeningDuringReconciliation)
        XCTAssertEqual(
            workspace.runningApplicationCheckBundleIdentifiers,
            ChatGPTApplicationIdentity.bundleIdentifiers
        )
    }

    func testChatGPTLaunchAgentReconcilesExistingChatGPTPresenceOnceAtStartup() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        workspace.runningBundleIdentifiers.insert("com.openai.codex")
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)

        runtime.start()
        runtime.start()

        XCTAssertEqual(workspace.openCallCount, 1)
        XCTAssertEqual(
            workspace.runningApplicationCheckBundleIdentifiers,
            ["com.openai.codex", workspace.balanceBarBundleIdentifier]
        )
        XCTAssertTrue(runtime.launchInFlight)
    }

    func testChatGPTLaunchAgentDoesNotOpenWhenBalanceBarAlreadyRunsAtStartup() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        workspace.runningBundleIdentifiers = [
            "com.openai.chat",
            workspace.balanceBarBundleIdentifier
        ]
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)

        runtime.start()

        XCTAssertEqual(workspace.openCallCount, 0)
        XCTAssertFalse(runtime.launchInFlight)
    }

    func testChatGPTLaunchAgentDoesNotOpenWhenChatGPTIsNotRunningAtStartup() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)

        runtime.start()

        XCTAssertEqual(workspace.openCallCount, 0)
        XCTAssertEqual(
            workspace.runningApplicationCheckBundleIdentifiers,
            ChatGPTApplicationIdentity.bundleIdentifiers
        )
    }

    func testChatGPTLaunchAgentDoesNotDuplicateAnEdgeDuringInitialReconciliation() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        workspace.runningBundleIdentifiers.insert("com.openai.codex")
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)
        var deliveredLaunchEdge = false
        workspace.onIsApplicationRunning = { bundleIdentifier in
            guard bundleIdentifier == "com.openai.codex", !deliveredLaunchEdge else {
                return
            }
            deliveredLaunchEdge = true
            runtime.handleLaunch(bundleIdentifier: "com.openai.chat")
        }

        runtime.start()

        XCTAssertEqual(workspace.openCallCount, 1)
        XCTAssertTrue(runtime.launchInFlight)
    }

    func testChatGPTLaunchAgentUsesLaunchEdgesAndGuardsDuplicateRequests() {
        let workspace = MockChatGPTLaunchAgentWorkspace()
        let runtime = makeChatGPTLaunchAgentRuntime(workspace: workspace)

        runtime.start()

        runtime.handleLaunch(bundleIdentifier: "com.openai.codex")
        runtime.handleLaunch(bundleIdentifier: "com.openai.chat")
        XCTAssertEqual(workspace.openCallCount, 1, "a second launch edge cannot duplicate an in-flight open")
        XCTAssertEqual(workspace.openedActivates, false)
        XCTAssertEqual(workspace.openedAddsToRecentItems, false)
        XCTAssertEqual(workspace.openedURL?.path, "/Applications/BalanceBar.app")

        workspace.finishOpen()
        workspace.balanceBarIsRunning = true
        runtime.handleLaunch(bundleIdentifier: "com.openai.chat")
        XCTAssertEqual(workspace.openCallCount, 1, "an already-running BalanceBar is not relaunched")

        workspace.balanceBarIsRunning = false
        XCTAssertEqual(
            workspace.openCallCount,
            1,
            "BalanceBar is not relaunched while ChatGPT remains running without a new launch edge"
        )

        runtime.stop()
        XCTAssertFalse(runtime.isListening)
        workspace.balanceBarIsRunning = false
        runtime.handleLaunch(bundleIdentifier: "com.openai.chat")
        XCTAssertEqual(workspace.openCallCount, 1, "stopping the agent removes its response path")
    }

    func testInitialLaunchPresentationMapsSilentPreferenceToBackgroundOnly() {
        XCTAssertEqual(InitialLaunchPresentation.resolve(silentLaunch: false), .dashboard)
        XCTAssertEqual(InitialLaunchPresentation.resolve(silentLaunch: true), .background)
    }
}
