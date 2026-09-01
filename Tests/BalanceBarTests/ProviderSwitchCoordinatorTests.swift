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

    func testPresentationRestorationPolicyDistinguishesAllRuntimeStates() {
        XCTAssertNil(CCSwitchPresentationState.notRunning.restoration)
        XCTAssertEqual(
            CCSwitchPresentationState.trayOnly.restoration,
            CCSwitchPresentationRestoration(hides: true, activates: false)
        )
        XCTAssertEqual(
            CCSwitchPresentationState.visibleInactive.restoration,
            CCSwitchPresentationRestoration(hides: false, activates: false)
        )
        XCTAssertEqual(
            CCSwitchPresentationState.visibleActive.restoration,
            CCSwitchPresentationRestoration(hides: false, activates: true)
        )
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
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleInactive))
        let actions = SwitchActionRecorder(testCase: self)
        let coordinator = makeCoordinator(runtime: runtime, actions: actions)

        coordinator.switchProvider(providerID: "target", appType: "codex", providerName: "Target")
        wait(for: [actions.completion], timeout: 2)

        XCTAssertEqual(actions.changedCount, 1)
        XCTAssertEqual(runtime.restoredSnapshots, [runtime.snapshotValue])
        XCTAssertEqual(runtime.restoredSnapshots.first?.state, .visibleInactive)
        XCTAssertEqual(
            CCSwitchPresentationState.visibleInactive.restoration,
            CCSwitchPresentationRestoration(hides: false, activates: false)
        )
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
        XCTAssertEqual(
            CCSwitchPresentationState.visibleActive.restoration,
            CCSwitchPresentationRestoration(hides: false, activates: true)
        )
    }

    func testTerminationTimeoutSkipsRepositoryWriteAndPresentationRestore() throws {
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleInactive))
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
        let runtime = RuntimeSpy(snapshot: CCSwitchRuntimeSnapshot(state: .visibleInactive))
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
        queue: DispatchQueue? = nil
    ) -> ProviderSwitchCoordinator {
        ProviderSwitchCoordinator(
            repository: repository,
            runtime: runtime,
            queue: queue ?? DispatchQueue(label: "test.provider-switch"),
            actions: ProviderSwitchActions(
                changed: { actions.changed() },
                failed: { actions.failed($0) }
            )
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

    func restore(from snapshot: CCSwitchRuntimeSnapshot) {
        restoredSnapshots.append(snapshot)
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
