import AppKit
import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class ProviderSwitchCoordinatorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!
    private var appSettingsURL: URL!
    private var repository: CCSwitchRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-ProviderSwitchCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = temporaryDirectoryURL.appendingPathComponent("cc-switch.db")
        appSettingsURL = temporaryDirectoryURL.appendingPathComponent("settings.json")
        try createFixtureDatabase()
        repository = CCSwitchRepository(
            databaseURL: databaseURL,
            appSettingsURL: appSettingsURL,
            homeDirectoryURL: temporaryDirectoryURL
        )
    }

    override func tearDownWithError() throws {
        repository = nil
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testPresentationStatesRemainDistinct() {
        XCTAssertNotEqual(CCSwitchPresentationState.notRunning, .trayOnly)
        XCTAssertNotEqual(CCSwitchPresentationState.trayOnly, .visibleInactive)
        XCTAssertNotEqual(CCSwitchPresentationState.visibleInactive, .visibleActive)
    }

    func testCoreGraphicsVisibilityDetectionRequiresVisibleStandardWindowEvidence() {
        let visibleStandardWindow = windowInfo(
            ownerPID: 42,
            layer: 0,
            isOnscreen: true,
            alpha: 1,
            width: 320,
            height: 240
        )
        XCTAssertTrue(
            CCSwitchRuntimeController.hasVisibleStandardWindow(
                for: 42,
                windowInfo: [visibleStandardWindow]
            )
        )

        let rejectedWindows = [
            windowInfo(ownerPID: 99, layer: 0, isOnscreen: true, alpha: 1, width: 320, height: 240),
            windowInfo(ownerPID: 42, layer: 1, isOnscreen: true, alpha: 1, width: 320, height: 240),
            windowInfo(ownerPID: 42, layer: 0, isOnscreen: false, alpha: 1, width: 320, height: 240),
            windowInfo(ownerPID: 42, layer: 0, isOnscreen: true, alpha: 0, width: 320, height: 240),
            windowInfo(ownerPID: 42, layer: 0, isOnscreen: true, alpha: 1, width: 0, height: 240),
        ]
        XCTAssertFalse(
            CCSwitchRuntimeController.hasVisibleStandardWindow(
                for: 42,
                windowInfo: rejectedWindows
            )
        )
    }

    func testNotRunningSwitchDoesNotTerminateOrRelaunch() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .notRunning))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(actions.failureCount, 0)
        XCTAssertEqual(runtime.snapshotCallCount, 1)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 1)
    }

    func testTrayOnlySwitchRestoresHiddenBackgroundPresentation() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .trayOnly))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(runtime.restoredSnapshots.first?.state, .trayOnly)
        XCTAssertEqual(runtime.terminationTimeouts.count, 1)
        XCTAssertEqual(try XCTUnwrap(runtime.terminationTimeouts.first), 4, accuracy: 0.000001)
    }

    func testVisibleInactiveSwitchRestoresWindowWithoutActivation() throws {
        let runtime = RuntimeSpy(snapshot: visibleInactiveSnapshot())
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(runtime.restoredSnapshots.first?.state, .visibleInactive)
    }

    func testVisibleActiveSwitchRestoresVisibleActivePresentation() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(runtime.restoredSnapshots.first?.state, .visibleActive)
    }

    func testTerminationTimeoutSkipsRepositoryWriteAndPresentationRestore() throws {
        let runtime = RuntimeSpy(snapshot: visibleInactiveSnapshot())
        runtime.terminationResult = false
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "current"), 1)
        XCTAssertEqual(try currentValue(for: "target"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSettingsURL.path))
    }

    func testRepositoryFailureRestoresOriginalPresentation() throws {
        let runtime = RuntimeSpy(snapshot: visibleInactiveSnapshot())
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "missing", appType: "codex", providerName: "Missing")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(try currentValue(for: "current"), 1)
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testDatabaseVerificationFailureRestoresOriginalPresentation() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                CREATE TRIGGER force_target_off
                AFTER UPDATE OF is_current ON providers
                WHEN NEW.id = 'target' AND NEW.is_current = 1
                BEGIN
                    UPDATE providers SET is_current = 0 WHERE id = 'target';
                END;
                """
            )
        }

        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(runtime.restoredSnapshots.first?.state, .visibleActive)
    }

    func testPresentationRestoreFailurePreventsChangedAction() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .trayOnly))
        runtime.restorationResult = .failure(CCSwitchRuntimeError.presentationDidNotRestore)
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(try currentValue(for: "target"), 1)
    }

    func testRunningCCSwitchUsesHotSwitchBridgeWithoutTerminationOrReopen() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        let repository = try XCTUnwrap(self.repository)
        bridge.onSwitch = { target in
            try repository.switchCurrent(to: target.providerID, appType: target.appType)
        }
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(actions.failureCount, 0)
        XCTAssertEqual(bridge.requests, [.init(providerID: "target", appType: "codex")])
        XCTAssertEqual(bridge.requests.first?.target.providerName, "Target")
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 1)
    }

    func testRunningCCSwitchHotSwitchDoesNotRequirePreviousForeground() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleInactive))
        let bridge = ProviderSwitchBridgeSpy()
        let repository = try XCTUnwrap(self.repository)
        bridge.onSwitch = { target in
            try repository.switchCurrent(to: target.providerID, appType: target.appType)
        }
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(actions.failureCount, 0)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 1)
    }

    func testHotSwitchBridgeFailureDoesNotFallBackToLegacyRestart() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        bridge.switchError = CCSwitchProviderSwitchBridgeError.unavailable
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "current"), 1)
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testHotSwitchBridgeRequiresDatabaseVerification() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testSeamlessSwitchUnavailableFailsClosedWithoutTermination() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        bridge.availability = .unavailable
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(bridge.requests, [])
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testSeamlessSwitchPermissionMissingFailsClosedWithoutTermination() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        bridge.availability = .accessibilityPermissionRequired
        bridge.switchError = CCSwitchAccessibilityError.permissionRequired
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testHotSwitchWaitsForAsynchronousDatabaseVerification() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let bridge = ProviderSwitchBridgeSpy()
        let repository = try XCTUnwrap(self.repository)
        let databaseUpdate = expectation(description: "CC Switch updates the database")
        bridge.onSwitch = { target in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                do {
                    try repository.switchCurrent(to: target.providerID, appType: target.appType)
                } catch {
                    XCTFail("unexpected asynchronous database update failure: \(error)")
                }
                databaseUpdate.fulfill()
            }
        }
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(
            runtime: runtime,
            actions: actions,
            bridge: bridge,
            seamlessSwitchEnabled: true,
            verificationTimeout: 0.5
        )

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion, databaseUpdate], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(actions.failureCount, 0)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "target"), 1)
    }

    func testVisibleInactiveWithoutForegroundPreconditionSkipsTerminationAndWrite() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleInactive))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 1)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "current"), 1)
        XCTAssertEqual(try currentValue(for: "target"), 0)
    }

    func testProductionAdapterVisibleInactiveWaitsForWindowAndRestoresPreviousForeground() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.onLaunch = { hides, _ in
            environment.processExists = true
            if !hides {
                // Models CC Switch silent_startup/lightweight mode: the first
                // launch has no main window, and the Reopen request recreates
                // and shows it while briefly focusing CC Switch.
                environment.visible = true
                environment.active = true
                environment.frontmostProcessIdentifier = environment.ccSwitchProcessIdentifier
            }
        }
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "visible inactive presentation restored")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .visibleInactive,
            applicationURL: environment.applicationURL,
            previousFrontmostProcessIdentifier: environment.previousProcessIdentifier
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        if case .failure(let error) = result {
            XCTFail("expected restoration success, got \(error)")
        }
        XCTAssertEqual(
            launcher.requests,
            [
                .init(hides: true, activates: false),
                .init(hides: false, activates: false),
            ]
        )
        XCTAssertEqual(environment.activationCalls, [environment.previousProcessIdentifier])
        XCTAssertEqual(environment.frontmostProcessIdentifier, environment.previousProcessIdentifier)
        XCTAssertFalse(environment.active)
        XCTAssertTrue(environment.visible)
    }

    func testProductionAdapterVisibleActiveWaitsForWindowAndActiveState() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.onLaunch = { hides, _ in
            environment.processExists = true
            if !hides {
                environment.visible = true
                environment.active = true
                environment.frontmostProcessIdentifier = environment.ccSwitchProcessIdentifier
            }
        }
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "visible active presentation restored")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .visibleActive,
            applicationURL: environment.applicationURL
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        if case .failure(let error) = result {
            XCTFail("expected restoration success, got \(error)")
        }
        XCTAssertEqual(
            launcher.requests,
            [
                .init(hides: true, activates: false),
                .init(hides: false, activates: false),
            ]
        )
        XCTAssertTrue(environment.visible)
        XCTAssertTrue(environment.active)
        XCTAssertEqual(environment.activationCalls, [])
    }

    func testProductionAdapterTrayOnlyUsesOneHiddenLaunchAndVerifiesNoWindow() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.onLaunch = { _, _ in
            environment.processExists = true
            environment.visible = true
        }
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "tray presentation restored")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .trayOnly,
            applicationURL: environment.applicationURL,
            previousFrontmostProcessIdentifier: environment.previousProcessIdentifier
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        if case .failure(let error) = result {
            XCTFail("expected restoration success, got \(error)")
        }
        XCTAssertEqual(launcher.requests, [.init(hides: true, activates: false)])
        XCTAssertEqual(environment.hideCallCount, 1)
        XCTAssertFalse(environment.visible)
    }

    func testProductionAdapterPropagatesOpenApplicationError() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.outcomes = [
            .failure(NSError(domain: "TestLaunch", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "launch rejected"
            ]))
        ]
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "launch error reported")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .visibleActive,
            applicationURL: environment.applicationURL
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        guard case .failure(let error as CCSwitchRuntimeError) = result else {
            return XCTFail("expected CCSwitchRuntimeError.launchFailed, got \(String(describing: result))")
        }
        guard case .launchFailed(let message) = error else {
            return XCTFail("expected launch failure, got \(error)")
        }
        XCTAssertEqual(message, "launch rejected")
        XCTAssertEqual(launcher.requests.count, 1)
    }

    func testProductionAdapterFailsWhenReopenDoesNotRestoreVisibleWindow() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.onLaunch = { hides, _ in
            environment.processExists = true
            if hides {
                environment.visible = false
            } else {
                environment.active = true
                environment.frontmostProcessIdentifier = environment.ccSwitchProcessIdentifier
            }
        }
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "window restoration failure reported")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .visibleInactive,
            applicationURL: environment.applicationURL,
            previousFrontmostProcessIdentifier: environment.previousProcessIdentifier
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        guard case .failure(let error as CCSwitchRuntimeError) = result else {
            return XCTFail("expected visible-window failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error, .presentationDidNotRestore)
        XCTAssertEqual(launcher.requests.count, 2)
        XCTAssertEqual(environment.activationCalls, [environment.previousProcessIdentifier])
    }

    func testProductionAdapterFailsWhenVisibleActiveNeverBecomesActive() {
        let environment = RuntimeControllerEnvironment()
        let launcher = ApplicationLaunchSpy()
        launcher.onLaunch = { hides, _ in
            environment.processExists = true
            if !hides {
                environment.visible = true
                environment.active = false
            }
        }
        let runtime = makeRuntimeController(environment: environment, launcher: launcher)
        let completion = expectation(description: "active restoration failure reported")
        var result: Result<Void, Error>?
        let snapshot = CCSwitchRuntimeSnapshot(
            state: .visibleActive,
            applicationURL: environment.applicationURL
        )

        runtime.restore(from: snapshot) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        guard case .failure(let error as CCSwitchRuntimeError) = result else {
            return XCTFail("expected active-state failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error, .activePresentationDidNotRestore)
    }

    func testSameProviderNoOpSkipsSnapshotTerminationAndRelaunch() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleActive))
        let actions = SwitchActionRecorder(testCase: self)
        let queue = DispatchQueue(label: "test.provider-switch.no-op")
        let coordinator = makeCoordinator(runtime: runtime, actions: actions, queue: queue)
        actions.completion.isInverted = true

        coordinator.switchProvider(providerID: "current", appType: "codex", providerName: "Current")
        queue.sync {}
        wait(for: [actions.completion], timeout: 0.1)

        XCTAssertEqual(actions.changedCount, 0)
        XCTAssertEqual(actions.failureCount, 0)
        XCTAssertEqual(runtime.snapshotCallCount, 0)
        XCTAssertEqual(runtime.terminationTimeouts, [])
        XCTAssertEqual(runtime.restoredSnapshots, [])
        XCTAssertEqual(try currentValue(for: "current"), 1)
    }

    private func makeCoordinator(
        runtime: RuntimeSpy,
        actions: SwitchActionRecorder,
        bridge: CCSwitchProviderSwitching = CCSwitchUnavailableProviderSwitchBridge(),
        seamlessSwitchEnabled: Bool = false,
        verificationTimeout: TimeInterval = 0.25,
        queue: DispatchQueue? = nil
    ) -> ProviderSwitchCoordinator {
        ProviderSwitchCoordinator(
            repository: repository,
            runtime: runtime,
            providerSwitchBridge: bridge,
            isSeamlessSwitchEnabled: { seamlessSwitchEnabled },
            verificationTimeout: verificationTimeout,
            verificationPollingInterval: 0.01,
            queue: queue ?? DispatchQueue(label: "test.provider-switch"),
            actions: ProviderSwitchActions(
                changed: { actions.changed() },
                failed: { actions.failed($0) }
            )
        )
    }

    private func visibleInactiveSnapshot() -> CCSwitchRuntimeSnapshot {
        CCSwitchRuntimeSnapshot(
            state: .visibleInactive,
            previousFrontmostProcessIdentifier: 4343
        )
    }

    private func makeRuntimeController(
        environment: RuntimeControllerEnvironment,
        launcher: ApplicationLaunchSpy
    ) -> CCSwitchRuntimeController {
        CCSwitchRuntimeController(
            runningApplicationProvider: { nil },
            previousFrontmostProcessIdentifierProvider: {
                environment.frontmostProcessIdentifier
            },
            windowInfoProvider: {
                environment.visible ? environment.visibleWindowInfo : []
            },
            processExistsProvider: { processIdentifier in
                processIdentifier == environment.ccSwitchProcessIdentifier
                    && environment.processExists
            },
            activeStateProvider: { processIdentifier in
                processIdentifier == environment.ccSwitchProcessIdentifier
                    && environment.active
            },
            hideApplication: { processIdentifier in
                guard processIdentifier == environment.ccSwitchProcessIdentifier else {
                    return false
                }
                environment.hideCallCount += 1
                environment.visible = false
                environment.active = false
                return environment.hideResult
            },
            activateApplication: { processIdentifier in
                environment.activationCalls.append(processIdentifier)
                guard environment.activateResult else { return false }
                environment.frontmostProcessIdentifier = processIdentifier
                if processIdentifier == environment.previousProcessIdentifier {
                    environment.active = false
                }
                return true
            },
            applicationLauncher: launcher,
            restorationTimeout: 0.05,
            pollInterval: 0.001,
            restorationQueue: DispatchQueue(label: "test.cc-switch-restore-\(UUID().uuidString)")
        )
    }

    private func createFixtureDatabase() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: """
                CREATE TABLE providers (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    settings_config TEXT NOT NULL,
                    meta TEXT NOT NULL,
                    category TEXT,
                    website_url TEXT,
                    app_type TEXT NOT NULL,
                    is_current INTEGER NOT NULL,
                    sort_index INTEGER,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE proxy_config (
                    app_type TEXT,
                    live_takeover_active INTEGER,
                    enabled INTEGER
                );
                CREATE TABLE proxy_live_backup (app_type TEXT);
                INSERT INTO proxy_config VALUES ('codex', 0, 1);
                INSERT INTO providers VALUES (
                    'current', 'Current', '{}', '{}', 'official', NULL, 'codex', 1, 1, 1
                );
                INSERT INTO providers VALUES (
                    'target', 'Target', '{}', '{}', 'official', NULL, 'codex', 0, 2, 2
                );
                """
            )
        }
    }

    private func currentValue(for providerID: String) throws -> Int32 {
        try withDatabase { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT is_current FROM providers WHERE id = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw fixtureError("failed to prepare current provider query")
            }
            sqlite3_bind_text(
                statement,
                1,
                providerID,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw fixtureError("provider row was not found")
            }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let code = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw fixtureError("failed to open fixture database; sqlite code=\(code)")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw fixtureError("fixture SQL failed; sqlite code=\(code); error=\(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.ProviderSwitchCoordinatorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private func windowInfo(
        ownerPID: Int32,
        layer: Int,
        isOnscreen: Bool,
        alpha: Double,
        width: Double,
        height: Double
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: ownerPID),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowIsOnscreen as String: NSNumber(value: isOnscreen),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: NSDictionary(dictionary: [
                "X": 0.0,
                "Y": 0.0,
                "Width": width,
                "Height": height,
            ]),
        ]
    }
}

private final class RuntimeSpy: CCSwitchRuntimeControlling {
    let snapshotValue: CCSwitchRuntimeSnapshot
    var terminationResult = true
    var restorationResult: Result<Void, Error> = .success(())
    private(set) var snapshotCallCount = 0
    private(set) var terminationTimeouts: [TimeInterval] = []
    private(set) var restoredSnapshots: [CCSwitchRuntimeSnapshot] = []

    init(snapshot: CCSwitchRuntimeSnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot() -> CCSwitchRuntimeSnapshot {
        snapshotCallCount += 1
        return snapshotValue
    }

    func terminateAndWait(for snapshot: CCSwitchRuntimeSnapshot, timeout: TimeInterval) -> Bool {
        terminationTimeouts.append(timeout)
        return terminationResult
    }

    func restore(
        from snapshot: CCSwitchRuntimeSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        restoredSnapshots.append(snapshot)
        completion(restorationResult)
    }
}

private final class ProviderSwitchBridgeSpy: CCSwitchProviderSwitching {
    struct Request: Equatable {
        let target: CCSwitchProviderSwitchTarget

        init(target: CCSwitchProviderSwitchTarget) {
            self.target = target
        }

        init(providerID: String, appType: String, providerName: String = "Target") {
            target = CCSwitchProviderSwitchTarget(
                providerID: providerID,
                providerName: providerName,
                appType: appType
            )
        }

        var providerID: String { target.providerID }
        var appType: String { target.appType }
    }

    var availability: CCSwitchBridgeAvailability = .ready
    private(set) var requests: [Request] = []
    var switchError: Error?
    var onSwitch: ((CCSwitchProviderSwitchTarget) throws -> Void)?

    func switchProvider(target: CCSwitchProviderSwitchTarget) throws {
        requests.append(Request(target: target))
        if let switchError {
            throw switchError
        }
        try onSwitch?(target)
    }
}

private final class ApplicationLaunchSpy: CCSwitchApplicationLaunching {
    struct Request: Equatable {
        let hides: Bool
        let activates: Bool
    }

    private(set) var requests: [Request] = []
    var outcomes: [Result<pid_t?, Error>] = []
    var onLaunch: ((Bool, Bool) -> Void)?
    let processIdentifier: pid_t = 4242

    func launch(
        at applicationURL: URL,
        hides: Bool,
        activates: Bool,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        _ = applicationURL
        requests.append(Request(hides: hides, activates: activates))
        onLaunch?(hides, activates)
        let outcome = outcomes.isEmpty
            ? Result<pid_t?, Error>.success(processIdentifier)
            : outcomes.removeFirst()
        switch outcome {
        case .success(let processIdentifier):
            completion(processIdentifier, nil)
        case .failure(let error):
            completion(nil, error)
        }
    }
}

private final class RuntimeControllerEnvironment {
    let applicationURL = URL(fileURLWithPath: "/Applications/CC Switch.app")
    let ccSwitchProcessIdentifier: pid_t = 4242
    let previousProcessIdentifier: pid_t = 4343
    var processExists = false
    var visible = false
    var active = false
    var frontmostProcessIdentifier: pid_t? = 4343
    var hideResult = true
    var activateResult = true
    var hideCallCount = 0
    var activationCalls: [pid_t] = []

    var visibleWindowInfo: [[String: Any]] {
        [[
            kCGWindowOwnerPID as String: NSNumber(value: ccSwitchProcessIdentifier),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowBounds as String: NSDictionary(dictionary: [
                "X": 0.0,
                "Y": 0.0,
                "Width": 640.0,
                "Height": 480.0,
            ]),
        ]]
    }
}

private final class SwitchActionRecorder {
    let completion: XCTestExpectation
    private(set) var changedCount = 0
    private(set) var failureCount = 0

    init(testCase: XCTestCase) {
        completion = testCase.expectation(description: "provider switch action")
    }

    func changed() {
        changedCount += 1
        completion.fulfill()
    }

    func failed(_ message: String) {
        _ = message
        failureCount += 1
        completion.fulfill()
    }
}
