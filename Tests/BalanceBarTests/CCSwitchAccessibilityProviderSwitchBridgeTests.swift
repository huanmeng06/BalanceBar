import ApplicationServices
import Foundation
import SQLite3
import XCTest
@testable import BalanceBar

final class CCSwitchAccessibilityProviderSwitchBridgeTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!
    private var repository: CCSwitchRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-CCSwitchAX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = temporaryDirectoryURL.appendingPathComponent("cc-switch.db")
        try createFixtureDatabase()
        repository = CCSwitchRepository(
            databaseURL: databaseURL,
            appSettingsURL: temporaryDirectoryURL.appendingPathComponent("settings.json"),
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

    func testPermissionMissingRequestsPermissionAndFailsClosed() throws {
        let runtime = FakeAccessibilityRuntime(permissionGranted: false)
        let bridge = makeBridge(runtime: runtime)
        let target = CCSwitchProviderSwitchTarget(
            providerID: "target",
            providerName: "Target",
            appType: "codex"
        )

        XCTAssertEqual(bridge.availability, .accessibilityPermissionRequired)
        XCTAssertThrowsError(try bridge.switchProvider(target: target)) { error in
            XCTAssertEqual(error as? CCSwitchAccessibilityError, .permissionRequired)
        }
        XCTAssertEqual(runtime.permissionRequestCount, 1)
        XCTAssertEqual(runtime.performedActions, [])
    }

    func testCodexClaudePrefixesAndUsageSuffixSectionMatch() throws {
        XCTAssertEqual(try CCSwitchAccessibilityProviderSwitchBridge.sectionPrefix(for: "codex"), "Codex · ")
        XCTAssertEqual(try CCSwitchAccessibilityProviderSwitchBridge.sectionPrefix(for: "claude"), "Claude · ")
        XCTAssertThrowsError(try CCSwitchAccessibilityProviderSwitchBridge.sectionPrefix(for: "gemini"))

        let runtime = FakeAccessibilityRuntime(
            sectionTitle: "Codex · Current · 🟢 5h 25%"
        )
        let bridge = makeBridge(runtime: runtime)
        try bridge.switchProvider(target: target())

        XCTAssertEqual(
            runtime.performedActions,
            [
                FakeAccessibilityAction(name: "AXPress", element: "status"),
                FakeAccessibilityAction(name: "AXPress", element: "provider")
            ]
        )
    }

    func testClaudeUsageSuffixSectionMatchUsesShowMenuFallback() throws {
        let runtime = FakeAccessibilityRuntime(
            sectionTitle: "Claude · Current · 🟢 5h 25%",
            useShowMenuFallback: true
        )
        let bridge = makeBridge(runtime: runtime)

        try bridge.switchProvider(target: target(appType: "claude"))

        XCTAssertEqual(
            runtime.performedActions,
            [
                FakeAccessibilityAction(name: "AXShowMenu", element: "status"),
                FakeAccessibilityAction(name: "AXPress", element: "provider")
            ]
        )
    }

    func testStatusAXPressFailureFallsBackToAXShowMenuWhenSupported() throws {
        let runtime = FakeAccessibilityRuntime(
            statusPressError: TestAccessibilityError.pressFailed
        )
        let bridge = makeBridge(runtime: runtime)

        try bridge.switchProvider(target: target())

        XCTAssertEqual(
            runtime.performedActions,
            [
                FakeAccessibilityAction(name: "AXShowMenu", element: "status"),
                FakeAccessibilityAction(name: "AXPress", element: "provider")
            ]
        )
    }

    func testUniqueEnabledProviderIsPressedAndPreviousAppIsRestored() throws {
        let runtime = FakeAccessibilityRuntime(frontmostProcessIdentifier: 99)
        let bridge = makeBridge(runtime: runtime)

        try bridge.switchProvider(target: target())

        XCTAssertEqual(
            runtime.performedActions,
            [
                FakeAccessibilityAction(name: "AXPress", element: "status"),
                FakeAccessibilityAction(name: "AXPress", element: "provider")
            ]
        )
        XCTAssertEqual(runtime.activationRequests, [99])
    }

    func testDuplicateDatabaseProviderNameFailsClosedBeforeAXPress() throws {
        try withDatabase { database in
            try execute(
                database,
                sql: "INSERT INTO providers VALUES ('duplicate', 'Target', '{}', '{}', 'official', NULL, 'codex', 0, 3, 3);"
            )
        }
        let runtime = FakeAccessibilityRuntime()
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            XCTAssertEqual(error as? CCSwitchAccessibilityError, .duplicateProviderName("Target"))
        }
        XCTAssertEqual(runtime.performedActions, [])
    }

    func testDisabledProviderFailsClosedWithoutPress() throws {
        let runtime = FakeAccessibilityRuntime(
            providerTitle: "Target ⛔",
            providerEnabled: false
        )
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            XCTAssertEqual(error as? CCSwitchAccessibilityError, .providerDisabled("Target"))
        }
        XCTAssertEqual(runtime.performedActions, [
            FakeAccessibilityAction(name: "AXPress", element: "status")
        ])
    }

    func testMissingSectionFailsClosedWithoutPressingAProvider() throws {
        let runtime = FakeAccessibilityRuntime(includeSection: false)
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            guard case .sectionUnavailable("Codex · ") = error as? CCSwitchAccessibilityError else {
                return XCTFail("expected missing Codex section, got \(error)")
            }
        }
        XCTAssertEqual(runtime.performedActions, [
            FakeAccessibilityAction(name: "AXPress", element: "status")
        ])
    }

    func testHiddenSectionFailsClosedWithoutPressingAProvider() throws {
        let runtime = FakeAccessibilityRuntime(sectionHidden: true)
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            guard case .sectionUnavailable("Codex · ") = error as? CCSwitchAccessibilityError else {
                return XCTFail("expected hidden Codex section, got \(error)")
            }
        }
        XCTAssertEqual(runtime.performedActions, [
            FakeAccessibilityAction(name: "AXPress", element: "status")
        ])
    }

    func testMissingTrayFailsClosedWithoutPress() throws {
        let runtime = FakeAccessibilityRuntime(includeStatusItem: false)
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            XCTAssertEqual(error as? CCSwitchAccessibilityError, .statusItemUnavailable)
        }
        XCTAssertEqual(runtime.performedActions, [])
    }

    func testAXPressFailureFailsClosed() throws {
        let runtime = FakeAccessibilityRuntime(providerPressError: TestAccessibilityError.pressFailed)
        let bridge = makeBridge(runtime: runtime)

        XCTAssertThrowsError(try bridge.switchProvider(target: target())) { error in
            XCTAssertEqual(error as? TestAccessibilityError, .pressFailed)
        }
        XCTAssertEqual(runtime.performedActions, [
            FakeAccessibilityAction(name: "AXPress", element: "status")
        ])
    }

    private func target(appType: String = "codex") -> CCSwitchProviderSwitchTarget {
        CCSwitchProviderSwitchTarget(
            providerID: appType == "claude" ? "claude-target" : "target",
            providerName: "Target",
            appType: appType
        )
    }

    private func makeBridge(
        runtime: FakeAccessibilityRuntime
    ) -> CCSwitchAccessibilityProviderSwitchBridge {
        CCSwitchAccessibilityProviderSwitchBridge(
            repository: repository,
            runtime: runtime
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
                INSERT INTO providers VALUES (
                    'claude-current', 'Claude Current', '{}', '{}', 'official', NULL, 'claude', 1, 1, 1
                );
                INSERT INTO providers VALUES (
                    'claude-target', 'Target', '{}', '{}', 'official', NULL, 'claude', 0, 2, 2
                );
                """
            )
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
            if let errorMessage { sqlite3_free(errorMessage) }
        }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw fixtureError("fixture SQL failed; sqlite code=\(code); error=\(message)")
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "BalanceBar.CCSwitchAccessibilityProviderSwitchBridgeTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

private struct FakeAccessibilityAction: Equatable {
    let name: String
    let element: String
}

private final class FakeAccessibilityRuntime: CCSwitchAccessibilityRuntime {
    private struct Node {
        var children: [String] = []
        var elements: [String: String] = [:]
        var strings: [String: String] = [:]
        var bools: [String: Bool] = [:]
        var actions: Set<String> = []
    }

    private var nodes: [String: Node] = [:]
    private(set) var performedActions: [FakeAccessibilityAction] = []
    private(set) var activationRequests: [pid_t] = []
    private(set) var permissionRequestCount = 0
    private var frontmostPID: pid_t?
    private let permissionGranted: Bool
    private let statusPressError: Error?
    private let providerPressError: Error?

    init(
        permissionGranted: Bool = true,
        frontmostProcessIdentifier: pid_t? = 99,
        sectionTitle: String = "Codex · Current",
        providerTitle: String = "Target",
        providerEnabled: Bool = true,
        includeSection: Bool = true,
        sectionHidden: Bool = false,
        includeStatusItem: Bool = true,
        useShowMenuFallback: Bool = false,
        statusPressError: Error? = nil,
        providerPressError: Error? = nil
    ) {
        self.permissionGranted = permissionGranted
        self.frontmostPID = frontmostProcessIdentifier
        self.statusPressError = statusPressError
        self.providerPressError = providerPressError

        nodes["app"] = Node(elements: [kAXExtrasMenuBarAttribute as String: "extras"])
        nodes["extras"] = Node(children: includeStatusItem ? ["status"] : [])
        var statusActions: Set<String> = [
            useShowMenuFallback ? kAXShowMenuAction as String : kAXPressAction as String
        ]
        if statusPressError != nil {
            statusActions = [kAXPressAction as String, kAXShowMenuAction as String]
        }
        nodes["status"] = Node(
            elements: ["AXMenu": "root"],
            strings: [
                kAXRoleAttribute as String: kAXMenuBarItemRole as String,
                kAXTitleAttribute as String: "CC Switch"
            ],
            actions: statusActions
        )
        nodes["root"] = Node(
            children: includeSection ? ["section"] : [],
            strings: [kAXRoleAttribute as String: kAXMenuRole as String]
        )
        nodes["section"] = Node(
            elements: ["AXMenu": "providerMenu"],
            strings: [
                kAXRoleAttribute as String: kAXMenuItemRole as String,
                kAXTitleAttribute as String: sectionTitle
            ],
            bools: sectionHidden ? [kAXHiddenAttribute as String: true] : [:]
        )
        nodes["providerMenu"] = Node(
            children: ["provider"],
            strings: [kAXRoleAttribute as String: kAXMenuRole as String]
        )
        nodes["provider"] = Node(
            strings: [kAXTitleAttribute as String: providerTitle],
            bools: [kAXEnabledAttribute as String: providerEnabled],
            actions: [kAXPressAction as String]
        )
    }

    var isTrusted: Bool { permissionGranted }

    var frontmostProcessIdentifier: pid_t? { frontmostPID }

    func requestPermission() {
        permissionRequestCount += 1
    }

    func runningApplication(bundleIdentifier: String) -> CCSwitchAccessibilityRunningApplication? {
        guard bundleIdentifier == CCSwitchAccessibilityProviderSwitchBridge.ccSwitchBundleIdentifier else {
            return nil
        }
        return CCSwitchAccessibilityRunningApplication(processIdentifier: 42, isActive: true)
    }

    func applicationElement(processIdentifier: pid_t) -> CCSwitchAccessibilityElement {
        _ = processIdentifier
        return CCSwitchAccessibilityElement(testIdentifier: "app")
    }

    func copyElement(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement {
        let node = try node(for: element)
        guard let identifier = node.elements[attribute] else {
            throw TestAccessibilityError.missingAttribute(attribute)
        }
        return CCSwitchAccessibilityElement(testIdentifier: identifier)
    }

    func copyElements(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> [CCSwitchAccessibilityElement] {
        guard attribute == kAXChildrenAttribute as String else {
            throw TestAccessibilityError.missingAttribute(attribute)
        }
        return try node(for: element).children.map {
            CCSwitchAccessibilityElement(testIdentifier: $0)
        }
    }

    func copyString(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> String? {
        try node(for: element).strings[attribute]
    }

    func copyBool(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> Bool {
        guard let value = try node(for: element).bools[attribute] else {
            throw TestAccessibilityError.missingAttribute(attribute)
        }
        return value
    }

    func actionNames(of element: CCSwitchAccessibilityElement) throws -> Set<String> {
        try node(for: element).actions
    }

    func performAction(
        _ action: String,
        on element: CCSwitchAccessibilityElement
    ) throws {
        let identifier = try nodeIdentifier(for: element)
        if identifier == "status",
           action == kAXPressAction as String,
           let statusPressError {
            throw statusPressError
        }
        if identifier == "provider", let providerPressError {
            throw providerPressError
        }
        performedActions.append(FakeAccessibilityAction(name: action, element: identifier))
        if identifier == "status" {
            frontmostPID = 42
        }
    }

    @discardableResult
    func activate(processIdentifier: pid_t) -> Bool {
        activationRequests.append(processIdentifier)
        frontmostPID = processIdentifier
        return true
    }

    private func node(for element: CCSwitchAccessibilityElement) throws -> Node {
        guard let identifier = element.testIdentifier,
              let node = nodes[identifier] else {
            throw TestAccessibilityError.invalidElement
        }
        return node
    }

    private func nodeIdentifier(for element: CCSwitchAccessibilityElement) throws -> String {
        guard let identifier = element.testIdentifier else {
            throw TestAccessibilityError.invalidElement
        }
        return identifier
    }
}

private enum TestAccessibilityError: Error, Equatable {
    case invalidElement
    case missingAttribute(String)
    case pressFailed
}
