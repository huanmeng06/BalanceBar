import AppKit
import XCTest
@testable import BalanceBar

private struct FakeHeadless: ModHeadlessSignalProviding { var isSatisfied: Bool }

private final class MemoryPreference: ModPromptPreferenceStoring { var isPromptDismissed = false }

private struct FakeLocator: ClaudeExecutableLocating { var path: String?; func locate() -> String? { path } }

private final class ScriptedRunner: ModCommandRunning {
    var results: [ModCommandResult?]
    var onRun: (([String]) -> Void)?
    private(set) var calls: [[String]] = []
    init(_ results: [ModCommandResult?]) { self.results = results }
    func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
        calls.append(arguments)
        onRun?(arguments)
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
                                           "新开的 Claude Code 会话会自动生效。", "已有会话可选运行下面的命令。", "</reload-plugins>", "<关闭>"])
        let commands = ModInstallPlan.standard.copyableCommands.replacingOccurrences(of: "\n", with: "\n$ ")
        XCTAssertEqual(lines(.failed(.claudeNotFound)), ["# 无法自动安装", "没有找到 claude 命令。请在终端中运行下面的命令：", "$ " + commands, "<复制命令>", "<关闭>"])
        XCTAssertEqual(lines(.failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "x")))[1], "命令未成功完成。请在终端中运行下面的命令：")
        XCTAssertEqual(lines(.dismissConfirmed), ["# 已隐藏提示", "之后可以在 设置 › 通用 › 刷新 中安装 BalanceBar Mod。", "<撤销>", "<关闭>"])
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
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .active(lastDataAt: Date(timeIntervalSince1970: 1_767_274_800)), timeZone: utc).statusText, "已开启，最近可信数据 13:40:00")
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
        XCTAssertEqual(row.mainText, "为 Claude 安装 Mod，额度实时更新")
        XCTAssertEqual(row.whyText, "为什么这么做？")
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(clicks, 1)
    }
}

// MARK: - Status-menu prompt row (INT-2)

final class ModMenuRowTests: XCTestCase {
    func testPromptOnlyForConfirmedNotInstalledOfficialDirect() {
        XCTAssertEqual(
            ModMenuRow.resolve(isOfficialDirect: true, status: .notInstalled(hasOtherScopeInstall: false), promptDismissed: false),
            .prompt)
        XCTAssertEqual(
            ModMenuRow.resolve(isOfficialDirect: true, status: .notInstalled(hasOtherScopeInstall: true), promptDismissed: false),
            .prompt)
    }

    func testInstalledOrUndetectedStatesHaveNoPrompt() {
        for status: ModSyncStatus in [.detecting, .waitingForData, .disabled, .silent, .active(lastAcceptedAt: Date())] {
            XCTAssertEqual(
                ModMenuRow.resolve(isOfficialDirect: true, status: status, promptDismissed: false), .none,
                "\(status) must not show the install prompt")
        }
    }

    func testPromptRowHoverResetsBetweenPresentations() {
        let row = ModPromptRowView()
        row.setHoveringForTesting(true)
        XCTAssertTrue(row.isHovering)
        row.resetHoverState()
        XCTAssertFalse(row.isHovering)
    }

    func testNonOfficialAndDismissedHideThePrompt() {
        let notInstalled = ModSyncStatus.notInstalled(hasOtherScopeInstall: false)
        XCTAssertEqual(ModMenuRow.resolve(isOfficialDirect: false, status: notInstalled, promptDismissed: false), .none)
        XCTAssertEqual(ModMenuRow.resolve(isOfficialDirect: true, status: notInstalled, promptDismissed: true), .none)
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
        inboxReady: Bool = true, processRunning: Bool = false,
        installationCheck: ModInstallationCheck = .ok
    ) -> ModEnvironment {
        ModEnvironment(
            claudeFound: claudeFound, claudeVersion: version, installation: installation,
            hasNonUserScopeInstall: otherScope, installationCheck: installationCheck,
            inboxReady: inboxReady, claudeProcessRunning: processRunning)
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

    func testFailedPluginListIsUnknownNotNotInstalled() {
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installationCheck: .failed(reason: "exit 1")), evidence: .init(), now: now),
            .installationUnknown)
        // A list we could not read is unknown even if some installation was cached earlier.
        XCTAssertEqual(
            ModSyncStatus.resolve(environment: env(installation: installed, installationCheck: .failed(reason: "unreadable")), evidence: .init(), now: now),
            .installationUnknown)
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

    func testParsePluginListPicksOnlyTheMatchingUserScopeEntry() throws {
        let data = listJSON([
            entry(),
            entry(id: "claude-hud@claude-hud"),
            entry(scope: "local"),
        ])
        let parsed = try XCTUnwrap(ModSyncDetector.parsePluginList(data, plan: plan))
        XCTAssertEqual(parsed.installation, ModPluginInstallation(
            scope: "user", isEnabled: true, version: "1.0.0",
            installedAt: ModSyncDetector.parseTimestamp("2026-10-20T08:00:00.000Z")))
        XCTAssertTrue(parsed.hasNonUserScopeInstall)
    }

    func testParsePluginListMissingAndMalformed() throws {
        let empty = try XCTUnwrap(ModSyncDetector.parsePluginList(listJSON([]), plan: plan))
        XCTAssertNil(empty.installation)
        XCTAssertFalse(empty.hasNonUserScopeInstall)
        // Unreadable output is a failed probe, not a confirmed absence.
        XCTAssertNil(ModSyncDetector.parsePluginList(Data("not json".utf8), plan: plan))
        XCTAssertNil(ModSyncDetector.parsePluginList(Data(), plan: plan))
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
        XCTAssertTrue(lines.contains { $0.contains("已安装，等待新会话的数据") })
        XCTAssertFalse(lines.contains { $0.contains("不再在菜单中提示") })
        XCTAssertTrue(lines.contains("<卸载 BalanceBar Mod>"))
        XCTAssertFalse(lines.contains("<一键安装>"))

        // A not-installed status offers the install action.
        let notInstalled = self.lines(.intro(dismissChecked: false), sync: context(.notInstalled(hasOtherScopeInstall: false)))
        XCTAssertTrue(notInstalled.contains("<一键安装>"))
        XCTAssertFalse(notInstalled.contains("<卸载 BalanceBar Mod>"))
    }

    func testInstalledStatusesOfferUninstallInsteadOfInstall() {
        for status in [ModSyncStatus.waitingForData, .active(lastAcceptedAt: Date()), .silent] {
            let lines = self.lines(.intro(dismissChecked: false), sync: context(status))
            XCTAssertTrue(lines.contains("<卸载 BalanceBar Mod>"), "\(status)")
            XCTAssertFalse(lines.contains("<一键安装>"), "\(status)")
        }
    }

    func testDisabledOffersTheEnableCommandFallback() {
        let lines = lines(.intro(dismissChecked: false), sync: context(.disabled))
        XCTAssertTrue(lines.contains("<复制启用命令>"))
        XCTAssertTrue(lines.contains("<卸载 BalanceBar Mod>"))
    }

    func testLegacyPanelWithoutSyncKeepsTheCheckbox() {
        let lines = lines(.intro(dismissChecked: false), sync: nil)
        XCTAssertTrue(lines.contains("( ) 不再在菜单中提示"))
        XCTAssertTrue(lines.contains("<一键安装>"))
        XCTAssertFalse(lines.contains("<卸载 BalanceBar Mod>"))
    }

    func testUninstallPanelStates() {
        XCTAssertEqual(lines(.uninstalling(current: .removeMarketplace), sync: nil), [
            "# 实时增强", "[x] 卸载 Mod", "[~] 移除安装来源", "[ ] 完成",
        ])
        XCTAssertEqual(lines(.uninstallSucceeded, sync: nil), [
            "# 已卸载 ✓",
            "额度已改为定时向官方查询。「Claude Code 原生同步」和其他插件不受影响。",
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
        XCTAssertTrue(view.isConfirmingUninstall)
        XCTAssertEqual(controller.state, .intro(dismissChecked: false))
        view.perform(.confirmUninstall)
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
            "已开启，最近可信数据 13:40:00")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .silent, timeZone: utc).statusText.contains("/reload-plugins"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .snapshotRejected(.init(rejection: .accountMismatch, at: Date())), timeZone: utc).statusText.contains("账号"))
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .snapshotRejected(.init(rejection: .unverifiedCycle, at: Date())), timeZone: utc).statusText.contains("官方"))
        let unknown = RealtimeBoostPresentation.make(status: .installationUnknown, timeZone: utc)
        XCTAssertTrue(unknown.statusText.contains("无法确认"))
        XCTAssertFalse(unknown.showsInstallAction, "a failed probe must not offer a reinstall")
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
        locator: String?, results: [ModCommandResult?],
        activityProvider: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
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
            controller: controller, detector: detector, activityProvider: activityProvider,
            now: now, schedule: schedule)
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

    func testPluginListFailureIsUnknownNotNotInstalled() {
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude",
            results: [
                ModCommandResult(exitCode: 0, stdout: "2.1.291 (Claude Code)", stderr: ""),
                ModCommandResult(exitCode: 1, stdout: "", stderr: "permission denied"),
            ])
        let unknown = expectation(description: "installation unknown")
        coordinator.onStatusChange = { status in
            if status == .installationUnknown { unknown.fulfill() }
        }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [unknown], timeout: 5)
        XCTAssertEqual(coordinator.status, .installationUnknown)
    }

    func testSilenceRecheckFlipsActiveToSilentWhenGraceExpires() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled: [(TimeInterval, () -> Void)] = []
        let version = ModCommandResult(exitCode: 0, stdout: "2.1.291 (Claude Code)", stderr: "")
        let list = ModCommandResult(exitCode: 0, stdout: String(decoding: listJSON(), as: UTF8.self), stderr: "")
        let (coordinator, _) = makeCoordinator(
            locator: "/bin/claude",
            results: [version, list, version, list],
            activityProvider: { true },
            now: { clock },
            schedule: { delay, block in scheduled.append((delay, block)) })

        let detected = expectation(description: "initial detection")
        coordinator.onStatusChange = { _ in detected.fulfill() }
        coordinator.startDetectionIfNeeded(force: true)
        wait(for: [detected], timeout: 5)

        let active = expectation(description: "active after a trusted snapshot")
        coordinator.onStatusChange = { status in
            if case .active = status { active.fulfill() }
        }
        coordinator.ingest(.init(kind: .processed(accepted: true), window: .fiveHour,
                                 observedAt: clock, receivedAt: clock))
        wait(for: [active], timeout: 5)
        let delay = try XCTUnwrap(scheduled.last?.0)
        XCTAssertEqual(delay, ModOnboardingConfig.noDataWithActivityGrace, accuracy: 1)

        // Time passes with the page open and no new snapshot: the one-shot recheck must
        // resample activity and turn "active" into "silent".
        clock = clock.addingTimeInterval(ModOnboardingConfig.noDataWithActivityGrace + 1)
        let silent = expectation(description: "silent after the grace period")
        coordinator.onStatusChange = { status in
            if status == .silent { silent.fulfill() }
        }
        DispatchQueue.main.async { scheduled.last?.1() }
        wait(for: [silent], timeout: 5)
        XCTAssertEqual(coordinator.status, .silent)
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
        // No scripted `plugin list` result means the probe failed: unknown, not absent.
        XCTAssertEqual(coordinator.status, .installationUnknown)
    }

    func testVisibleAdvancedCardDetectsExternalInstallAndDisableThenStopsWhenHidden() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled: [(TimeInterval, () -> Void)] = []
        let (coordinator, runner) = makeCoordinator(
            locator: "/bin/claude",
            results: [
                probeVersion, ModCommandResult(exitCode: 0, stdout: "[]", stderr: ""),
                probeVersion, listResult(),
                probeVersion, listResult(enabled: false),
                probeVersion, listResult(),
            ],
            now: { clock },
            schedule: { delay, block in scheduled.append((delay, block)) })

        let absent = expectation(description: "visible card detects the Mod is absent")
        coordinator.onStatusChange = { if $0 == .notInstalled(hasOtherScopeInstall: false) { absent.fulfill() } }
        coordinator.setAdvancedStatusCardVisible(true)
        wait(for: [absent], timeout: 5)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(scheduled.first?.0, ModSyncCoordinator.detectionThrottle)

        clock = clock.addingTimeInterval(ModSyncCoordinator.detectionThrottle)
        let installed = expectation(description: "visible card detects an external install")
        coordinator.onStatusChange = { if $0 == .waitingForData { installed.fulfill() } }
        let firstPoll = scheduled[0].1
        let firstPollRan = expectation(description: "first visible poll ran")
        DispatchQueue.main.async { firstPoll(); firstPollRan.fulfill() }
        wait(for: [firstPollRan], timeout: 5)
        wait(for: [installed], timeout: 5)
        XCTAssertEqual(runner.calls.count, 4)

        clock = clock.addingTimeInterval(ModSyncCoordinator.detectionThrottle)
        let disabled = expectation(description: "visible card detects an external disable")
        coordinator.onStatusChange = { if $0 == .disabled { disabled.fulfill() } }
        let secondPoll = scheduled[1].1
        let secondPollRan = expectation(description: "second visible poll ran")
        DispatchQueue.main.async { secondPoll(); secondPollRan.fulfill() }
        wait(for: [secondPollRan], timeout: 5)
        wait(for: [disabled], timeout: 5)
        XCTAssertEqual(runner.calls.count, 6)

        coordinator.setAdvancedStatusCardVisible(false)
        clock = clock.addingTimeInterval(ModSyncCoordinator.detectionThrottle)
        let callsWhenHidden = runner.calls.count
        let stalePoll = scheduled.last!.1
        let stalePollRan = expectation(description: "stale poll ran")
        DispatchQueue.main.async { stalePoll(); stalePollRan.fulfill() }
        wait(for: [stalePollRan], timeout: 5)
        XCTAssertEqual(runner.calls.count, callsWhenHidden, "hidden Advanced/search must stop environment probes")

        let reinstalled = expectation(description: "returning to Advanced refreshes after the throttle")
        coordinator.onStatusChange = { if $0 == .waitingForData { reinstalled.fulfill() } }
        coordinator.setAdvancedStatusCardVisible(true)
        wait(for: [reinstalled], timeout: 5)
        XCTAssertEqual(runner.calls.count, 8)
        coordinator.setAdvancedStatusCardVisible(false)
    }

    func testVisiblePollingDoesNotQueueDuplicateSlowDetection() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled: [(TimeInterval, () -> Void)] = []
        let (coordinator, runner) = makeCoordinator(
            locator: "/bin/claude",
            results: [probeVersion, listResult()],
            now: { clock },
            schedule: { delay, block in scheduled.append((delay, block)) })
        let listStarted = expectation(description: "slow plugin-list probe started")
        let releaseList = DispatchSemaphore(value: 0)
        let noQueuedProbe = expectation(description: "no duplicate probe is queued")
        noQueuedProbe.isInverted = true
        var callsSeen = 0
        runner.onRun = { arguments in
            callsSeen += 1
            if arguments == ModInstallPlan.listArguments {
                if callsSeen == 2 { listStarted.fulfill() }
                if callsSeen > 2 { noQueuedProbe.fulfill() }
                releaseList.wait()
            }
        }

        coordinator.setAdvancedStatusCardVisible(true)
        wait(for: [listStarted], timeout: 5)
        clock = clock.addingTimeInterval(ModSyncCoordinator.detectionThrottle)
        let firstPoll = expectation(description: "first poll skips in-flight detection")
        DispatchQueue.main.async { scheduled[0].1(); firstPoll.fulfill() }
        wait(for: [firstPoll], timeout: 5)
        clock = clock.addingTimeInterval(ModSyncCoordinator.detectionThrottle)
        let secondPoll = expectation(description: "second poll skips in-flight detection")
        DispatchQueue.main.async { scheduled[1].1(); secondPoll.fulfill() }
        wait(for: [secondPoll], timeout: 5)

        coordinator.setAdvancedStatusCardVisible(false)
        let firstDetectionFinished = expectation(description: "slow detection finished")
        coordinator.onStatusChange = { if $0 == .waitingForData { firstDetectionFinished.fulfill() } }
        releaseList.signal()
        releaseList.signal()
        wait(for: [firstDetectionFinished], timeout: 5)
        wait(for: [noQueuedProbe], timeout: 0.25)
        XCTAssertEqual(callsSeen, 2, "a slow detection must not leave a duplicate CLI probe queued")
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
        panel.perform(.showStatus)
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
            panel.snapshotLines.contains { $0.contains("<查看当前状态>") },
            "the reopened panel opens on the intro page for an installed Mod: \(panel.snapshotLines)")
        panel.perform(.showStatus)
        XCTAssertTrue(
            panel.snapshotLines.contains { $0.contains("<卸载 BalanceBar Mod>") },
            "the status page offers uninstall: \(panel.snapshotLines)")
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


// MARK: - Issue #604: management UI, no real CLI or visible GUI interaction

final class ModManagementUITests: XCTestCase {
    private func controller(runner: ScriptedRunner = ScriptedRunner([]), queue: DispatchQueue? = nil,
                            copied: @escaping (String) -> Void = { _ in }) -> ModOnboardingController {
        ModOnboardingController(installer: ModInstaller(
            locator: FakeLocator(path: "/test/claude"), runner: runner, prepareInbox: { true },
            workQueue: queue ?? DispatchQueue(label: "test.mod.ui"), callbackQueue: .main),
            preference: MemoryPreference(), copyToPasteboard: copied)
    }

    func testStandalonePromptWindowHasNoOwnerAndFloats() {
        let c = controller()
        let windows = ModOnboardingWindowController { ModOnboardingPanelView(controller: c) }
        defer { windows.close() }
        let panel = windows.prepare(owner: nil)
        XCTAssertNil(panel.parent)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isFloatingPanel)
        // The test host parks windows at a background level; the production level is
        // asserted only outside it.
        if !AutomatedTestHost.isRunning { XCTAssertEqual(panel.level, .floating) }
        let scroll = panel.contentView as? NSScrollView
        XCTAssertEqual(scroll?.verticalScrollElasticity, NSScrollView.Elasticity.none)
        XCTAssertEqual(scroll?.horizontalScrollElasticity, NSScrollView.Elasticity.none)
        windows.show()
        XCTAssertNil(panel.parent, "the menu prompt must never attach to the dashboard")
        XCTAssertTrue(panel.isVisible)
    }

    private func context(_ status: ModSyncStatus, language: AppLanguage = .english) -> ModPanelSyncContext {
        .init(status: status, statusText: RealtimeBoostPresentation.make(status: status, localize: {
            realtimeBoostLocalize($0, language: language)
        }).statusText)
    }

    private func content(_ state: ModPanelState, status: ModSyncStatus, language: AppLanguage = .english) -> [ModPanelItem] {
        ModPanelContent.items(for: state, plan: .standard, localize: {
            tr(LocalizationKey.key(for: $0), language: language)
        }, sync: context(status, language: language))
    }

    private var fixtures: [(String, ModPanelState, ModSyncStatus)] {
        let rejected: (ModSnapshotRejection) -> ModSyncStatus = {
            .snapshotRejected(.init(rejection: $0, at: Date(timeIntervalSince1970: 1_792_872_000)))
        }
        return [
            ("detecting", .intro(dismissChecked: false), .detecting),
            ("not-installed", .intro(dismissChecked: false), .notInstalled(hasOtherScopeInstall: false)),
            ("installation-unknown", .intro(dismissChecked: false), .installationUnknown),
            ("project-scope", .intro(dismissChecked: false), .notInstalled(hasOtherScopeInstall: true)),
            ("install-source", .installing(current: .addMarketplace), .notInstalled(hasOtherScopeInstall: false)),
            ("installing", .installing(current: .installPlugin), .notInstalled(hasOtherScopeInstall: false)),
            ("install-finish", .installing(current: .finish), .waitingForData),
            ("waiting", .succeeded, .waitingForData),
            ("waiting-management", .intro(dismissChecked: false), .waitingForData),
            ("trusted-success", .succeeded, .active(lastAcceptedAt: Date(timeIntervalSince1970: 1_792_872_000))),
            ("normal", .intro(dismissChecked: false), .active(lastAcceptedAt: Date(timeIntervalSince1970: 1_792_872_000))),
            ("silent", .intro(dismissChecked: false), .silent),
            ("disabled", .intro(dismissChecked: false), .disabled),
            ("account-rejected", .intro(dismissChecked: false), rejected(.accountMismatch)),
            ("cycle-rejected", .intro(dismissChecked: false), rejected(.unverifiedCycle)),
            ("cli-missing", .intro(dismissChecked: false), .claudeMissing),
            ("old-version", .intro(dismissChecked: false), .claudeVersionTooOld(.init(major: 2, minor: 1, patch: 200))),
            ("permission", .intro(dismissChecked: false), .inboxNotReady),
            ("failed", .failed(.commandFailed(step: .addMarketplace, exitCode: 1,
                detail: "Network unavailable. Check your connection and retry.")), .notInstalled(hasOtherScopeInstall: false)),
            ("install-permission", .failed(.inboxNotReady), .inboxNotReady),
            ("uninstalling", .uninstalling(current: .removeMarketplace), .waitingForData),
            ("uninstalled", .uninstallSucceeded, .notInstalled(hasOtherScopeInstall: false)),
            ("uninstall-failed", .uninstallFailed(.commandFailed(step: .uninstallPlugin, exitCode: 1,
                detail: "Permission denied")), .waitingForData),
        ]
    }

    func testLocalizedTimeAndVersionRemainReadableInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let active = context(.active(lastAcceptedAt: Date()), language: language).statusText
            XCTAssertFalse(active.contains("⟦"))
            XCTAssertTrue(active.contains(":"))
            let version = context(.claudeVersionTooOld(.init(major: 2, minor: 1, patch: 200)), language: language).statusText
            XCTAssertFalse(version.contains("⟦"))
            XCTAssertTrue(version.contains("2.1.200"))
            XCTAssertFalse(version.contains("%@"))
        }
    }

    func testEveryStatusHasAccurateActionsAndNoFalseRealtimeSuccess() {
        for (_, state, status) in fixtures {
            let items = content(state, status: status)
            XCTAssertFalse(items.isEmpty)
            let actions = items.compactMap { item -> ModPanelItem.ButtonAction? in
                if case let .button(_, action) = item { return action }; return nil
            }
            XCTAssertTrue(actions.contains(.close))
            if case .intro = state {
                XCTAssertEqual(actions.contains(.uninstall), ModPanelContent.isInstalled(status))
                if [.detecting, .claudeMissing].contains(status) {
                    XCTAssertFalse(actions.contains(.install))
                }
            }
        }
        let waiting = content(.succeeded, status: .waitingForData)
        XCTAssertFalse(waiting.contains(.step(label: tr(.modUIWaitingStep, language: .english), status: .done)))
        XCTAssertTrue(waiting.map(\.snapshotLine).joined().contains("trusted"))
        let active = content(.succeeded, status: .active(lastAcceptedAt: Date()))
        XCTAssertTrue(active.contains { item in
            if case let .hero(symbol, _, _) = item { return symbol == "checkmark.circle.fill" }; return false
        }, "only a trusted active status gets the original compact success hero")
        let missing = content(.succeeded, status: .notInstalled(hasOtherScopeInstall: false))
        XCTAssertTrue(missing.map(\.snapshotLine).contains(context(.notInstalled(hasOtherScopeInstall: false)).statusText),
                      "a detection result must not be replaced with a fabricated installed state")
    }

    func testUninstallRequiresExplicitConfirmationAndReturnIsSafe() throws {
        let runner = ScriptedRunner([ok, ok])
        let c = controller(runner: runner)
        let view = ModOnboardingPanelView(controller: c, syncProvider: { self.context(.waitingForData) })
        XCTAssertEqual(view.defaultButton?.identifier?.rawValue, "close")
        view.perform(.confirmUninstall)
        XCTAssertTrue(runner.calls.isEmpty)
        view.perform(.uninstall)
        XCTAssertTrue(view.isConfirmingUninstall)
        XCTAssertEqual(view.defaultButton?.identifier?.rawValue, "cancelUninstall")
        XCTAssertTrue(runner.calls.isEmpty)
        view.defaultButton?.performClick(nil)
        XCTAssertFalse(view.isConfirmingUninstall)
        XCTAssertTrue(runner.calls.isEmpty)
        view.perform(.uninstall)
        let finished = expectation(description: "confirmed uninstall")
        let render = c.onChange
        c.onChange = { render?(); if c.state == .uninstallSucceeded { finished.fulfill() } }
        view.perform(.confirmUninstall)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(runner.calls, [ModInstallPlan.standard.uninstallArguments, ModInstallPlan.standard.removeMarketplaceArguments])
    }

    func testConfirmationIsClearedByEnvironmentChange() {
        var status = ModSyncStatus.waitingForData
        let c = controller()
        let view = ModOnboardingPanelView(controller: c, syncProvider: { self.context(status) })
        view.perform(.uninstall)
        status = .notInstalled(hasOtherScopeInstall: false)
        view.reload()
        XCTAssertFalse(view.isConfirmingUninstall)
        view.perform(.confirmUninstall)
        XCTAssertEqual(c.state, .intro(dismissChecked: false))
    }

    func testCopyButtonsShowFeedbackAndCopyExactCommands() throws {
        var copied = ""
        let view = ModOnboardingPanelView(controller: controller(copied: { copied = $0 }),
            syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        let copy = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "copyCommands" })
        copy.performClick(nil)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableCommands)
        XCTAssertEqual(copy.title, ModOnboardingText.copied.defaultText)
        view.perform(.copyEnable)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableEnableCommand)
        view.perform(.copyReload)
        XCTAssertEqual(copied, ModInstallPlan.reloadCommand)
    }

    func testWindowCloseReopenPreservesInFlightOperationAndResetsFinishedPage() throws {
        let queue = DispatchQueue(label: "test.mod.ui.suspended")
        queue.suspend()
        let c = controller(runner: ScriptedRunner([ok, ok]), queue: queue)
        var buildCount = 0
        let windows = ModOnboardingWindowController {
            buildCount += 1
            c.resetToIntro()
            return ModOnboardingPanelView(controller: c, syncProvider: { self.context(.waitingForData) })
        }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        let panel = windows.prepare(owner: owner)
        defer { windows.close() }
        windows.show(owner: owner)
        XCTAssertTrue(panel.parent === owner)
        let openedCount = buildCount
        c.startInstall()
        panel.cancelOperation(nil)
        XCTAssertNil(panel.parent)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(c.state, .installing(current: .addMarketplace))
        XCTAssertTrue(windows.prepare(owner: owner) === panel)
        XCTAssertEqual(c.state, .installing(current: .addMarketplace))
        XCTAssertEqual(buildCount, openedCount + 1)
        XCTAssertTrue(windows.panelView?.snapshotLines.contains { $0.contains("[~]") } == true)
        let finished = expectation(description: "background install completes")
        let render = c.onChange
        c.onChange = { render?(); if c.state == .succeeded { finished.fulfill() } }
        queue.resume()
        wait(for: [finished], timeout: 5)
        windows.close()
        _ = windows.prepare(owner: owner)
        XCTAssertEqual(c.state, .intro(dismissChecked: false))
        XCTAssertTrue(windows.panelView?.snapshotLines.contains { $0.contains("<查看当前状态>") } == true)
        windows.panelView?.perform(.showStatus)
        XCTAssertTrue(windows.panelView?.snapshotLines.contains { $0.contains("<卸载 BalanceBar Mod>") } == true)
        // Owner close tears down its child even if settings navigation changed first.
        windows.show(owner: owner)
        XCTAssertTrue(panel.parent === owner)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.parent)
        XCTAssertEqual(c.state, .intro(dismissChecked: false))
    }

    func testAllLanguagesStatesAndWidthsRenderWithoutClippedText() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        for language in AppLanguage.allCases where language != .system {
            for appearance in appearances {
                let view = ModOnboardingPanelView(controller: controller(), localize: {
                    tr(LocalizationKey.key(for: $0), language: language)
                })
                view.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                for width: CGFloat in [420, 480, 760] {
                    view.setFrameSize(NSSize(width: width, height: 10))
                    for (name, state, status) in fixtures {
                        view.render(content(state, status: status, language: language))
                        view.layoutSubtreeIfNeeded()
                        let context = "\(language) \(appearance.rawValue) \(width) \(name)"
                        XCTAssertGreaterThan(view.frame.height, 100, context)
                        XCTAssertLessThan(view.frame.height, 2200, context)
                        for button in descendants(view).compactMap({ $0 as? NSButton }) {
                            let rect = view.convert(button.bounds, from: button)
                            XCTAssertGreaterThanOrEqual(rect.minX, -1, context)
                            XCTAssertLessThanOrEqual(rect.maxX, width + 1, context)
                            XCTAssertGreaterThanOrEqual(button.bounds.width + 1, button.fittingSize.width, context)
                        }
                        if name == "not-installed", width == 420 {
                            let suffix = appearance == .aqua ? "light" : "dark"
                            try export(view, name: "locale-\(language.rawValue)-\(suffix)")
                        }
                        for field in descendants(view).compactMap({ $0 as? NSTextField }) {
                            let rect = view.convert(field.bounds, from: field)
                            XCTAssertGreaterThanOrEqual(rect.minX, -1, context)
                            XCTAssertLessThanOrEqual(rect.maxX, width + 1, context)
                            XCTAssertGreaterThan(rect.height, 0, context)
                            let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)).height ?? 0
                            XCTAssertGreaterThanOrEqual(field.bounds.height + 1, needed, "clipped \(field.stringValue): \(context)")
                        }
                    }
                }
            }
        }
    }

    func testExportOfflineStateScreenshots() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceBar-Issue604-UI")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for language in [AppLanguage.english, .simplifiedChinese] {
                for (name, state, status) in fixtures {
                    let view = ModOnboardingPanelView(controller: controller(), localize: {
                        tr(LocalizationKey.key(for: $0), language: language)
                    })
                    view.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                    view.render(content(state, status: status, language: language))
                    view.layoutSubtreeIfNeeded()
                    let suffix = appearance == .aqua ? "light" : "dark"
                    let prefix = language == .english ? "after" : "int2-zh"
                    try export(view, name: "\(prefix)-\(name)-\(suffix)")
                }
            }
        }
        print("Offline UI fixtures: \(output.path)")
    }

    private func export(_ view: NSView, name: String) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceBar-Issue604-UI")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let path = output.appendingPathComponent("\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let attachment = XCTAttachment(contentsOfFile: path)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testConfirmationLayoutAndScreenshotsInEveryLanguage() throws {
        for language in AppLanguage.allCases where language != .system {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = ModOnboardingPanelView(controller: controller(), localize: {
                    tr(LocalizationKey.key(for: $0), language: language)
                }, syncProvider: { self.context(.waitingForData, language: language) })
                view.setFrameSize(NSSize(width: 420, height: 10))
                view.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                view.perform(.uninstall)
                view.layoutSubtreeIfNeeded()
                XCTAssertTrue(view.isConfirmingUninstall)
                XCTAssertEqual(view.defaultButton?.identifier?.rawValue, "cancelUninstall")
                for button in descendants(view).compactMap({ $0 as? NSButton }) {
                    XCTAssertGreaterThanOrEqual(button.bounds.width + 1, button.fittingSize.width)
                    let rect = view.convert(button.bounds, from: button)
                    XCTAssertGreaterThanOrEqual(rect.minX, -1)
                    XCTAssertLessThanOrEqual(rect.maxX, view.bounds.width + 1)
                }
                if language == .english {
                    try export(view, name: "after-confirmation-\(appearance == .aqua ? "light" : "dark")")
                }
            }
        }
    }

    func testScrollDocumentGrowsAfterShortPagesAndTracksWindowWidth() throws {
        let c = controller()
        let windows = ModOnboardingWindowController {
            ModOnboardingPanelView(controller: c, syncProvider: { self.context(.waitingForData) })
        }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        let panel = windows.prepare(owner: owner)
        defer { windows.close() }
        let view = try XCTUnwrap(windows.panelView)
        let scroll = try XCTUnwrap(panel.contentView as? NSScrollView)
        for width: CGFloat in [420, 760, 480] {
            panel.setContentSize(NSSize(width: width, height: 360))
            panel.layoutIfNeeded()
            for (_, state, status) in fixtures {
                view.render(content(state, status: status))
                panel.layoutIfNeeded()
                XCTAssertEqual(view.frame.width, scroll.contentSize.width, accuracy: 1)
                XCTAssertEqual(view.frame.height, view.fittingSize.height, accuracy: 1)
                for field in descendants(view).compactMap({ $0 as? NSTextField }) {
                    let rect = view.convert(field.bounds, from: field)
                    XCTAssertLessThanOrEqual(rect.maxY, view.bounds.height + 1)
                    XCTAssertGreaterThanOrEqual(rect.minY, -1)
                }
            }
        }
    }

    func testExplicitRefreshCallsTheExistingDetectionHook() {
        let view = ModOnboardingPanelView(controller: controller(), syncProvider: { self.context(.claudeMissing) })
        var refreshes = 0
        view.onRequestRefresh = { refreshes += 1 }
        view.perform(.refresh)
        XCTAssertEqual(refreshes, 1)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

// MARK: - INT-2 Advanced settings card restoration
final class RealtimeBoostAdvancedCardTests: XCTestCase {
    private func rows(_ status: ModSyncStatus, operation: ModPanelState = .intro(dismissChecked: false),
                      install: @escaping (NSButton) -> Void = { _ in },
                      describe: @escaping (NSButton) -> Void = { _ in }) -> RealtimeBoostSettingsRows {
        RealtimeBoostSettingsRows(status: status, operation: operation,
            localize: { realtimeBoostLocalize($0, language: .english) },
            modLocalize: { tr(LocalizationKey.key(for: $0), language: .english) },
            onInstall: install, onShowDescription: describe)
    }

    private func cardCopy(
        _ status: ModSyncStatus,
        operation: ModPanelState = .intro(dismissChecked: false),
        language: AppLanguage = .simplifiedChinese
    ) -> RealtimeBoostCardCopy {
        RealtimeBoostSettingsRows.cardCopy(
            status: status,
            operation: operation,
            localize: { realtimeBoostLocalize($0, language: language) },
            modLocalize: { tr(LocalizationKey.key(for: $0), language: language) },
            timeZone: TimeZone(identifier: "UTC")!)
    }

    private func statusLine(_ row: SettingsRowView) -> String {
        row.detailLabel.stringValue.components(separatedBy: "\n").last ?? ""
    }

    func testHistoricalStatusTitleAndLatestDataUseSeparateLines() {
        let card = rows(.active(lastAcceptedAt: Date()))
        XCTAssertEqual(card.statusRow.titleLabel.stringValue, "BalanceBar Mod realtime boost")
        XCTAssertTrue(statusLine(card.statusRow).hasPrefix("● Enabled · Last trusted data: "))
        XCTAssertTrue(card.installButton.isHidden)
        XCTAssertEqual(card.descriptionButton.title, "Learn more")
        card.update(status: .silent, operation: .intro(dismissChecked: false))
        XCTAssertEqual(card.statusRow.titleLabel.stringValue, "BalanceBar Mod realtime boost")
        XCTAssertEqual(card.statusRow.detailLabel.stringValue,
                       "Recommended for the Claude desktop app, also works in the terminal; pushes quota in real time during chats"
                       + "\n● No recent data · No data in the last 10 minutes · Start a new session, or run /reload-plugins",
                       "line one names the audience, line two carries the status")
    }

    func testInstallAndDescriptionCallbacksKeepTheirOriginalSender() {
        var installed: NSButton?
        var described: NSButton?
        let card = rows(.notInstalled(hasOtherScopeInstall: false), install: { installed = $0 }, describe: { described = $0 })
        XCTAssertFalse(card.installButton.isHidden)
        XCTAssertEqual(card.descriptionButton.title, "Learn more")
        card.installButton.performClick(nil)
        card.descriptionButton.performClick(nil)
        XCTAssertTrue(installed === card.installButton)
        XCTAssertTrue(described === card.descriptionButton)
    }

    func testOperationProgressAndFailuresDoNotBecomeRealtimeSuccess() {
        let card = rows(.notInstalled(hasOtherScopeInstall: false), operation: .installing(current: .installPlugin))
        XCTAssertTrue(card.installButton.isHidden)
        XCTAssertEqual(card.descriptionButton.title, "Manage")
        XCTAssertTrue(card.statusRow.detailLabel.stringValue.contains("Install Mod"))
        card.update(status: .waitingForData, operation: .succeeded)
        XCTAssertTrue(statusLine(card.statusRow).hasPrefix("● Waiting for data"))
        XCTAssertFalse(card.statusRow.detailLabel.stringValue.contains("Enabled"))
        card.update(status: .notInstalled(hasOtherScopeInstall: false), operation: .failed(.inboxNotReady))
        XCTAssertFalse(card.installButton.isHidden)
        XCTAssertEqual(card.descriptionButton.title, "View error")
        card.update(status: .waitingForData, operation: .uninstalling(current: .removeMarketplace))
        XCTAssertTrue(card.statusRow.detailLabel.stringValue.contains("Remove"))
        XCTAssertTrue(card.installButton.isHidden)
    }

    func testDetectingAndUnsupportedEnvironmentsDoNotOfferDirectInstall() {
        for status in [ModSyncStatus.detecting, .claudeMissing, .claudeVersionTooOld(.init(major: 2, minor: 0, patch: 0))] {
            XCTAssertTrue(rows(status).installButton.isHidden)
        }
        XCTAssertFalse(rows(.inboxNotReady).installButton.isHidden)
        XCTAssertEqual(rows(.disabled).descriptionButton.title, "Learn more")
    }

    func testGeneralRefreshSectionHostsTheModRowRightAfterNativeSyncAndAdvancedOnlyHasDiagnostics() throws {
        let old = AppLanguage.selected
        AppLanguage.selected = .english
        defer { AppLanguage.selected = old }
        let advanced = DashboardAdvancedPage().make(.init(relay: DashboardPreferencePageRelay(), logViewer: nil))
        let advancedSections = descendants(advanced).compactMap { $0 as? SettingsSectionView }
        XCTAssertEqual(advancedSections.map { $0.headingLabel.stringValue }, ["Diagnostics"])

        let page = DashboardGeneralPage()
        let general = page.make(.init(preferences: AppPreferences(), relay: DashboardPreferencePageRelay(),
            updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
            modSyncStatus: .notInstalled(hasOtherScopeInstall: false)))
        let refreshSection = try XCTUnwrap(descendants(general).compactMap { $0 as? SettingsSectionView }
            .first { $0.contentViews.contains { ($0 as? SettingsRowView)?.titleLabel.stringValue == "BalanceBar Mod realtime boost" } })
        let rows = refreshSection.contentViews.compactMap { $0 as? SettingsRowView }
        let nativeSync = try XCTUnwrap(rows.firstIndex { $0.titleLabel.stringValue == tr(.keyClaudeStatusLineEnabled) })
        let mod = try XCTUnwrap(rows.firstIndex { $0.titleLabel.stringValue == "BalanceBar Mod realtime boost" })
        XCTAssertEqual(mod, nativeSync + 1, "the Mod row sits directly below Claude Code native sync")

        let card = rows[mod]
        XCTAssertEqual(card.identifier, DashboardPageSearch.rowIdentifier)
        XCTAssertEqual(statusLine(card), "● Not installed · Install to sync quota in real time")
        page.refreshModSync(.active(lastAcceptedAt: Date()), operation: .succeeded)
        XCTAssertEqual(card.titleLabel.stringValue, "BalanceBar Mod realtime boost")
        XCTAssertTrue(statusLine(card).hasPrefix("● Enabled · "))
    }

    func testModRowTitleHoldsOnlyTheClaudeMarkAndTheStatusDotLeadsTheSubtitle() throws {
        let card = rows(.waitingForData)
        let accessory = try XCTUnwrap(card.statusRow.titleAccessory)
        XCTAssertTrue(accessory is AgentIconStripView, "the title accessory is the Claude mark only")
        func dotColor(_ status: ModSyncStatus, operation: ModPanelState = .intro(dismissChecked: false)) -> NSColor? {
            card.update(status: status, operation: operation)
            let text = card.statusRow.detailLabel.attributedStringValue
            let dot = (text.string as NSString).range(of: "\n● ")
            XCTAssertNotEqual(dot.location, NSNotFound, "the dot leads the second (status) line")
            return text.attribute(.foregroundColor, at: dot.location + 1, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(dotColor(.active(lastAcceptedAt: Date())), .systemGreen)
        XCTAssertEqual(dotColor(.silent), .systemOrange)
        XCTAssertEqual(dotColor(.notInstalled(hasOtherScopeInstall: false)), .tertiaryLabelColor)
        XCTAssertEqual(dotColor(.inboxNotReady), .systemRed)
        XCTAssertEqual(dotColor(.notInstalled(hasOtherScopeInstall: false), operation: .failed(.inboxNotReady)), .systemRed)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
        let section = SettingsSectionView(title: "R", contentViews: [card.statusRow])
        section.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(section)
        NSLayoutConstraint.activate([section.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            section.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            section.topAnchor.constraint(equalTo: host.topAnchor, constant: 24)])
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(accessory.bounds.width, 60, "the accessory must hug the Claude mark, not stretch")
        XCTAssertEqual(card.statusRow.titleLabel.frame.height, 17, accuracy: 4, "the fixed row title stays on one line")
    }

    private func panelView(_ status: ModSyncStatus) -> ModOnboardingPanelView {
        let controller = ModOnboardingController(preference: MemoryPreference())
        let ctx = ModPanelSyncContext(status: status, statusText: RealtimeBoostPresentation.make(status: status).statusText)
        let view = ModOnboardingPanelView(controller: controller, syncProvider: { ctx })
        view.reload()
        return view
    }

    func testInstalledModOpensOnTheOverviewThenShowsStatusAndCanGoBack() throws {
        let view = panelView(.silent)
        XCTAssertTrue(view.snapshotLines.contains("<\(ModOnboardingText.viewStatus.defaultText)>"))
        XCTAssertTrue(view.snapshotLines.contains { $0.contains(ModOnboardingText.feature1Title.defaultText) })
        XCTAssertFalse(view.snapshotLines.contains { $0.contains(ModOnboardingText.silentTitle.defaultText) },
                       "status details stay behind the button")
        func click(_ title: String) throws {
            func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
            try XCTUnwrap(buttons(view).first { $0.title == title }, title).performClick(nil)
        }
        try click(ModOnboardingText.viewStatus.defaultText)
        XCTAssertTrue(view.snapshotLines.contains { $0.contains(ModOnboardingText.silentTitle.defaultText) })
        XCTAssertTrue(view.snapshotLines.contains("<\(ModOnboardingText.backToIntro.defaultText)>"))
        try click(ModOnboardingText.backToIntro.defaultText)
        XCTAssertTrue(view.snapshotLines.contains("<\(ModOnboardingText.viewStatus.defaultText)>"))
    }

    func testPanelIsWideEnoughForTheStatusPageFooterOnOneLineInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let t: (ModOnboardingText) -> String = { tr(LocalizationKey.key(for: $0), language: language) }
            let width = ModOnboardingPanelView.requiredWidth(localize: t)
            let needed = [t(.uninstallButton), t(.refresh), t(.backToIntro), t(.closeButton)].reduce(CGFloat(48)) { total, title in
                let b = NSButton(title: title, target: nil, action: nil)
                b.bezelStyle = .push; b.controlSize = .large
                return total + b.fittingSize.width + 10
            }
            XCTAssertGreaterThanOrEqual(width, min(needed, ModOnboardingPanelView.maximumWidth), "\(language)")
        }
    }

    func testUninstallConfirmationUsesItsOwnPlainCopy() {
        let view = panelView(.active(lastAcceptedAt: Date()))
        view.perform(.showStatus)
        view.perform(.uninstall)
        XCTAssertTrue(view.isConfirmingUninstall)
        let lines = view.snapshotLines
        XCTAssertTrue(lines.contains { $0.contains("卸载 BalanceBar Mod？") })
        XCTAssertTrue(lines.contains { $0.contains("定时向官方查询") && !$0.contains("statusLine") })
        XCTAssertTrue(lines.contains("<卸载>"))
        XCTAssertTrue(lines.contains("<取消>"))
    }

    func testUninstallConfirmationCopyExistsInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            for text in [ModOnboardingText.confirmUninstall, .confirmUninstallNote, .confirmUninstallAction] {
                let value = tr(LocalizationKey.key(for: text), language: language)
                XCTAssertFalse(value.isEmpty, "\(language): \(text.rawValue)")
                XCTAssertNotEqual(value, text.rawValue, "\(language): missing \(text.rawValue)")
            }
            XCTAssertFalse(tr(LocalizationKey.key(for: .confirmUninstallNote), language: language).contains("statusLine"), "\(language)")
        }
    }

    func testReloadHintPointsAtTheCommandBelowInsteadOfRepeatingIt() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertFalse(tr(LocalizationKey.key(for: ModOnboardingText.reloadHint), language: language).contains("/reload-plugins"), "\(language)")
        }
        let view = panelView(.waitingForData)
        view.perform(.showStatus)
        let lines = view.snapshotLines
        let hint = lines.firstIndex(of: ModOnboardingText.reloadHint.defaultText)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint.map { lines[$0 + 1] }, "$ /reload-plugins", "the command follows its hint")
    }

    func testStatusPageForActiveModExplainsLastTrustedData() {
        let view = panelView(.active(lastAcceptedAt: Date()))
        view.perform(.showStatus)
        XCTAssertTrue(view.snapshotLines.contains(ModOnboardingText.lastDataNote.defaultText))
    }

    func testNotInstalledPanelKeepsTheIntroWithoutStatusButtons() {
        let view = panelView(.notInstalled(hasOtherScopeInstall: false))
        XCTAssertFalse(view.snapshotLines.contains("<\(ModOnboardingText.viewStatus.defaultText)>"))
        XCTAssertTrue(view.snapshotLines.contains("<\(ModOnboardingText.installButton.defaultText)>"))
    }

    func testPanelOverviewCopyExistsInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            for text in [ModOnboardingText.viewStatus, .backToIntro, .lastDataNote] {
                let value = tr(LocalizationKey.key(for: text), language: language)
                XCTAssertFalse(value.isEmpty, "\(language): \(text.rawValue)")
                XCTAssertNotEqual(value, text.rawValue, "\(language): missing \(text.rawValue)")
            }
            XCTAssertNotEqual(realtimeBoostLocalize(.cardLearnMore, language: language), "mod.card.learn_more", "\(language)")
        }
    }

    func testRowTitleIsFixedAndStatusWordLeadsTheSubtitleInChineseAndEnglish() {
        let now = Date(timeIntervalSince1970: 1_767_274_800)
        let accountRejection = ModSyncStatus.snapshotRejected(.init(rejection: .accountMismatch, at: now))
        let cycleRejection = ModSyncStatus.snapshotRejected(.init(rejection: .unverifiedCycle, at: now))
        let statuses: [ModSyncStatus] = [
            .detecting,
            .notInstalled(hasOtherScopeInstall: false),
            .notInstalled(hasOtherScopeInstall: true),
            .active(lastAcceptedAt: now),
            .waitingForData,
            .silent,
            .disabled,
            .claudeMissing,
            .claudeVersionTooOld(.init(major: 2, minor: 1, patch: 100)),
            .inboxNotReady,
            accountRejection,
            cycleRejection,
            .installationUnknown,
        ]

        for language in [AppLanguage.simplifiedChinese, .english] {
            for status in statuses {
                let word = cardCopy(status, language: language).status
                XCTAssertFalse(word.contains("BalanceBar Mod"), "\(language): \(word)")
                XCTAssertFalse(word.contains("：") || word.contains(":"), "\(language): \(word)")
                XCTAssertFalse(word.contains("。"), "\(language): \(word)")
                XCTAssertLessThanOrEqual(word.count, 20, "\(language): \(word)")
                XCTAssertFalse(cardCopy(status, language: language).detail.contains("\n"), "\(language): one line")
            }
        }
    }

    func testCardDetailSplitsReasonAndAction() {
        func assertCopy(
            _ status: ModSyncStatus,
            operation: ModPanelState = .intro(dismissChecked: false),
            title: String,
            reason: String?,
            action: String?
        ) {
            let copy = cardCopy(status, operation: operation)
            XCTAssertEqual(copy.status, title)
            XCTAssertEqual(copy.reason, reason)
            XCTAssertEqual(copy.action, action)
            XCTAssertEqual(copy.detail, [title, reason, action].compactMap { $0 }.joined(separator: " · "))
        }

        assertCopy(.notInstalled(hasOtherScopeInstall: false), title: "未安装",
                   reason: "安装后可实时同步额度", action: nil)
        assertCopy(.notInstalled(hasOtherScopeInstall: true), title: "仅项目级安装",
                   reason: "只在该项目内生效", action: "点「一键安装」装到用户级")
        assertCopy(.waitingForData, title: "等待数据",
                   reason: "已安装，还没收到会话数据", action: "新开一个 Claude 会话即可")
        assertCopy(.silent, title: "暂无数据",
                   reason: "10 分钟内没有收到数据", action: "新开会话，或运行 /reload-plugins")
        assertCopy(.disabled, title: "已停用",
                   reason: "插件已安装，但被停用", action: "点「了解更多」查看启用方法")
        assertCopy(.claudeMissing, title: "未找到 Claude Code",
                   reason: "系统中没有 claude 命令", action: "安装 Claude Code 后重试")
        assertCopy(.claudeVersionTooOld(.init(major: 2, minor: 1, patch: 100)), title: "版本过旧",
                   reason: "当前 Claude Code 2.1.100", action: "请升级到 v2.1.287 或更高")
        assertCopy(.inboxNotReady, title: "收件箱不可用",
                   reason: "权限不足或所有者不符", action: "点「一键安装」重建")
        assertCopy(.snapshotRejected(.init(rejection: .accountMismatch, at: Date())), title: "数据被拒绝",
                   reason: "Claude 与 BalanceBar 登录的账号不同", action: "请切换到同一账号")
        assertCopy(.snapshotRejected(.init(rejection: .unverifiedCycle, at: Date())), title: "数据被拒绝",
                   reason: "周期与官方数据不一致", action: "已改用官方额度")
        assertCopy(.installationUnknown, title: "状态未知",
                   reason: "读取插件列表失败", action: "稍后重试")
        assertCopy(.notInstalled(hasOtherScopeInstall: false),
                   operation: .installing(current: .installPlugin), title: "未安装",
                   reason: "安装 Mod…", action: nil)
        assertCopy(.waitingForData, operation: .uninstalling(current: .removeMarketplace),
                   title: "等待数据", reason: "移除安装来源…", action: nil)
        assertCopy(.notInstalled(hasOtherScopeInstall: false), operation: .failed(.inboxNotReady),
                   title: "安装失败", reason: "无法自动安装", action: "点「查看原因」了解详情")
        assertCopy(.waitingForData, operation: .uninstallFailed(.commandFailed(step: .removeMarketplace, exitCode: 1, detail: "")),
                   title: "卸载失败", reason: "卸载未完成", action: "点「查看原因」了解详情")
    }

    func testCardCopyExistsInEveryLanguage() {
        let cardTexts = RealtimeBoostText.allCases.filter { $0.rawValue.hasPrefix("mod.card.") }
        XCTAssertFalse(cardTexts.isEmpty)
        for language in AppLanguage.allCases where language != .system {
            for text in cardTexts {
                let value = realtimeBoostLocalize(text, language: language)
                XCTAssertFalse(value.isEmpty, "\(language): \(text.rawValue)")
                XCTAssertNotEqual(value, text.rawValue, "\(language): missing \(text.rawValue)")
            }
        }
    }

    func testCardActionNamesMatchButtonTitlesInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let localize: (RealtimeBoostText) -> String = { realtimeBoostLocalize($0, language: language) }
            let install = localize(.install)
            let learnMore = localize(.cardLearnMore)
            let viewError = localize(.viewError)
            let projectAction = cardCopy(.notInstalled(hasOtherScopeInstall: true), language: language).action
            let inboxAction = cardCopy(.inboxNotReady, language: language).action
            let disabledAction = cardCopy(.disabled, language: language).action
            let failedAction = cardCopy(.notInstalled(hasOtherScopeInstall: false),
                                        operation: .failed(.inboxNotReady), language: language).action
            XCTAssertTrue(projectAction?.contains(install) == true, "\(language): \(projectAction ?? "nil")")
            XCTAssertTrue(inboxAction?.contains(install) == true, "\(language): \(inboxAction ?? "nil")")
            XCTAssertTrue(disabledAction?.contains(learnMore) == true, "\(language): \(disabledAction ?? "nil")")
            XCTAssertTrue(failedAction?.contains(viewError) == true, "\(language): \(failedAction ?? "nil")")
        }
    }

    func testSearchFindsTheModRowOnTheGeneralPageFromAnotherSettingsPage() {
        let old = AppLanguage.selected
        defer { AppLanguage.selected = old }
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.selected = language
            for key in [LocalizationKey.modSettingsTitle, .modSettingsViewNote, .modSettingsManage, .modSyncStatusDetecting,
                        .modCardRowTitle] {
                let query = tr(key)
                XCTAssertTrue(DashboardSettingsSearchCatalog.matchingSections(query: query).contains(.general))
            }
            XCTAssertFalse(DashboardSettingsSearchCatalog.keys(for: .advanced).contains(.keyClaudeModSyncTitle))
        }
    }

    func testSettingsProgressObserverDoesNotReplacePanelOrChangeSyncFacts() {
        let controller = ModOnboardingController(preference: MemoryPreference())
        let coordinator = ModSyncCoordinator(controller: controller, detector: ModSyncDetector(), activityProvider: { false })
        let panel = coordinator.attachPanel()
        var presentations = 0
        var statusChanges = 0
        coordinator.onPresentationChange = { presentations += 1 }
        coordinator.onStatusChange = { _ in statusChanges += 1 }
        controller.setDismissChecked(true)
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(statusChanges, 0)
        XCTAssertEqual(coordinator.status, .detecting)
        XCTAssertEqual(panel.snapshotLines, ModPanelContent.items(for: controller.state, plan: .standard,
            localize: ModOnboardingText.defaultLocalize, sync: coordinator.syncContext).map(\.snapshotLine))
    }

    func testViewErrorRetainsTheActualFailureWhenOpeningManagement() {
        let controller = ModOnboardingController(installer: ModInstaller(
            locator: FakeLocator(path: nil), runner: ScriptedRunner([]), prepareInbox: { true }),
            preference: MemoryPreference())
        let coordinator = ModSyncCoordinator(controller: controller,
            detector: ModSyncDetector(locator: FakeLocator(path: nil)), activityProvider: { false })
        let failed = expectation(description: "installation fails without CLI")
        controller.onChange = { if controller.state == .failed(.claudeNotFound) { failed.fulfill() } }
        controller.startInstall()
        wait(for: [failed], timeout: 5)
        let panel = coordinator.attachPanel()
        XCTAssertEqual(controller.state, .failed(.claudeNotFound))
        XCTAssertTrue(panel.snapshotLines.contains { $0.contains(ModOnboardingText.failureClaudeMissing.defaultText) })
        // The underlying explicit reset behavior is unchanged.
        controller.resetToIntro()
        XCTAssertEqual(controller.state, .intro(dismissChecked: false))
    }

    func testExportAdvancedCardsInBothAppearancesAndAllLanguages() throws {
        let previous = AppLanguage.selected
        let originalAppearance = NSApp.appearance
        defer { AppLanguage.selected = previous; NSApp.appearance = originalAppearance }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceBar-Issue604-Advanced")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, ModSyncStatus, ModPanelState)] = [
            ("not-installed", .notInstalled(hasOtherScopeInstall: false), .intro(dismissChecked: false)),
            ("installing", .notInstalled(hasOtherScopeInstall: false), .installing(current: .installPlugin)),
            ("waiting", .waitingForData, .succeeded),
            ("active", .active(lastAcceptedAt: Date(timeIntervalSince1970: 1_792_872_000)), .intro(dismissChecked: false)),
            ("silent", .silent, .intro(dismissChecked: false)),
            ("failed", .inboxNotReady, .failed(.inboxNotReady)),
            ("uninstalling", .waitingForData, .uninstalling(current: .removeMarketplace))]
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.selected = language
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                // Dashboard chrome follows the application's effective appearance.
                NSApp.appearance = NSAppearance(named: appearance)
                for width: CGFloat in [420, 760] {
                    for (name, status, operation) in states {
                        let page = DashboardGeneralPage()
                        let narrowCard = RealtimeBoostSettingsRows(status: status, operation: operation,
                            onInstall: { _ in }, onShowDescription: { _ in })
                        // 420pt stress-tests the row alone. The full General page
                        // also contains the other settings; its supported
                        // window width starts at 800pt, including the sidebar.
                        let content: NSView = width == 420
                            ? SettingsSectionView(title: tr(.keyDashboardGeneralAndRefreshPagesRefresh), contentViews: [narrowCard.statusRow])
                            : page.make(.init(preferences: AppPreferences(), relay: DashboardPreferencePageRelay(),
                                              updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
                                              modSyncStatus: status, modPanelState: operation))
                        let host = AdvancedCardRenderHost(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
                        host.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                        content.translatesAutoresizingMaskIntoConstraints = false
                        host.addSubview(content)
                        NSLayoutConstraint.activate([
                            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
                            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
                            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24)])
                        host.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                        host.layoutSubtreeIfNeeded()
                        host.setFrameSize(NSSize(width: width, height: content.fittingSize.height + 48))
                        host.layoutSubtreeIfNeeded()
                        for field in descendants(content).compactMap({ $0 as? NSTextField }) where !field.isHidden {
                            let rect = host.convert(field.bounds, from: field)
                            XCTAssertGreaterThanOrEqual(rect.minX, -1, "\(language) \(width) \(name)")
                            XCTAssertLessThanOrEqual(rect.maxX, width + 1, "\(language) \(width) \(name)")
                        }
                        if width == 760 && (language == .simplifiedChinese || language == .english)
                            || width == 420 && name == "not-installed" {
                            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            let suffix = appearance == .aqua ? "light" : "dark"
                            let path = output.appendingPathComponent("\(language.rawValue)-\(name)-\(Int(width))-\(suffix).png")
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
                            let attachment = XCTAttachment(contentsOfFile: path)
                            attachment.lifetime = .keepAlways
                            add(attachment)
                        }
                    }
                }
            }
        }
        print("Advanced card offline renders: \(output.path)")
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

private final class AdvancedCardRenderHost: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

// MARK: - INT-2 window appearance, connected to the current safe controller
final class ModInt2WindowRestorationTests: XCTestCase {
    private func context(_ status: ModSyncStatus) -> ModPanelSyncContext {
        .init(status: status, statusText: RealtimeBoostPresentation.make(status: status).statusText)
    }
    private func controller(copied: @escaping (String) -> Void = { _ in }) -> ModOnboardingController {
        ModOnboardingController(preference: MemoryPreference(), copyToPasteboard: copied)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testInstallationUnknownCopyCopiesTheListCommand() throws {
        var copied = ""
        let c = controller(copied: { copied = $0 })
        let view = ModOnboardingPanelView(controller: c,
            syncProvider: { self.context(.installationUnknown) })
        let copy = try XCTUnwrap(descendants(view).compactMap { $0 as? ModCopyButton }.first)
        XCTAssertEqual(copy.identifier?.rawValue, "copyList")
        copy.performClick(nil)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableListCommand,
                       "the read-only probe must copy the list command, never the install commands")
        XCTAssertTrue(view.snapshotLines.contains { $0.contains("claude plugin list --json") })
    }

    func testPitchUsesOriginalHeroFourPointsAndFooterWithoutStatusCard() throws {
        let items = ModPanelContent.items(for: .intro(dismissChecked: false), plan: .standard,
            localize: ModOnboardingText.defaultLocalize, sync: context(.notInstalled(hasOtherScopeInstall: false)))
        XCTAssertEqual(items.first, .hero(symbol: nil, title: ModOnboardingText.pitchTitle.defaultText,
                                         subtitle: ModOnboardingText.pitchSubtitle.defaultText))
        let symbols = items.compactMap { item -> String? in
            if case let .feature(symbol, _, _) = item { return symbol }; return nil
        }
        XCTAssertEqual(symbols, ["bolt.fill", "terminal", "gauge.with.dots.needle.33percent", "lock.shield"])
        XCTAssertFalse(items.contains { if case .text = $0 { return true }; return false }, "the pitch has no separate status panel between its hero and points")
        let view = ModOnboardingPanelView(controller: controller(), syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        let copy = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "copyCommands" })
        let later = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "close" })
        let install = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "install" })
        XCTAssertEqual(later.title, "稍后")
        XCTAssertEqual(view.defaultButton?.identifier?.rawValue, "install")
        let frames = [copy, later, install].map { view.convert($0.bounds, from: $0) }
        XCTAssertEqual(frames[0].midY, frames[2].midY, accuracy: 1)
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        XCTAssertTrue([copy, later, install].allSatisfy { $0.controlSize == .large })
        // The menu-prompt preference sits above the footer as a regular checkbox.
        let promptCheckbox = try XCTUnwrap(buttons.first {
            $0.title == ModOnboardingText.dismissCheckbox.defaultText
        })
        XCTAssertEqual(promptCheckbox.state, .off)
    }

    func testMenuPromptCheckboxDisablesTheStatusMenuPrompt() throws {
        let pref = MemoryPreference()
        let c = ModOnboardingController(preference: pref)
        let view = ModOnboardingPanelView(controller: c,
            syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        var changes = 0
        view.onPromptPreferenceChange = { changes += 1 }
        let box = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.title == ModOnboardingText.dismissCheckbox.defaultText
        })
        XCTAssertEqual(box.state, .off)
        box.performClick(nil)
        XCTAssertEqual(box.state, .on)
        // INT-2 timing: checking marks the box; the prompt is hidden on "Later".
        XCTAssertFalse(c.isPromptDismissed)
        XCTAssertEqual(c.state, .intro(dismissChecked: true))
        XCTAssertEqual(changes, 0)
        view.perform(.close)
        XCTAssertTrue(c.isPromptDismissed)
        XCTAssertEqual(c.state, .dismissConfirmed)
        XCTAssertEqual(changes, 1)
    }

    func testPanelChromeAvoidsAccidentalScrollingSelectionAndSecondClick() throws {
        let c = ModOnboardingController(preference: MemoryPreference())
        let view = ModOnboardingPanelView(controller: c,
            syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        XCTAssertTrue(descendants(view).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isSelectable },
                      "panel copy must not be selectable")
        let box = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.title == ModOnboardingText.dismissCheckbox.defaultText
        })
        XCTAssertTrue(box.acceptsFirstMouse(for: nil), "the checkbox must react to the first click")
        let heroHeight = view.frame.height
        view.render(ModPanelContent.items(for: .dismissConfirmed, plan: .standard,
            localize: ModOnboardingText.defaultLocalize,
            sync: self.context(.notInstalled(hasOtherScopeInstall: false))))
        XCTAssertLessThan(view.frame.height, heroHeight, "a short page must shrink the window")
        XCTAssertLessThan(view.frame.height, 400)
    }

    func testDismissCheckSurvivesPanelReloadBeforeLater() throws {
        let c = ModOnboardingController(preference: MemoryPreference())
        let view = ModOnboardingPanelView(controller: c,
            syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        func checkbox() throws -> NSButton {
            try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
                $0.title == ModOnboardingText.dismissCheckbox.defaultText
            })
        }
        let box = try checkbox()
        box.performClick(nil)
        XCTAssertTrue(c.isDismissCheckboxChecked)
        XCTAssertFalse(c.isPromptDismissed, "the preference is written on Later, not on check")
        view.reload()
        XCTAssertEqual(try checkbox().state, .on, "a reload must not visually clear the checked box")
    }

    func testLaterAfterDismissShowsAdvancedGuidanceAndUndoRestores() throws {
        let pref = MemoryPreference()
        let c = ModOnboardingController(preference: pref)
        let view = ModOnboardingPanelView(controller: c,
            syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
        let box = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.title == ModOnboardingText.dismissCheckbox.defaultText
        })
        box.performClick(nil)
        view.perform(.close)
        XCTAssertEqual(c.state, .dismissConfirmed, "Later must show the guidance page, not close")
        XCTAssertTrue(view.snapshotLines.contains { $0.contains("之后可以在 设置 › 通用 › 刷新 中安装 BalanceBar Mod。") })
        view.perform(.undoDismiss)
        XCTAssertFalse(c.isPromptDismissed)
        XCTAssertEqual(c.state, .intro(dismissChecked: false))
    }

    func testInlineReloadCopyHasOriginalCheckmarkFeedback() throws {
        var copied = ""
        let view = ModOnboardingPanelView(controller: controller(copied: { copied = $0 }),
            syncProvider: { self.context(.waitingForData) })
        view.perform(.showStatus)
        let copy = try XCTUnwrap(descendants(view).compactMap { $0 as? ModCopyButton }.first)
        XCTAssertEqual(copy.identifier?.rawValue, "copyReload")
        let rect = view.convert(copy.bounds, from: copy)
        XCTAssertEqual(rect.maxX, view.bounds.maxX - 30, accuracy: 1, "copy stays pinned to the right edge of the code block")
        copy.performClick(nil)
        XCTAssertEqual(copied, ModInstallPlan.reloadCommand)
        XCTAssertTrue(copy.isShowingFeedback)
        XCTAssertEqual(descendants(view).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue == "copyReload"
        }.count, 1, "the code block replaces the duplicate footer copy button")
    }

    func testFailureAndInstalledPagesUseTheirOriginalDedicatedLayouts() {
        let failed = ModPanelContent.items(for: .failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "one\ntwo\nthree")),
            plan: .standard, localize: ModOnboardingText.defaultLocalize, sync: context(.notInstalled(hasOtherScopeInstall: false)))
        XCTAssertTrue(failed.contains(.detail("one\ntwo")))
        XCTAssertTrue(failed.contains { if case .codeBlock = $0 { return true }; return false })
        let installed = ModPanelContent.items(for: .intro(dismissChecked: false), plan: .standard,
            localize: ModOnboardingText.defaultLocalize, sync: context(.active(lastAcceptedAt: Date())))
        XCTAssertTrue(installed.contains { item in
            if case let .hero(_, title, _) = item { return title == ModOnboardingText.manageTitle.defaultText }; return false
        })
        XCTAssertFalse(installed.contains { if case .feature = $0 { return true }; return false },
                       "installed users see management, not the install pitch")
        let silent = ModPanelContent.items(for: .intro(dismissChecked: false), plan: .standard,
            localize: ModOnboardingText.defaultLocalize, sync: context(.silent))
        XCTAssertEqual(silent.filter { if case let .text(text) = $0 { return text.hasPrefix("•") }; return false }.count, 3)
    }

    func testOriginalDelayedSuccessCloseRequiresTrustedDataAndAnOpenWindow() throws {
        let c = ModOnboardingController(installer: ModInstaller(locator: FakeLocator(path: "/fake/claude"),
            runner: ScriptedRunner([ok, ok]), prepareInbox: { true }), preference: MemoryPreference())
        var status = ModSyncStatus.waitingForData
        let windows = ModOnboardingWindowController {
            ModOnboardingPanelView(controller: c, syncProvider: { self.context(status) })
        }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        let panel = windows.prepare(owner: owner)
        defer { windows.close() }
        ApplicationWindowPresentation.presentInBackground(panel)
        let view = try XCTUnwrap(windows.panelView)
        let installed = expectation(description: "commands finish")
        let render = c.onChange
        c.onChange = { render?(); if c.state == .succeeded { installed.fulfill() } }
        var closes = 0
        let closed = expectation(description: "trusted success closes after original delay")
        view.onRequestClose = { closes += 1; closed.fulfill() }
        c.startInstall()
        wait(for: [installed], timeout: 5)
        XCTAssertEqual(closes, 0, "command success never closes the waiting page")
        XCTAssertTrue(view.snapshotLines.contains { $0.contains("等待可信数据") })
        status = .active(lastAcceptedAt: Date())
        view.reload()
        XCTAssertEqual(closes, 0, "success remains visible briefly")
        wait(for: [closed], timeout: 4)
        XCTAssertEqual(closes, 1)
        windows.close()
        view.reload()
        XCTAssertEqual(closes, 1, "a closed window must not be brought back")
    }

    func testNativeWindowChromeAndLocalizedWidthMatchTheReference() throws {
        let previous = AppLanguage.selected
        defer { AppLanguage.selected = previous }
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.selected = language
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                styleMask: [.titled], backing: .buffered, defer: false)
            let windows = ModOnboardingWindowController {
                ModOnboardingPanelView(controller: self.controller(), localize: modOnboardingLocalize,
                    syncProvider: { self.context(.notInstalled(hasOtherScopeInstall: false)) })
            }
            let panel = windows.prepare(owner: owner)
            let view = try XCTUnwrap(windows.panelView)
            XCTAssertEqual(panel.titleVisibility, .hidden)
            XCTAssertTrue(panel.titlebarAppearsTransparent)
            XCTAssertTrue(panel.isMovableByWindowBackground)
            XCTAssertEqual(panel.standardWindowButton(.zoomButton)?.isHidden, true)
            XCTAssertGreaterThanOrEqual(panel.contentView?.bounds.width ?? 0, 380)
            XCTAssertLessThanOrEqual(panel.contentView?.bounds.width ?? 1000, 640)
            XCTAssertEqual(view.defaultButton?.identifier?.rawValue, "install")
            windows.close()
        }
    }
}
