import XCTest
@testable import BalanceBar

final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var root: URL!
    private var settingsURL: URL { root.appendingPathComponent("claude/settings.json") }
    private var backupURL: URL { root.appendingPathComponent("support/statusline-backup.json") }
    private var wrapperURL: URL { root.appendingPathComponent("Application Support/BalanceBar/bin/balancebar-statusline") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeInstaller(wrapper: URL? = nil, managed: URL? = nil) -> ClaudeStatusLineInstaller {
        ClaudeStatusLineInstaller(
            settingsURL: settingsURL, wrapperURL: wrapper ?? wrapperURL, backupURL: backupURL,
            managedSettingsURL: managed ?? root.appendingPathComponent("no-managed.json"))
    }

    private func writeSettings(_ text: String) throws {
        try Data(text.utf8).write(to: settingsURL)
    }

    private func settingsText() throws -> String {
        String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self)
    }

    private func statusLine() throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        return object?["statusLine"] as? [String: Any]
    }

    // MARK: - Round trips

    func testNoStatusLineInstallsMinimalObjectAndUninstallRestoresBytes() throws {
        let original = "{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n"
        try writeSettings(original)
        let installer = makeInstaller()
        let result = try installer.install()
        XCTAssertTrue(result.changed)
        let status = try XCTUnwrap(try statusLine())
        XCTAssertEqual(Set(status.keys), ["type", "command"])
        XCTAssertEqual(status["type"] as? String, "command")
        XCTAssertEqual(ClaudeStatusLineInstaller.embeddedOriginalCommand(in: result.command), "")
        XCTAssertTrue(try settingsText().hasPrefix("{\n  \"model\": \"opus\",\n  \"theme\": \"dark\""))

        XCTAssertTrue(try installer.uninstall())
        XCTAssertEqual(try settingsText(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testExistingStatusLineKeepsEveryOtherFieldAndRestoresExactly() throws {
        let original = #"{"statusLine":{"type":"command","command":"~/bin/line.sh","padding":2,"refreshInterval":5,"hideVimModeIndicator":true,"futureKey":{"a":[1,2]}},"env":{"X":"1"}}"#
        try writeSettings(original)
        let installer = makeInstaller()
        _ = try installer.install()
        let status = try XCTUnwrap(try statusLine())
        XCTAssertEqual(status["padding"] as? Int, 2)
        XCTAssertEqual(status["refreshInterval"] as? Int, 5)
        XCTAssertEqual(status["hideVimModeIndicator"] as? Bool, true)
        XCTAssertNotNil(status["futureKey"])
        XCTAssertTrue((status["command"] as? String)?.contains(ClaudeStatusLineInstaller.ownershipMarker) == true)

        XCTAssertTrue(try installer.uninstall())
        XCTAssertEqual(try settingsText(), original)
    }

    func testCommandWithQuotesPipesAndUnicodeRoundTrips() throws {
        let command = #"jq -r '"[\(.model.display_name)] ✓"' | sed "s/a/b/" && printf '%s\n' "$HOME" # 注释"#
        let object: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
        let original = try Data(contentsOf: settingsURL)
        let installer = makeInstaller()
        let result = try installer.install()
        XCTAssertEqual(ClaudeStatusLineInstaller.embeddedOriginalCommand(in: result.command), command)
        XCTAssertTrue(try installer.uninstall())
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
    }

    func testWrapperPathWithSpacesIsSingleQuoted() throws {
        let command = try ClaudeStatusLineInstaller.wrapperCommand(
            wrapperPath: "/Users/a b/Library/Application Support/BalanceBar/bin/balancebar-statusline", originalCommand: "x")
        XCTAssertTrue(command.hasPrefix("'/Users/a b/Library/Application Support/BalanceBar/bin/balancebar-statusline' "))
        XCTAssertThrowsError(try ClaudeStatusLineInstaller.wrapperCommand(wrapperPath: "/tmp/it's/bin", originalCommand: "x")) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .unsupportedWrapperPath)
        }
    }

    func testMissingSettingsFileIsCreated() throws {
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
        let installer = makeInstaller()
        _ = try installer.install()
        XCTAssertNotNil(try statusLine())
        let permissions = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertTrue(try installer.uninstall())
        XCTAssertNil(try statusLine())
    }

    func testReinstallOverOwnedCommandKeepsOriginalInsteadOfWrappingWrapper() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"original.sh"}}"#)
        _ = try makeInstaller().install()
        let moved = root.appendingPathComponent("moved/balancebar-statusline")
        let result = try makeInstaller(wrapper: moved).install()
        XCTAssertTrue(result.command.hasPrefix("'\(moved.path)'"))
        XCTAssertEqual(ClaudeStatusLineInstaller.embeddedOriginalCommand(in: result.command), "original.sh")
    }

    // MARK: - Failure safety

    func testOwnedCommandWithMissingBackupStopsInsteadOfRewrapping() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"original.sh"}}"#)
        _ = try makeInstaller().install()
        try FileManager.default.removeItem(at: backupURL)
        let before = try settingsText()
        XCTAssertThrowsError(try makeInstaller().install()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .backupMissing)
        }
        XCTAssertEqual(try settingsText(), before)
    }

    func testUninstallWithoutBackupRestoresEmbeddedOriginal() throws {
        let original = #"{"statusLine":{"type":"command","command":"original.sh","padding":1}}"#
        try writeSettings(original)
        _ = try makeInstaller().install()
        try FileManager.default.removeItem(at: backupURL)
        XCTAssertTrue(try makeInstaller().uninstall())
        XCTAssertEqual(try settingsText(), original)
    }

    func testBackupWriteFailureLeavesSettingsUntouched() throws {
        let original = #"{"statusLine":{"type":"command","command":"original.sh"}}"#
        try writeSettings(original)
        // A file where the backup directory should be makes the backup write fail.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("support"))
        XCTAssertThrowsError(try makeInstaller().install()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .writeFailed)
        }
        XCTAssertEqual(try settingsText(), original)
    }

    func testConcurrentModificationAbortsAndDropsNewBackup() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"original.sh"}}"#)
        let installer = makeInstaller()
        let concurrent = #"{"statusLine":{"type":"command","command":"other-tool.sh"}}"#
        installer.beforeSettingsWrite = { try Data(concurrent.utf8).write(to: self.settingsURL) }
        XCTAssertThrowsError(try installer.install()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .concurrentModification)
        }
        XCTAssertEqual(try settingsText(), concurrent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testInvalidSettingsAreNeverRewritten() throws {
        let broken = #"{"statusLine": {"command": "x",}"#
        try writeSettings(broken)
        XCTAssertThrowsError(try makeInstaller().install()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .invalidSettings)
        }
        XCTAssertEqual(try settingsText(), broken)
    }

    func testManagedStatusLineBlocksInstall() throws {
        try writeSettings("{}")
        let managed = root.appendingPathComponent("managed.json")
        try Data(#"{"statusLine":{"type":"command","command":"corp.sh"}}"#.utf8).write(to: managed)
        XCTAssertThrowsError(try makeInstaller(managed: managed).install()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .managedSettingsOverride)
        }
        XCTAssertEqual(try settingsText(), "{}")
    }

    func testUninstallLeavesThirdPartyCommandAlone() throws {
        try writeSettings(#"{"statusLine":{"type":"command","command":"original.sh"}}"#)
        _ = try makeInstaller().install()
        let replaced = #"{"statusLine":{"type":"command","command":"another-tool.sh"}}"#
        try writeSettings(replaced)
        XCTAssertThrowsError(try makeInstaller().uninstall()) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .notOwned)
        }
        XCTAssertEqual(try settingsText(), replaced)
        XCTAssertFalse(makeInstaller().isInstalled())
    }

    func testBundledHelperIsLookedUpUnderContentsHelpers() {
        let url = ClaudeStatusLineInstaller.bundledHelperURL(in: .main)
        XCTAssertTrue(url.path.hasSuffix("/Contents/Helpers/balancebar-statusline"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "the Xcode build embeds the helper")
    }

    func testInstallBundledWrapperCopiesHelperToStablePath() throws {
        let helper = ClaudeStatusLineInstaller.bundledHelperURL(in: .main)
        let installer = makeInstaller()
        try installer.installBundledWrapper(from: helper)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapperURL.path))
        XCTAssertEqual(try Data(contentsOf: wrapperURL), try Data(contentsOf: helper))
        XCTAssertThrowsError(try installer.installBundledWrapper(from: root.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? ClaudeStatusLineInstallerError, .helperMissing)
        }
    }
}
