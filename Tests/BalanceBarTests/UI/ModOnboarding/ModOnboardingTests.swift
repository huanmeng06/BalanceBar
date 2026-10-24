import AppKit
import XCTest
@testable import BalanceBar

private struct FakeHeadless: ModHeadlessSignalProviding { var isSatisfied: Bool }

private final class MemoryPreference: ModPromptPreferenceStoring { var isPromptDismissed = false }

private struct FakeLocator: ClaudeExecutableLocating { var path: String?; func locate() -> String? { path } }

private final class ScriptedRunner: ModCommandRunning {
    var results: [ModCommandResult?]
    private(set) var calls: [[String]] = []
    init(_ results: [ModCommandResult?]) { self.results = results }
    func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
        calls.append(arguments)
        return results.isEmpty ? nil : results.removeFirst()
    }
}

private let ok = ModCommandResult(exitCode: 0, stdout: "{\"outcome\":\"ok\"}", stderr: "")

final class ModPromptVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func inputs(_ edit: (inout ModPromptInputs) -> Void = { _ in }) -> ModPromptInputs {
        var i = ModPromptInputs(isOfficialDirect: true, claudeCode: .detected(.init(major: 2, minor: 1, patch: 291)))
        edit(&i)
        return i
    }

    func testVisibleOnlyWhenVersionConfirmed() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs(), now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .unknown }, now: now), .hidden(.claudeCodeVersionUnknown))
    }

    func testEachConditionHidesPrompt() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.isOfficialDirect = false }, now: now), .hidden(.notOfficialDirect))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.lastModDataAt = now.addingTimeInterval(-6 * 86_400) }, now: now), .hidden(.recentModData))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 2, minor: 1, patch: 286)) }, now: now), .hidden(.claudeCodeTooOld))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.promptDismissed = true }, now: now), .hidden(.dismissed))
    }

    func testBoundaries() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.lastModDataAt = now.addingTimeInterval(-7 * 86_400) }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 2, minor: 1, patch: 287)) }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 3, minor: 0, patch: 0)) }, now: now), .visible)
    }

    func testHeadlessSignalOnlyMattersWithHUDSnapshot() {
        let unmet = FakeHeadless(isSatisfied: false), met = FakeHeadless(isSatisfied: true)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.headlessSignalSatisfied = unmet.isSatisfied }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.hasHUDSnapshot = true; $0.headlessSignalSatisfied = unmet.isSatisfied }, now: now), .hidden(.headlessSignalNotSatisfied))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.hasHUDSnapshot = true; $0.headlessSignalSatisfied = met.isSatisfied }, now: now), .visible)
    }

    func testVersionParsing() {
        XCTAssertEqual(ClaudeCodeVersion.parse("2.1.291 (Claude Code)"), .init(major: 2, minor: 1, patch: 291))
        XCTAssertNil(ClaudeCodeVersion.parse("garbage"))
        XCTAssertLessThan(ClaudeCodeVersion.parse("2.1.99")!, ModOnboardingConfig.minimumClaudeCodeVersion)
    }

    func testEnhancementStatus() {
        let v = ClaudeCodeVersionStatus.detected(.init(major: 2, minor: 1, patch: 291))
        func status(installed: Bool, last: TimeInterval?, active: Bool, since: TimeInterval? = nil,
                    claude: ClaudeCodeVersionStatus = v) -> ModEnhancementStatus {
            .resolve(installed: installed, lastModDataAt: last.map { now.addingTimeInterval(-$0) }, claudeActivityDetected: active,
                     claudeCode: claude, silenceSince: since.map { now.addingTimeInterval(-$0) }, now: now)
        }
        XCTAssertEqual(status(installed: false, last: nil, active: true), .notInstalled)
        XCTAssertEqual(status(installed: true, last: nil, active: false), .waitingForData)
        // Just installed with activity but no clock yet, or under 10 minutes: still waiting.
        XCTAssertEqual(status(installed: true, last: nil, active: true), .waitingForData)
        XCTAssertEqual(status(installed: true, last: nil, active: true, since: 9 * 60), .waitingForData)
        XCTAssertEqual(status(installed: true, last: nil, active: true, since: 10 * 60), .enabledButSilent)
        // Old data, activity started recently: grace applies from the activity start.
        XCTAssertEqual(status(installed: true, last: 3600, active: true, since: 60), .active(lastDataAt: now.addingTimeInterval(-3600)))
        XCTAssertEqual(status(installed: true, last: 3600, active: true, since: 11 * 60), .enabledButSilent)
        XCTAssertEqual(status(installed: true, last: 9 * 60, active: true, since: 30 * 60), .active(lastDataAt: now.addingTimeInterval(-9 * 60)))
        XCTAssertEqual(status(installed: true, last: 3600, active: false), .active(lastDataAt: now.addingTimeInterval(-3600)))
        // Uninstalled with a leftover snapshot (fresh or stale) is not "enabled".
        XCTAssertEqual(status(installed: false, last: 3600, active: false), .notInstalled)
        XCTAssertEqual(status(installed: false, last: 60, active: true), .notInstalled)
        XCTAssertEqual(status(installed: false, last: nil, active: false, claude: .detected(.init(major: 2, minor: 0, patch: 1))),
                       .unsupportedClaudeCode(.init(major: 2, minor: 0, patch: 1)))
    }
}

final class ModInstallerTests: XCTestCase {
    private func run(locator: String?, results: [ModCommandResult?]) -> (ModInstallResult, [ModInstallStep], [[String]]) {
        let runner = ScriptedRunner(results)
        let q = DispatchQueue(label: "test.installer")
        let installer = ModInstaller(
            locator: FakeLocator(path: locator), runner: runner, prepareInbox: { true },
            workQueue: q, callbackQueue: q)
        let done = expectation(description: "install")
        var steps: [ModInstallStep] = [], result: ModInstallResult?
        installer.install(progress: { steps.append($0) }, completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        return (result!, q.sync { steps }, runner.calls)
    }

    func testSuccessRunsBothCommandsAndAllSteps() {
        let (result, steps, calls) = run(locator: "/bin/claude", results: [ok, ok])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(steps, [.addMarketplace, .installPlugin, .finish])
        XCTAssertEqual(calls, [ModInstallPlan.standard.marketplaceArguments, ModInstallPlan.standard.installArguments])
    }

    func testClaudeNotFoundRunsNothing() {
        let (result, steps, calls) = run(locator: nil, results: [ok, ok])
        XCTAssertEqual(result, .failure(.claudeNotFound))
        XCTAssertTrue(steps.isEmpty); XCTAssertTrue(calls.isEmpty)
    }

    func testCommandFailureStopsAtThatStep() {
        let bad = ModCommandResult(exitCode: 1, stdout: "", stderr: "boom")
        let (result, steps, calls) = run(locator: "/bin/claude", results: [ok, bad])
        XCTAssertEqual(result, .failure(.commandFailed(step: .installPlugin, exitCode: 1, detail: "boom")))
        XCTAssertEqual(steps, [.addMarketplace, .installPlugin]); XCTAssertEqual(calls.count, 2)
    }

    func testLaunchFailureAndNonOkOutcome() {
        let (launch, _, _) = run(locator: "/bin/claude", results: [nil])
        XCTAssertEqual(launch, .failure(.commandFailed(step: .addMarketplace, exitCode: nil, detail: "launch failed")))
        let notOk = ModCommandResult(exitCode: 0, stdout: "{\"outcome\":\"error\"}", stderr: "")
        let (outcome, _, _) = run(locator: "/bin/claude", results: [notOk])
        XCTAssertEqual(outcome, .failure(.commandFailed(step: .addMarketplace, exitCode: 0, detail: "outcome=error")))
    }

    func testLocatorSearchesPathThenKnownDirectories() {
        var seen: [String] = []
        let locator = DefaultClaudeExecutableLocator(environment: ["PATH": "/a:/b"], homeDirectory: "/h",
                                                     isExecutable: { seen.append($0); return $0 == "/h/.local/bin/claude" })
        XCTAssertEqual(locator.locate(), "/h/.local/bin/claude")
        XCTAssertEqual(Array(seen.prefix(2)), ["/a/claude", "/b/claude"])
        XCTAssertNil(DefaultClaudeExecutableLocator(environment: [:], homeDirectory: "/h", isExecutable: { _ in false }).locate())
    }
}

final class ModOnboardingPanelTests: XCTestCase {
    private func controller(locator: String?, results: [ModCommandResult?], pref: MemoryPreference = MemoryPreference(),
                            copied: @escaping (String) -> Void = { _ in }) -> ModOnboardingController {
        let q = DispatchQueue(label: "test.panel")
        let installer = ModInstaller(
            locator: FakeLocator(path: locator), runner: ScriptedRunner(results), prepareInbox: { true },
            workQueue: q, callbackQueue: .main)
        return ModOnboardingController(installer: installer, preference: pref, copyToPasteboard: copied)
    }

    private func lines(_ state: ModPanelState) -> [String] {
        ModPanelContent.items(for: state, plan: .standard, localize: ModOnboardingText.defaultLocalize).map(\.snapshotLine)
    }

    func testSnapshotIntro() {
        XCTAssertEqual(lines(.intro(dismissChecked: false)), [
            "# 实时增强",
            "• 只读取额度数据（5 小时 / 7 天用量），不读取对话内容。",
            "• 插件以你的用户权限在 Claude Code 内运行，可随时用 /plugin 卸载。",
            "• 数据只写入本机，不联网上传。",
            "• 新会话自动生效；已有会话可运行 /reload-plugins。",
            "( ) 不再在菜单中提示", "<一键安装>", "<关闭>",
        ])
        XCTAssertTrue(lines(.intro(dismissChecked: true)).contains("(x) 不再在菜单中提示"))
    }

    func testSnapshotInstallingSucceededFailedDismissed() {
        XCTAssertEqual(lines(.installing(current: .installPlugin)), ["# 实时增强", "[x] 添加来源", "[~] 安装 Mod", "[ ] 完成"])
        XCTAssertEqual(lines(.succeeded), ["# 已开启 ✓", "[x] 添加来源", "[x] 安装 Mod", "[x] 完成",
                                           "新开的 Claude Code 会话会自动生效。", "已有会话可选运行 /reload-plugins。", "</reload-plugins>", "<关闭>"])
        let commands = ModInstallPlan.standard.copyableCommands.replacingOccurrences(of: "\n", with: "\n$ ")
        XCTAssertEqual(lines(.failed(.claudeNotFound)), ["# 无法自动安装", "没有找到 claude 命令。请在终端中运行下面的命令：", "$ " + commands, "<复制命令>", "<关闭>"])
        XCTAssertEqual(lines(.failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "x")))[1], "命令未成功完成。请在终端中运行下面的命令：")
        XCTAssertEqual(lines(.dismissConfirmed), ["# 已关闭提示", "菜单底部改为显示“数据来源”。可在 设置 › 高级 › 实时增强 中重新开启。", "<撤销>", "<关闭>"])
    }

    func testPanelViewRendersEveryStateInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let c = controller(locator: nil, results: [])
            let view = ModOnboardingPanelView(controller: c)
            view.appearance = try XCTUnwrap(NSAppearance(named: name))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.height, 100, "intro \(name.rawValue)")
        }
    }

    func testInstallFlowToSuccessAndClaudeMissingFallback() {
        let success = controller(locator: "/bin/claude", results: [ok, ok])
        let done = expectation(description: "success")
        success.onChange = { if success.state == .succeeded { done.fulfill() } }
        success.startInstall()
        XCTAssertEqual(success.state, .installing(current: .addMarketplace))
        wait(for: [done], timeout: 5)

        var copied: String?
        let missing = controller(locator: nil, results: [], copied: { copied = $0 })
        let failed = expectation(description: "failed")
        let view = ModOnboardingPanelView(controller: missing)
        let reload = missing.onChange
        missing.onChange = { reload?(); if missing.state == .failed(.claudeNotFound) { failed.fulfill() } }
        view.perform(.install)
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(view.snapshotLines.contains("<复制命令>"))
        view.perform(.copyCommands)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableCommands)
    }

    func testDismissFlowShowsConfirmationAndPersists() {
        let pref = MemoryPreference()
        let c = controller(locator: nil, results: [], pref: pref)
        let view = ModOnboardingPanelView(controller: c)
        var closed = 0
        view.onRequestClose = { closed += 1 }
        view.perform(.close)  // unchecked: closes directly
        XCTAssertEqual(closed, 1); XCTAssertFalse(pref.isPromptDismissed)

        c.setDismissChecked(true)
        view.perform(.close)  // checked: confirmation state, not yet closed
        XCTAssertEqual(c.state, .dismissConfirmed); XCTAssertTrue(pref.isPromptDismissed); XCTAssertEqual(closed, 1)
        view.perform(.undoDismiss)
        XCTAssertEqual(c.state, .intro(dismissChecked: false)); XCTAssertFalse(pref.isPromptDismissed)
        c.setDismissChecked(true); view.perform(.close); view.perform(.close)
        XCTAssertEqual(closed, 2)
    }

    func testPanelViewRendersNonBlankWithButtonsWired() throws {
        let c = controller(locator: nil, results: [])
        let view = ModOnboardingPanelView(controller: c)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 100)
        XCTAssertEqual(view.snapshotLines.count, 8)
    }

    func testSettingsPresentationAndToggle() {
        let silent = RealtimeBoostPresentation.make(status: .enabledButSilent)
        XCTAssertTrue(silent.statusText.contains("10 分钟")); XCTAssertTrue(silent.showsCopyAction); XCTAssertFalse(silent.showsInstallAction)
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .notInstalled).showsInstallAction)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .active(lastDataAt: Date(timeIntervalSince1970: 1_767_274_800)), timeZone: utc).statusText, "已开启，最近数据 13:40:00")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .unsupportedClaudeCode(.init(major: 2, minor: 1, patch: 100))).statusText.contains("2.1.100"))

        let pref = MemoryPreference()
        let view = RealtimeBoostSettingsView(controller: controller(locator: nil, results: [], pref: pref), status: .notInstalled)
        XCTAssertEqual(view.promptToggle.state, .on)
        view.promptToggle.performClick(nil)
        XCTAssertTrue(pref.isPromptDismissed)
        view.promptToggle.performClick(nil)
        XCTAssertFalse(pref.isPromptDismissed)
    }

    func testPromptRowClick() {
        let row = ModPromptRowView()
        var clicks = 0
        row.onClick = { clicks += 1 }
        row.button.performClick(nil)
        XCTAssertEqual(clicks, 1); XCTAssertEqual(row.button.title, "启用实时增强 ›")
    }
}

// MARK: - Issue #597 (M2): user-scope install, settings entry, status, uninstall

final class ModInstallPlanArgsTests: XCTestCase {
    func testUninstallAndEnableArgumentsStayOnTheOwnUserScopeEntry() {
        let plan = ModInstallPlan.standard
        XCTAssertEqual(plan.marketplaceName, "balancebar-mods")
        XCTAssertEqual(plan.uninstallArguments, ["plugin", "uninstall", "balancebar-mod@balancebar-mods", "--scope", "user", "--json"])
        XCTAssertEqual(plan.removeMarketplaceArguments, ["plugin", "marketplace", "remove", "balancebar-mods", "--scope", "user", "--json"])
        XCTAssertEqual(plan.enableArguments, ["plugin", "enable", "balancebar-mod@balancebar-mods", "--scope", "user", "--json"])
        XCTAssertEqual(ModInstallPlan.versionArguments, ["--version"])
        XCTAssertEqual(ModInstallPlan.listArguments, ["plugin", "list", "--json"])
    }

    func testCopyableFallbacks() {
        let plan = ModInstallPlan.standard
        XCTAssertTrue(plan.copyableUninstallCommands.contains("plugin uninstall balancebar-mod@balancebar-mods --scope user"))
        XCTAssertTrue(plan.copyableUninstallCommands.contains("plugin marketplace remove balancebar-mods --scope user"))
        XCTAssertTrue(plan.copyableEnableCommand.contains("plugin enable balancebar-mod@balancebar-mods --scope user"))
    }
}

final class ModInstallerUninstallTests: XCTestCase {
    private func uninstall(locator: String?, results: [ModCommandResult?]) -> (ModUninstallResult, [ModUninstallStep], [[String]]) {
        let runner = ScriptedRunner(results)
        let q = DispatchQueue(label: "test.uninstaller")
        let installer = ModInstaller(
            locator: FakeLocator(path: locator), runner: runner, prepareInbox: { true },
            workQueue: q, callbackQueue: q)
        let done = expectation(description: "uninstall")
        var steps: [ModUninstallStep] = [], result: ModUninstallResult?
        installer.uninstall(progress: { steps.append($0) }, completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        return (result!, q.sync { steps }, runner.calls)
    }

    func testUninstallRunsPluginThenMarketplaceRemoval() {
        let (result, steps, calls) = uninstall(locator: "/bin/claude", results: [ok, ok])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(steps, [.uninstallPlugin, .removeMarketplace, .finish])
        XCTAssertEqual(calls, [
            ModInstallPlan.standard.uninstallArguments,
            ModInstallPlan.standard.removeMarketplaceArguments,
        ])
    }

    func testUninstallWithoutClaudeReportsFailureWithoutRunningAnything() {
        let (result, steps, calls) = uninstall(locator: nil, results: [])
        XCTAssertEqual(result, .failure(.claudeNotFound))
        XCTAssertTrue(steps.isEmpty); XCTAssertTrue(calls.isEmpty)
    }

    func testPluginRemovalFailureStopsTheFlow() {
        let bad = ModCommandResult(exitCode: 1, stdout: "", stderr: "boom")
        let (result, steps, calls) = uninstall(locator: "/bin/claude", results: [bad])
        XCTAssertEqual(result, .failure(.commandFailed(step: .uninstallPlugin, exitCode: 1, detail: "boom")))
        XCTAssertEqual(steps, [.uninstallPlugin]); XCTAssertEqual(calls.count, 1)
    }

    func testMarketplaceRemovalFailureIsBestEffortAfterThePluginIsGone() {
        let bad = ModCommandResult(exitCode: 1, stdout: "", stderr: "marketplace busy")
        let (result, steps, calls) = uninstall(locator: "/bin/claude", results: [ok, bad])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(steps, [.uninstallPlugin, .removeMarketplace, .finish])
        XCTAssertEqual(calls.count, 2)
    }

    func testInstallFailsWhenTheInboxCannotBePrepared() {
        let runner = ScriptedRunner([ok, ok])
        let q = DispatchQueue(label: "test.inboxprep")
        let installer = ModInstaller(
            locator: FakeLocator(path: "/bin/claude"), runner: runner, prepareInbox: { false },
            workQueue: q, callbackQueue: q)
        let done = expectation(description: "install")
        var result: ModInstallResult?
        installer.install(progress: { _ in }, completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, .failure(.inboxNotReady))
        XCTAssertEqual(runner.calls.count, 0, "no claude command may run before the inbox exists")
    }
}

final class ModSyncStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let version = ClaudeCodeVersion(major: 2, minor: 1, patch: 291)

    private func env(
        claudeFound: Bool = true, version: ClaudeCodeVersion? = nil,
        installation: ModPluginInstallation? = nil, otherScope: Bool = false,
        inboxReady: Bool = true, processRunning: Bool = false
    ) -> ModEnvironment {
        ModEnvironment(
            claudeFound: claudeFound, claudeVersion: version, installation: installation,
            hasNonUserScopeInstall: otherScope, inboxReady: inboxReady, claudeProcessRunning: processRunning)
    }

    private var installed: ModPluginInstallation {
        ModPluginInstallation(scope: "user", isEnabled: true, version: "1.0.0", installedAt: now.addingTimeInterval(-600))
    }

    func testDetectingWithoutEnvironment() {
        XCTAssertEqual(ModSyncStatus.resolve(environment: nil, evidence: .init(), now: now), .detecting)
    }

    func testErrorStatesWinOverInstallation() {
        XCTAssertEqual(ModSyncStatus.resolve(environment: env(claudeFound: false), evidence: .init(), now: now), .claudeMissing)
        XCTAssertEqual(
            ModSyncStatus.resolve(
                environment: env(version: .init(major: 2, minor: 1, patch: 286), installation: installed),
                evidence: .init(), now: now),
            .claudeVersionTooOld(.init(major: 2, minor: 1, patch: 286)))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed, inboxReady: false), evidence: .init(), now: now),
            .inboxNotReady)
    }

    func testNotInstalledDistinguishesOtherScopeInstalls() {
        XCTAssertEqual(ModSyncStatus.resolve(environment: env(), evidence: .init(), now: now), .notInstalled(hasOtherScopeInstall: false))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(otherScope: true), evidence: .init(), now: now),
            .notInstalled(hasOtherScopeInstall: true))
    }

    func testDisabledBeatsSnapshotEvidence() {
        let disabled = ModPluginInstallation(scope: "user", isEnabled: false, version: "1.0.0", installedAt: now.addingTimeInterval(-600))
        let evidence = ModSnapshotEvidence(lastAcceptedAt: now.addingTimeInterval(-60), lastRejection: nil)
        XCTAssertEqual(ModSyncStatus.resolve(environment: env(installation: disabled), evidence: evidence, now: now), .disabled)
    }

    func testWaitingForDataBeforeAnySnapshot() {
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed), evidence: .init(), now: now),
            .waitingForData)
    }

    func testActiveWithinGraceAndWithoutActivity() {
        let evidence = ModSnapshotEvidence(lastAcceptedAt: now.addingTimeInterval(-9 * 60), lastRejection: nil)
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed, processRunning: true), evidence: evidence, now: now),
            .active(lastAcceptedAt: now.addingTimeInterval(-9 * 60)))
        // Stale acceptance without Claude Code running still shows the last accepted time.
        let stale = ModSnapshotEvidence(lastAcceptedAt: now.addingTimeInterval(-3_600), lastRejection: nil)
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed, processRunning: false), evidence: stale, now: now),
            .active(lastAcceptedAt: now.addingTimeInterval(-3_600)))
    }

    func testSilentRequiresRunningClaudeAndGraceElapsed() {
        let stale = ModSnapshotEvidence(lastAcceptedAt: now.addingTimeInterval(-3_600), lastRejection: nil)
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed, processRunning: true), evidence: stale, now: now),
            .silent)
        // Never accepted anything, installed longer than the grace period, Claude running.
        let oldInstall = ModPluginInstallation(scope: "user", isEnabled: true, version: "1.0.0", installedAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: oldInstall, processRunning: true), evidence: .init(), now: now),
            .silent)
        // At the grace boundary the silence is reported…
        let boundaryInstall = ModPluginInstallation(scope: "user", isEnabled: true, version: "1.0.0", installedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: boundaryInstall, processRunning: true), evidence: .init(), now: now),
            .silent)
        // …and a recently installed Claude session is still just waiting for its first turn.
        let freshInstall = ModPluginInstallation(scope: "user", isEnabled: true, version: "1.0.0", installedAt: now.addingTimeInterval(-300))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: freshInstall, processRunning: true), evidence: .init(), now: now),
            .waitingForData)
    }

    func testRejectionNewerThanAcceptanceIsReportedAndOlderIsSuperseded() {
        let accepted = ModSnapshotEvidence(
            lastAcceptedAt: now.addingTimeInterval(-60),
            lastRejection: ModRejectionEvent(rejection: .accountMismatch, at: now.addingTimeInterval(-3_600)))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed), evidence: accepted, now: now),
            .active(lastAcceptedAt: now.addingTimeInterval(-60)))
        let rejected = ModSnapshotEvidence(
            lastAcceptedAt: now.addingTimeInterval(-3_600),
            lastRejection: ModRejectionEvent(rejection: .unverifiedCycle, at: now.addingTimeInterval(-60)))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed), evidence: rejected, now: now),
            .snapshotRejected(ModRejectionEvent(rejection: .unverifiedCycle, at: now.addingTimeInterval(-60))))
        // A rejection with no acceptance at all is also current.
        let onlyRejection = ModSnapshotEvidence(
            lastAcceptedAt: nil,
            lastRejection: ModRejectionEvent(rejection: .accountMismatch, at: now.addingTimeInterval(-60)))
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed), evidence: onlyRejection, now: now),
            .snapshotRejected(ModRejectionEvent(rejection: .accountMismatch, at: now.addingTimeInterval(-60))))
    }
}

final class ModSyncDetectorTests: XCTestCase {
    private let plan = ModInstallPlan.standard

    private func listJSON(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }

    private func entry(id: String = "balancebar-mod@balancebar-mods", scope: String = "user",
                       enabled: Bool = true, installedAt: String = "2026-10-20T08:00:00.000Z") -> [String: Any] {
        ["id": id, "scope": scope, "enabled": enabled, "version": "1.0.0", "installedAt": installedAt]
    }

    func testParsePluginListPicksOnlyTheMatchingUserScopeEntry() {
        let data = listJSON([
            entry(),
            entry(id: "claude-hud@claude-hud"),
            entry(scope: "local"),
        ])
        let parsed = ModSyncDetector.parsePluginList(data, plan: plan)
        XCTAssertEqual(parsed.installation, ModPluginInstallation(
            scope: "user", isEnabled: true, version: "1.0.0",
            installedAt: ModSyncDetector.parseTimestamp("2026-10-20T08:00:00.000Z")))
        XCTAssertTrue(parsed.hasNonUserScopeInstall)
    }

    func testParsePluginListMissingAndMalformed() {
        XCTAssertEqual(ModSyncDetector.parsePluginList(listJSON([]), plan: plan).installation, nil)
        XCTAssertFalse(ModSyncDetector.parsePluginList(listJSON([]), plan: plan).hasNonUserScopeInstall)
        XCTAssertNil(ModSyncDetector.parsePluginList(Data("not json".utf8), plan: plan).installation)
        XCTAssertNil(ModSyncDetector.parsePluginList(Data(), plan: plan).installation)
    }

    func testParseTimestampAcceptsFractionalAndPlainISO8601() {
        XCTAssertEqual(
            ModSyncDetector.parseTimestamp("2026-10-20T08:00:00.000Z"),
            ModSyncDetector.parseTimestamp("2026-10-20T08:00:00Z"))
        XCTAssertNil(ModSyncDetector.parseTimestamp("yesterday"))
    }

    func testInboxReadinessAndPreparationInTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb597-inbox-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("inbox", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(ModSyncDetector.isInboxReady(directory: directory, fileManager: .default))
        XCTAssertTrue(ModSyncDetector.prepareInbox(directory: directory))
        XCTAssertTrue(ModSyncDetector.isInboxReady(directory: directory, fileManager: .default))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o700)
        // Already ready: preparation is a no-op that keeps the directory.
        XCTAssertTrue(ModSyncDetector.prepareInbox(directory: directory))

        // A regular file in the directory's place is reported, not replaced.
        let filePath = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: filePath)
        XCTAssertFalse(ModSyncDetector.prepareInbox(directory: filePath))

        // An unwritable directory is reported, not modified.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        XCTAssertFalse(ModSyncDetector.isInboxReady(directory: locked, fileManager: .default))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }
}

final class ModPanelSyncContextTests: XCTestCase {
    private func lines(_ state: ModPanelState, sync: ModPanelSyncContext?) -> [String] {
        ModPanelContent.items(for: state, plan: .standard, localize: ModOnboardingText.defaultLocalize, sync: sync).map(\.snapshotLine)
    }

    private func context(_ status: ModSyncStatus) -> ModPanelSyncContext {
        ModPanelSyncContext(status: status, statusText: RealtimeBoostPresentation.make(status: status).statusText)
    }

    func testIntroWithSyncStatusShowsStatusAndSkipsMenuPromptCheckbox() {
        // An installed-but-waiting status offers the uninstall action, not install.
        let lines = self.lines(.intro(dismissChecked: false), sync: context(.waitingForData))
        XCTAssertTrue(lines[1].contains("已安装，等待新会话的数据"))
        XCTAssertFalse(lines.contains { $0.contains("不再在菜单中提示") })
        XCTAssertTrue(lines.contains("<卸载实时同步>"))
        XCTAssertFalse(lines.contains("<一键安装>"))

        // A not-installed status offers the install action.
        let notInstalled = self.lines(.intro(dismissChecked: false), sync: context(.notInstalled(hasOtherScopeInstall: false)))
        XCTAssertTrue(notInstalled.contains("<一键安装>"))
        XCTAssertFalse(notInstalled.contains("<卸载实时同步>"))
    }

    func testInstalledStatusesOfferUninstallInsteadOfInstall() {
        for status in [ModSyncStatus.waitingForData, .active(lastAcceptedAt: Date()), .silent] {
            let lines = self.lines(.intro(dismissChecked: false), sync: context(status))
            XCTAssertTrue(lines.contains("<卸载实时同步>"), "\(status)")
            XCTAssertFalse(lines.contains("<一键安装>"), "\(status)")
        }
    }

    func testDisabledOffersTheEnableCommandFallback() {
        let lines = lines(.intro(dismissChecked: false), sync: context(.disabled))
        XCTAssertTrue(lines.contains("<复制启用命令>"))
        XCTAssertTrue(lines.contains("<卸载实时同步>"))
    }

    func testLegacyPanelWithoutSyncKeepsTheCheckbox() {
        let lines = lines(.intro(dismissChecked: false), sync: nil)
        XCTAssertTrue(lines.contains("( ) 不再在菜单中提示"))
        XCTAssertTrue(lines.contains("<一键安装>"))
        XCTAssertFalse(lines.contains("<卸载实时同步>"))
    }

    func testUninstallPanelStates() {
        XCTAssertEqual(lines(.uninstalling(current: .removeMarketplace), sync: nil), [
            "# 实时增强", "[x] 卸载 Mod", "[~] 移除安装来源", "[ ] 完成",
        ])
        XCTAssertEqual(lines(.uninstallSucceeded, sync: nil), [
            "# 已卸载 ✓",
            "额度显示回退到官方路径；statusLine 与其他插件配置保持不变。",
            "<关闭>",
        ])
        let commands = ModInstallPlan.standard.copyableUninstallCommands.replacingOccurrences(of: "\n", with: "\n$ ")
        XCTAssertEqual(lines(.uninstallFailed(.commandFailed(step: .uninstallPlugin, exitCode: 1, detail: "x")), sync: nil), [
            "# 无法自动安装",
            "卸载未完成。请在终端中运行下面的命令：",
            "$ " + commands,
            "<复制命令>", "<关闭>",
        ])
        XCTAssertEqual(lines(.uninstallFailed(.claudeNotFound), sync: nil)[1], "没有找到 claude 命令。请在终端中运行下面的命令：")
    }

    func testControllerUninstallFlowAndCopyFallbacks() {
        var copied: String?
        var finished: ModUninstallResult?
        let q = DispatchQueue(label: "test.uninstall.flow")
        // The plugin removal itself fails: that must surface as a failure state.
        let installer = ModInstaller(
            locator: FakeLocator(path: "/bin/claude"),
            runner: ScriptedRunner([ModCommandResult(exitCode: 1, stdout: "", stderr: "nope")]),
            prepareInbox: { true }, workQueue: q, callbackQueue: .main)
        let controller = ModOnboardingController(installer: installer, preference: MemoryPreference(), copyToPasteboard: { copied = $0 })
        let view = ModOnboardingPanelView(controller: controller)
        let done = expectation(description: "uninstall failed")
        let base = controller.onChange
        controller.onChange = {
            base?()
            if case .uninstallFailed = controller.state { done.fulfill() }
        }
        controller.onUninstallCompleted = { finished = $0 }
        view.perform(.uninstall)
        XCTAssertEqual(controller.state, .uninstalling(current: .uninstallPlugin))
        wait(for: [done], timeout: 5)
        guard case .uninstallFailed = controller.state else { return XCTFail("expected uninstall failure") }
        guard case .failure(.commandFailed(step: .uninstallPlugin, _, _)) = finished else { return XCTFail("unexpected completion \(String(describing: finished))") }
        view.perform(.copyUninstall)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableUninstallCommands)
        view.perform(.copyEnable)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableEnableCommand)
        // A running uninstall blocks a concurrent install and vice versa.
        let installer2 = ModInstaller(
            locator: FakeLocator(path: "/bin/claude"), runner: ScriptedRunner([ok, ok]),
            prepareInbox: { true }, workQueue: q, callbackQueue: .main)
        let controller2 = ModOnboardingController(installer: installer2, preference: MemoryPreference())
        controller2.startUninstall()
        XCTAssertEqual(controller2.state, .uninstalling(current: .uninstallPlugin))
        controller2.startInstall()
        XCTAssertEqual(controller2.state, .uninstalling(current: .uninstallPlugin), "install must not start during uninstall")
        let uninstallDone = expectation(description: "uninstall finished")
        controller2.onChange = { if controller2.state == .uninstallSucceeded { uninstallDone.fulfill() } }
        wait(for: [uninstallDone], timeout: 5)
        XCTAssertEqual(controller2.state, .uninstallSucceeded)
    }
}

final class ModSyncPresentationTests: XCTestCase {
    func testEveryStatusMapsToActionableText() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .detecting, timeZone: utc).statusText, "正在检测…")
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .claudeMissing, timeZone: utc).statusText, "未找到 claude 命令。请安装 Claude Code 后重试")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .claudeVersionTooOld(.init(major: 2, minor: 1, patch: 100)), timeZone: utc).statusText.contains("2.1.100"))
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .inboxNotReady, timeZone: utc).showsInstallAction, true)
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .notInstalled(hasOtherScopeInstall: false), timeZone: utc).statusText, "未开启")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .notInstalled(hasOtherScopeInstall: true), timeZone: utc).statusText.contains("项目级安装"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .disabled, timeZone: utc).statusText.contains("停用"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: ModSyncStatus.waitingForData, timeZone: utc).statusText.contains("等待新会话"))
        XCTAssertEqual(
            RealtimeBoostPresentation.make(status: .active(lastAcceptedAt: Date(timeIntervalSince1970: 1_767_274_800)), timeZone: utc).statusText,
            "已开启，最近数据 13:40:00")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .silent, timeZone: utc).statusText.contains("/reload-plugins"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .snapshotRejected(.init(rejection: .accountMismatch, at: Date())), timeZone: utc).statusText.contains("账号"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .snapshotRejected(.init(rejection: .unverifiedCycle, at: Date())), timeZone: utc).statusText.contains("官方"))
    }
}

final class ModSyncCoordinatorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var inboxDirectory: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb597-coordinator-\(UUID().uuidString)", isDirectory: true)
        inboxDirectory = temporaryRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
        inboxDirectory = nil
    }

    private func listJSON(enabled: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: [[
            "id": "balancebar-mod@balancebar-mods", "scope": "user", "enabled": enabled,
            "version": "1.0.0", "installedAt": "2026-10-20T08:00:00.000Z",
        ]])
    }

    private func makeCoordinator(
        locator: String?, results: [ModCommandResult?]
    ) -> (ModSyncCoordinator, ScriptedRunner) {
        let runner = ScriptedRunner(results)
        let q = DispatchQueue(label: "test.coordinator")
        let controller = ModOnboardingController(
            installer: ModInstaller(
                locator: FakeLocator(path: locator), runner: runner, prepareInbox: { true },
                workQueue: q, callbackQueue: .main),
            preference: MemoryPreference())
        let detector = ModSyncDetector(
            locator: FakeLocator(path: locator), runner: runner,
            inboxDirectory: inboxDirectory, workQueue: q, callbackQueue: .main)
        let coordinator = ModSyncCoordinator(
            controller: controller, detector: detector, activityProvider: { false })
        return (coordinator, runner)
    }

    func testDetectionDrivesWaitingForDataAndSnapshotEvidenceDrivesActive() {
        let (coordinator, runner) = makeCoordinator(
            locator: "/bin/claude",
            results: [
                ModCommandResult(exitCode: 0, stdout: "2.1.291 (Claude Code)", stderr: ""),
                ModCommandResult(exitCode: 0, stdout: String(decoding: listJSON(), as: UTF8.self), stderr: ""),
            ])
        var changes: [ModSyncStatus] = []
        let detected = expectation(description: "detected")
        coordinator.onStatusChange = { status in
            changes.append(status)
            if status == .waitingForData { detected.fulfill() }
        }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [detected], timeout: 5)
        XCTAssertEqual(coordinator.status, .waitingForData)
        XCTAssertEqual(runner.calls, [ModInstallPlan.versionArguments, ModInstallPlan.listArguments])

        // A trusted accepted snapshot turns the status active…
        let accepted = expectation(description: "accepted")
        coordinator.onStatusChange = { status in
            if case .active = status { accepted.fulfill() }
        }
        coordinator.ingest(.init(kind: .processed(accepted: true), window: .fiveHour, observedAt: nil, receivedAt: Date()))
        wait(for: [accepted], timeout: 5)
        guard case .active = coordinator.status else { return XCTFail("expected active, got \(coordinator.status)") }

        // …a later rejection supersedes it.
        let rejected = expectation(description: "rejected")
        coordinator.onStatusChange = { status in
            if case .snapshotRejected = status { rejected.fulfill() }
        }
        coordinator.ingest(.init(
            kind: .rejected(reason: .accountEmailHashMismatch), window: nil, observedAt: nil,
            receivedAt: Date().addingTimeInterval(1)))
        wait(for: [rejected], timeout: 5)
        guard case .snapshotRejected(let event) = coordinator.status else { return XCTFail("expected rejected") }
        XCTAssertEqual(event.rejection, .accountMismatch)
    }

    func testDetectionThrottlesUnlessForced() {
        let (coordinator, runner) = makeCoordinator(locator: "/bin/claude", results: [])
        let first = expectation(description: "first")
        coordinator.onStatusChange = { _ in first.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [first], timeout: 5)
        let callsAfterFirst = runner.calls.count
        XCTAssertGreaterThan(callsAfterFirst, 0, "detection probes claude")
        coordinator.startDetectionIfNeeded()
        XCTAssertEqual(runner.calls.count, callsAfterFirst, "non-forced detection within the throttle window must be skipped")
        coordinator.startDetectionIfNeeded(force: true)
        let deadline = Date().addingTimeInterval(3)
        while runner.calls.count < callsAfterFirst * 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(runner.calls.count, callsAfterFirst * 2, "forced detection runs immediately")
        // The completion lands on the main queue; pump it once before reading the status.
        let settled = expectation(description: "settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(coordinator.status, .notInstalled(hasOtherScopeInstall: false))
    }

    func testSyncContextCarriesLocalizedStatusText() {
        let (coordinator, _) = makeCoordinator(locator: nil, results: [])
        XCTAssertEqual(coordinator.syncContext.status, .detecting)
        XCTAssertFalse(coordinator.syncContext.statusText.isEmpty)
    }
}

// MARK: - Review fixes (PR #603 round 2): panel reset, evidence lifecycle, live reload

extension ModSyncCoordinatorTests {
    private var probeVersion: ModCommandResult {
        ModCommandResult(exitCode: 0, stdout: "2.1.291 (Claude Code)", stderr: "")
    }

    private func listResult(enabled: Bool = true) -> ModCommandResult {
        ModCommandResult(exitCode: 0, stdout: String(decoding: listJSON(enabled: enabled), as: UTF8.self), stderr: "")
    }

    func testOpenPanelRefreshesWhenDetectionCompletes() {
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude", results: [probeVersion, listResult()])
        // The user opens the panel before the first detection has finished.
        let panel = coordinator.attachPanel()
        XCTAssertTrue(
            panel.snapshotLines.contains { $0.contains("正在检测…") },
            "panel opens with the detecting status: \(panel.snapshotLines)")
        let detected = expectation(description: "detected")
        coordinator.onStatusChange = { _ in detected.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [detected], timeout: 5)
        XCTAssertTrue(
            panel.snapshotLines.contains { $0.contains("已安装，等待新会话的数据") },
            "the open panel must refresh when detection lands: \(panel.snapshotLines)")
        XCTAssertFalse(panel.snapshotLines.contains { $0.contains("正在检测…") })
    }

    func testReopeningThePanelResetsFinishedOperationPages() {
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude",
            results: [probeVersion, listResult(), ok, ok, probeVersion, listResult()])
        let installed = expectation(description: "installed")
        coordinator.onStatusChange = { _ in installed.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [installed], timeout: 5)

        // A finished install success page must not survive into the next management view.
        let installedDone = expectation(description: "install finished")
        coordinator.controller.onChange = { if coordinator.controller.state == .succeeded { installedDone.fulfill() } }
        coordinator.controller.startInstall()
        wait(for: [installedDone], timeout: 5)
        XCTAssertEqual(coordinator.controller.state, .succeeded)

        let panel = coordinator.attachPanel()
        XCTAssertEqual(coordinator.controller.state, .intro(dismissChecked: false))
        XCTAssertTrue(
            panel.snapshotLines.contains { $0.contains("<卸载实时同步>") },
            "the reopened panel shows the management view for an installed Mod: \(panel.snapshotLines)")
        XCTAssertFalse(panel.snapshotLines.contains { $0.contains("已开启 ✓") })
    }

    func testSnapshotEvidenceIsClearedOnAccountChange() {
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude", results: [probeVersion, listResult()])
        let installed = expectation(description: "installed")
        coordinator.onStatusChange = { _ in installed.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [installed], timeout: 5)

        let accepted = expectation(description: "accepted")
        coordinator.onStatusChange = { if case .active = $0 { accepted.fulfill() } }
        coordinator.ingest(.init(kind: .processed(accepted: true), window: .fiveHour, observedAt: nil, receivedAt: Date()))
        wait(for: [accepted], timeout: 5)

        // Switching the Claude account must not let account B inherit account A's evidence.
        let reset = expectation(description: "evidence reset")
        coordinator.onStatusChange = { if $0 == .waitingForData { reset.fulfill() } }
        coordinator.ingest(.init(kind: .accountChanged, window: nil, observedAt: nil, receivedAt: Date()))
        wait(for: [reset], timeout: 5)
        XCTAssertEqual(coordinator.status, .waitingForData)
    }

    func testReinstallDoesNotInheritPreviousSnapshotEvidence() {
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude",
            results: [probeVersion, listResult(), ok, ok, probeVersion, listResult()])
        let installed = expectation(description: "installed")
        coordinator.onStatusChange = { _ in installed.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [installed], timeout: 5)

        let accepted = expectation(description: "accepted")
        coordinator.onStatusChange = { if case .active = $0 { accepted.fulfill() } }
        coordinator.ingest(.init(kind: .processed(accepted: true), window: .fiveHour, observedAt: nil, receivedAt: Date()))
        wait(for: [accepted], timeout: 5)

        // A successful (re)install resets the old evidence: until a fresh trusted snapshot
        // arrives the status is "waiting for data", never "realtime".
        let reinstallDone = expectation(description: "reinstall finished")
        let backToWaiting = expectation(description: "back to waiting")
        coordinator.controller.onChange = { if coordinator.controller.state == .succeeded { reinstallDone.fulfill() } }
        coordinator.onStatusChange = { if $0 == .waitingForData { backToWaiting.fulfill() } }
        coordinator.controller.startInstall()
        wait(for: [reinstallDone, backToWaiting], timeout: 5)
        XCTAssertEqual(coordinator.status, .waitingForData)
    }
}

extension ModPanelSyncContextTests {
    func testResetToIntroPreservesInFlightOperationsAndClearsFinishedPages() {
        let q = DispatchQueue(label: "test.reset.intro")
        let installer = ModInstaller(
            locator: FakeLocator(path: "/bin/claude"), runner: ScriptedRunner([ok, ok]),
            prepareInbox: { true }, workQueue: q, callbackQueue: .main)
        let controller = ModOnboardingController(installer: installer, preference: MemoryPreference())

        // An operation in flight keeps its progress across a presentation reset.
        controller.startUninstall()
        XCTAssertEqual(controller.state, .uninstalling(current: .uninstallPlugin))
        controller.resetToIntro()
        XCTAssertEqual(controller.state, .uninstalling(current: .uninstallPlugin))

        // A finished page is cleared, so the next management view starts at the intro.
        let done = expectation(description: "uninstall finished")
        controller.onChange = { if controller.state == .uninstallSucceeded { done.fulfill() } }
        wait(for: [done], timeout: 5)
        controller.resetToIntro()
        XCTAssertEqual(controller.state, .intro(dismissChecked: false))
    }
}
